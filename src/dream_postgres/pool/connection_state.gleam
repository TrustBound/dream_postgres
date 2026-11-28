//// The state that every call on a connection shares: the connection
//// itself, the settings of its pool, the one connection that a callback
//// holds, and the functions that hold it and run SQL on it. The public
//// modules `pool`, `query`, `copy`, `transaction` and `boot_check` all
//// work on this state.

import dream_errors.{type Error}
import dream_postgres/copy/executor
import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/cell.{type CommandResult}
import dream_postgres/driver/connection/call as connection_call
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/connection/status as connection_status
import dream_postgres/driver/pool as driver_pool
import dream_postgres/driver/pool/holds as pool_holds
import dream_postgres/driver/pool/pool_failure
import dream_postgres/driver/pool/pool_message.{type Pool}
import dream_postgres/error.{
  type PostgresError, type Reason, type ServerError, InterceptorFailed,
}
import dream_postgres/error/failure.{failure}
import dream_postgres/interceptor.{
  type Answer, type Interceptor, type Outcome, type Request, CopyFromAnswer,
  CopyToAnswer, Request, Sql, SqlAnswer, StatementAnswer,
}
import dream_postgres/query/driver_executor
import dream_postgres/query/runner.{type LowestLayer}
import dream_postgres/recorder.{type Recorder}
import dream_postgres/recorder/replay.{type Replay}
import dream_postgres/secrets.{type Secrets}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A connection to PostgreSQL: a pool, or the one connection that a
/// transaction or `with_connection` holds. Every query function takes it.
pub opaque type Connection {
  /// Each call holds a connection of the pool for its run. The pool
  /// carries the settings, so a handle made from a name has them too.
  /// `added_interceptors` run after the interceptors of the config.
  Pooled(pool: Pool(Settings), added_interceptors: List(Interceptor))
  /// One connection, held for a callback.
  OneConnection(held: HeldConnection, transaction_level: TransactionLevel)
  /// The connection of a recorder in playback mode, with no database:
  /// after the interceptors, the replay answers each request.
  Replayed(
    replay: Replay,
    interceptors: List(Interceptor),
    secrets: Secrets,
    recorder: Recorder,
  )
}

/// The settings that each call on a pool needs. The pool carries them.
pub opaque type Settings {
  Settings(
    host: String,
    port: Int,
    query_timeout_milliseconds: Int,
    checkout_timeout_milliseconds: Int,
    interceptors: List(Interceptor),
    /// The interceptors that run after all others, also after the
    /// interceptors that `with_interceptor` adds: the interceptor of a
    /// recorder in record mode.
    lowest_interceptors: List(Interceptor),
    secrets: Secrets,
    /// The recorder of the pool, which `stop` stops.
    recorder: Option(Recorder),
    /// What answers each request of a pool with no database: the replay of
    /// a recorder in playback mode under a supervisor.
    replay: Option(Replay),
  )
}

/// One connection, held for a callback: what answers its requests, and
/// the interceptors that each request goes through first.
pub opaque type HeldConnection {
  HeldConnection(session: Session, interceptors: List(Interceptor))
}

/// What answers the requests of a held connection.
pub opaque type Session {
  /// A connection of a pool, with the settings of the pool.
  DatabaseSession(
    connection: connection_call.Connection,
    catalog: Catalog,
    settings: Settings,
  )
  /// A connection with no database.
  ReplaySession(replay: Replay, secrets: Secrets)
}

pub opaque type TransactionLevel {
  /// No transaction is open on the connection.
  NoTransaction
  /// A transaction is open, inside `savepoints` savepoints of nested
  /// transactions.
  InTransaction(savepoints: Int)
}

// The error with the text secrets of the connection replaced in its SQL.
// When no pool runs under the name of a connection, its secrets are not
// known, so the error keeps no SQL.
pub fn secret_free_error(
  connection: Connection,
  failed: Error(PostgresError),
) -> Error(PostgresError) {
  let secret_free_sql = case connection_secrets(connection) {
    Ok(known) -> option.map(_, secrets.replace_text(known, _))
    Error(pool_failure.PoolNotRunning) -> fn(_sql) { None }
  }
  dream_errors.map_cause(failed, fn(cause) {
    error.PostgresError(..cause, sql: secret_free_sql(cause.sql))
  })
}

