//// The pool of connections: start it, or run it under a supervisor, reach
//// it by a name, stop it, hold one connection for a callback, and add an
//// interceptor to one call.

import dream_errors.{type Error}
import dream_postgres/config.{
  type Config, type Settings, check_times, connection_count, pool_config,
  pool_settings, recorder_attachment,
}
import dream_postgres/driver/pool as driver_pool
import dream_postgres/driver/pool/pool_message
import dream_postgres/error.{type PostgresError}
import dream_postgres/error/failure.{failure_with_no_query}
import dream_postgres/interceptor.{type Interceptor}
import dream_postgres/pool/connection_state
import dream_postgres/query/driver_executor
import dream_postgres/recorder
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

/// A connection to PostgreSQL: a pool, or the one connection that a
/// transaction or `with_connection` holds. Every query function takes it.
pub type Connection =
  connection_state.Connection

/// Checks the config and starts the pool, linked to the calling process.
/// The connections connect in the background: a server that does not
/// answer shows as an error of the first query. For a pool under a
/// supervisor, use `supervised`.
pub fn start(config: Config) -> Result(Connection, Error(PostgresError)) {
  use _checked <- result.try(check_times(config))
  let settings = pool_settings(config, [], None)
  case recorder_attachment(config) {
    recorder.RecordingPool(interceptor:) -> start_pool(config, [interceptor])
    recorder.PlainPool -> start_pool(config, [])
    recorder.NoPool(replay:, recorder: test_recorder) ->
      Ok(connection_state.replayed(settings, replay, test_recorder))
  }
}

fn start_pool(
  config: Config,
  lowest_interceptors: List(Interceptor),
) -> Result(Connection, Error(PostgresError)) {
  use checked <- result.try(pool_config(config, lowest_interceptors, None))
  driver_pool.start(checked, connection_count(config))
  |> result.map(connection_state.pooled)
  |> result.map_error(fn(start_error) {
    failure_with_no_query(driver_executor.start_error_reason(start_error))
  })
}

/// The name of a pool that runs under a supervisor. Make it one time when
/// the program starts, with `process.new_name("database")`: each name is
/// an atom.
pub type PoolName =
  process.Name(pool_message.PoolMessage(Settings))

/// The child specification of a pool under the app's supervisor, under
/// the name. After a restart the new pool takes the same name, so a
/// `named_connection` of it keeps working. The config is checked here,
/// so a wrong config is an error before the supervisor starts.
///
/// ### Start a pool under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/supervised_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/codecs.{text}
/// import dream_postgres/config.{type Config}
/// import dream_postgres/error.{type PostgresError, describe}
/// import dream_postgres/pool.{type PoolName, named_connection, supervised}
/// import dream_postgres/query.{one, query}
/// import dream_postgres/row.{single}
/// import gleam/otp/actor
/// import gleam/otp/static_supervisor.{type Supervisor}
/// import gleam/result
///
/// /// Starts the app's supervisor with the pool under it. The pool runs
/// /// under `pool_name`, also after a restart.
/// pub fn start_supervisor(
///   config: Config,
///   pool_name: PoolName,
/// ) -> Result(actor.Started(Supervisor), String) {
///   use pool_child <- result.try(
///     supervised(config, name: pool_name)
///     |> result.map_error(describe),
///   )
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(pool_child)
///   |> static_supervisor.start
///   |> result.replace_error("the supervisor did not start")
/// }
///
/// /// Any process can reach the pool by its name.
/// pub fn current_database(
///   pool_name: PoolName,
/// ) -> Result(String, Error(PostgresError)) {
///   "SELECT current_database()"
///   |> query
///   |> one(single(text), named_connection(pool_name))
/// }
/// ```
pub fn supervised(
  config: Config,
  name name: PoolName,
) -> Result(ChildSpecification(Connection), Error(PostgresError)) {
  use _checked <- result.try(check_times(config))
  case recorder_attachment(config) {
    recorder.RecordingPool(interceptor:) ->
      pool_config(config, [interceptor], None)
      |> result.map(driver_pool.supervised(_, connection_count(config), name))
    recorder.PlainPool ->
      pool_config(config, [], None)
      |> result.map(driver_pool.supervised(_, connection_count(config), name))
    recorder.NoPool(replay:, ..) ->
      pool_config(config, [], Some(replay))
      |> result.map(driver_pool.supervised_without_database(_, name))
  }
  |> result.map(supervision.map_data(_, connection_state.pooled))
}

/// The connection of the pool that runs under the name. It holds only the
/// name, so it stays valid when the supervisor restarts the pool. While
/// no pool runs under the name, each call fails with `PoolStopped`.
pub fn named_connection(name: PoolName) -> Connection {
  connection_state.pooled(driver_pool.from_name(name))
}

/// Stops the pool and closes its connections, then stops the recorder of
/// the config, if any. The holds that run get at most 5 seconds to
/// finish. A held connection belongs to its pool, so `stop` of one does
/// nothing.
pub fn stop(connection: Connection) -> Nil {
  connection_state.stop(connection)
}

/// The connection with an interceptor added after its other interceptors.
/// Each query and `run_sql` call on the new connection, also in a transaction,
/// goes through it. The connection that was given does not change. For an
/// interceptor of every connection of a pool, use `intercept` on the
/// config.
///
/// ### Add an interceptor to one call <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/tagged_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/codecs.{text}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, with_interceptor}
/// import dream_postgres/query.{one, query}
/// import dream_postgres/row.{single}
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The SQL text that the server runs, with the tag in front of it.
/// pub fn current_sql(
///   connection: Connection,
/// ) -> Result(String, Error(PostgresError)) {
///   query("SELECT current_query()")
///   |> one(single(text), with_interceptor(connection, tag_with_app_name))
/// }
/// ```
pub fn with_interceptor(
  connection: Connection,
  added_interceptor: Interceptor,
) -> Connection {
  connection_state.add_interceptor(connection, added_interceptor)
}

/// Holds one connection of the pool for the callback, so that each call
/// in it runs on the same connection: for example a temporary table and
/// the queries on it. On a connection that is held already, the callback
/// gets that connection. A transaction that the callback leaves open is
/// rolled back when the hold ends.
pub fn with_connection(
  connection: Connection,
  callback: fn(Connection) -> a,
) -> Result(a, Error(PostgresError)) {
  connection_state.hold_for_callback(connection, callback)
}