fn connection_secrets(
  connection: Connection,
) -> Result(Secrets, pool_failure.PoolNotRunning) {
  case connection {
    Pooled(pool:, ..) ->
      pool_holds.attachment(pool)
      |> result.map(fn(settings) { settings.secrets })
    OneConnection(held:, ..) -> Ok(session_secrets(held.session))
    Replayed(secrets: replay_secrets, ..) -> Ok(replay_secrets)
  }
}

fn session_secrets(session: Session) -> Secrets {
  case session {
    DatabaseSession(settings:, ..) -> settings.secrets
    ReplaySession(secrets: replay_secrets, ..) -> replay_secrets
  }
}

// The interceptors of a held connection, then its lowest interceptors.
pub fn chain_of(held: HeldConnection) -> List(Interceptor) {
  case held.session {
    DatabaseSession(settings:, ..) ->
      list.append(held.interceptors, settings.lowest_interceptors)
    ReplaySession(..) -> held.interceptors
  }
}

pub fn lowest_layer(held: HeldConnection) -> LowestLayer {
  case held.session {
    DatabaseSession(connection:, catalog:, settings:) ->
      runner.DatabaseLayer(driver_executor.executor(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      ))
    ReplaySession(replay:, ..) -> runner.AnsweringLayer(replay.answer)
  }
}

pub fn copy_from_end(held: HeldConnection) -> fn(Request) -> Outcome {
  case held.session {
    DatabaseSession(connection:, catalog:, settings:) ->
      executor.copy_from_database(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      )
    ReplaySession(replay:, ..) -> replay.answer
  }
}

pub fn copy_to_end(held: HeldConnection) -> fn(Request) -> Outcome {
  case held.session {
    DatabaseSession(connection:, catalog:, settings:) ->
      executor.copy_to_database(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      )
    ReplaySession(replay:, ..) -> replay.answer
  }
}

fn endpoint_of(settings: Settings) -> driver_executor.Endpoint {
  driver_executor.Endpoint(host: settings.host, port: settings.port)
}

/// Holds one connection for the callback: a connection of the pool, or
/// the connection that is held already. The error is why the pool gave no
/// connection.
pub fn hold(
  connection: Connection,
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  case connection {
    Pooled(pool:, added_interceptors:) ->
      hold_pooled(pool, added_interceptors, callback)
    OneConnection(held:, transaction_level: _) -> Ok(callback(held))
    Replayed(replay:, interceptors:, secrets: replay_secrets, ..) ->
      Ok(
        callback(HeldConnection(
          session: ReplaySession(replay:, secrets: replay_secrets),
          interceptors:,
        )),
      )
  }
}

// The settings and the catalog are read from the pool one time for each
// call. Both fail only when no pool runs. The interceptors that were added
// to the connection run after the interceptors of the config.
fn hold_pooled(
  pool: Pool(Settings),
  added_interceptors: List(Interceptor),
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  use settings <- result.try(
    pool_holds.attachment(pool) |> result.replace_error(error.PoolStopped),
  )
  let interceptors = list.append(settings.interceptors, added_interceptors)
  case settings.replay {
    Some(replay) ->
      Ok(
        callback(HeldConnection(
          session: ReplaySession(replay:, secrets: settings.secrets),
          interceptors:,
        )),
      )
    None -> hold_database(pool, settings, interceptors, callback)
  }
}

// Holds a connection of a pool that has a database.
fn hold_database(
  pool: Pool(Settings),
  settings: Settings,
  interceptors: List(Interceptor),
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  use catalog <- result.try(
    pool_holds.catalog(pool) |> result.replace_error(error.PoolStopped),
  )
  pool_holds.hold(
    pool,
    settings.checkout_timeout_milliseconds,
    fn(held_connection) {
      callback(HeldConnection(
        session: DatabaseSession(
          connection: held_connection,
          catalog:,
          settings:,
        ),
        interceptors:,
      ))
    },
  )
  |> result.map_error(driver_executor.checkout_error_reason(
    _,
    settings.host,
    settings.port,
  ))
}

// Runs a `run_sql` call through the interceptors, and gives the result of each
// of its statements.
pub fn run_held_sql(
  held: HeldConnection,
  sql: String,
) -> Result(List(CommandResult), Error(PostgresError)) {
  run_held_sql_with_postgres_error(held, sql)
  |> result.map_error(error.to_dream_error)
}

// Runs a `run_sql` call, and gives its failure as the PostgresError itself, for a
// caller that keeps it whole, such as the rollback of a transaction.
pub fn run_held_sql_with_postgres_error(
  held: HeldConnection,
  sql: String,
) -> Result(List(CommandResult), PostgresError) {
  runner.intercept(
    chain_of(held),
    Request(sql:, name: None, parameters: [], kind: Sql),
    sql_answer_from_session(held.session, _),
  )
  |> result.try(sql_answer)
  |> result.map_error(fn(reason) {
    error.PostgresError(query_name: None, sql: Some(sql), reason:)
  })
}

// The end of the chain of a `run_sql` call: runs its SQL on the connection, or
// gives the answer of the replay.
fn sql_answer_from_session(session: Session, request: Request) -> Outcome {
  case session {
    DatabaseSession(connection:, catalog: _, settings:) ->
      connection_simple_query.run_simple_query(
        connection,
        driver_executor.statement(request.sql, None, settings.secrets),
        settings.query_timeout_milliseconds,
      )
      |> result.map(fn(outcomes) {
        SqlAnswer(results: list.map(outcomes, fn(outcome) { outcome.result }))
      })
      |> result.map_error(driver_executor.simple_query_error_reason(
        _,
        endpoint_of(settings),
      ))
    ReplaySession(replay:, ..) -> replay.answer(request)
  }
}

fn sql_answer(answer: Answer) -> Result(List(CommandResult), Reason) {
  case answer {
    SqlAnswer(results:) -> Ok(results)
    StatementAnswer(..) | CopyFromAnswer(..) | CopyToAnswer(..) ->
      Error(InterceptorFailed(
        reason: "an interceptor answered a `run_sql` call with the answer of another kind of request",
      ))
  }
}

/// The settings of a pool, with the interceptors that run after all others
/// and, for a pool with no database, the replay that answers each request.
pub fn new_settings(
  host host: String,
  port port: Int,
  query_timeout_milliseconds query_timeout_milliseconds: Int,
  checkout_timeout_milliseconds checkout_timeout_milliseconds: Int,
  interceptors interceptors: List(Interceptor),
  lowest_interceptors lowest_interceptors: List(Interceptor),
  secrets secrets: Secrets,
  recorder recorder: Option(Recorder),
  replay replay: Option(Replay),
) -> Settings {
  Settings(
    host:,
    port:,
    query_timeout_milliseconds:,
    checkout_timeout_milliseconds:,
    interceptors:,
    lowest_interceptors:,
    secrets:,
    recorder:,
    replay:,
  )
}

/// The host of the server of the settings.
pub fn settings_host(settings: Settings) -> String {
  settings.host
}

/// The port of the server of the settings.
pub fn settings_port(settings: Settings) -> Int {
  settings.port
}

/// The longest time in milliseconds of one query, in the settings.
pub fn settings_query_timeout_milliseconds(settings: Settings) -> Int {
  settings.query_timeout_milliseconds
}

/// The connection of a pool, with no added interceptor.
pub fn pooled(pool: Pool(Settings)) -> Connection {
  Pooled(pool, added_interceptors: [])
}

/// The connection of a recorder in playback mode, with no database. It has
/// the interceptors and the secrets of the settings.
pub fn replayed(
  settings: Settings,
  replay: Replay,
  test_recorder: Recorder,
) -> Connection {
  Replayed(
    replay:,
    interceptors: settings.interceptors,
    secrets: settings.secrets,
    recorder: test_recorder,
  )
}

/// The connection of a transaction that is open on the held connection,
/// inside `savepoints` savepoints of nested transactions.
pub fn in_open_transaction(
  held: HeldConnection,
  savepoints: Int,
) -> Connection {
  OneConnection(held, InTransaction(savepoints:))
}

/// Where a connection is, for a transaction that starts on it.
pub type Placement {
  /// Not held yet: a pool, or a connection with no database.
  NotHeld
  /// Held, with no transaction open.
  HeldOutsideTransaction(held: HeldConnection)
  /// Held, with a transaction open inside `savepoints` savepoints.
  HeldInsideTransaction(held: HeldConnection, savepoints: Int)
}

/// Where the connection is.
pub fn placement(connection: Connection) -> Placement {
  case connection {
    Pooled(..) | Replayed(..) -> NotHeld
    OneConnection(held:, transaction_level: NoTransaction) ->
      HeldOutsideTransaction(held:)
    OneConnection(held:, transaction_level: InTransaction(savepoints:)) ->
      HeldInsideTransaction(held:, savepoints:)
  }
}

/// The report of the statement that failed the open transaction of the held
/// connection: from the state of the connection, or from the replay.
pub fn failed_statement(
  held: HeldConnection,
) -> Result(Option(ServerError), Reason) {
  case held.session {
    DatabaseSession(connection:, ..) ->
      connection_status.aborted_by(connection)
      |> result.map(option.map(_, error.server_error_from_report))
      |> result.map_error(driver_executor.connection_state_error_reason)
    ReplaySession(replay:, ..) -> replay.aborted_by()
  }
}

/// Stops the pool and closes its connections, then stops the recorder of
/// the config, if any. A held connection belongs to its pool, so stopping
/// one does nothing.
pub fn stop(connection: Connection) -> Nil {
  case connection {
    Pooled(pool:, added_interceptors: _) -> {
      let pool_recorder =
        pool_holds.attachment(pool)
        |> option.from_result
        |> option.then(fn(settings) { settings.recorder })
      driver_pool.stop(pool, 5000)
      stop_recorder(pool_recorder)
    }
    OneConnection(..) -> Nil
    Replayed(recorder: test_recorder, ..) -> recorder.stop(test_recorder)
  }
}

fn stop_recorder(pool_recorder: Option(Recorder)) -> Nil {
  case pool_recorder {
    Some(test_recorder) -> recorder.stop(test_recorder)
    None -> Nil
  }
}

/// The connection with an interceptor added after its other interceptors.
/// The connection that was given does not change.
pub fn add_interceptor(
  connection: Connection,
  added_interceptor: Interceptor,
) -> Connection {
  case connection {
    Pooled(pool:, added_interceptors:) ->
      Pooled(
        pool:,
        added_interceptors: list.append(added_interceptors, [added_interceptor]),
      )
    OneConnection(held:, transaction_level:) ->
      OneConnection(
        held: HeldConnection(
          ..held,
          interceptors: list.append(held.interceptors, [added_interceptor]),
        ),
        transaction_level:,
      )
    Replayed(interceptors:, ..) ->
      Replayed(
        ..connection,
        interceptors: list.append(interceptors, [added_interceptor]),
      )
  }
}

/// Holds one connection for the callback, which gets it as a connection with
/// no transaction open. On a connection that is held already, the callback
/// gets that connection.
pub fn hold_for_callback(
  connection: Connection,
  callback: fn(Connection) -> a,
) -> Result(a, Error(PostgresError)) {
  case connection {
    Pooled(..) | Replayed(..) ->
      hold(connection, fn(held) { callback(OneConnection(held, NoTransaction)) })
      |> result.map_error(failure(None, None, _))
    OneConnection(..) -> Ok(callback(connection))
  }
}
