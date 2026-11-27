//// Tests for `dream_postgres/driver/pool`, the pool and its holds, on the
//// driver servers of PostgreSQL 16 to 19. A test proxy between the pool
//// and the server breaks a connection on purpose, and a control
//// connection straight to the server watches and controls the server, so
//// no test sleeps. The advisory lock keys of these tests are 82600 to
//// 82699.

import dream_postgres/driver/catalog.{CatalogProcessDown}
import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type ConnectionEvent, type DriverError,
  type Outcome, Backoff, CacheStatements, ConnectionConfig,
  ConnectionProcessDown, Disconnected, LoginRefused, ReconnectFailed,
  Reconnected, TransportRefused,
}
import dream_postgres/driver/login.{
  type Password, PreferChannelBinding, ServerRejectedLogin,
}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/pool.{
  type CheckoutError, type Pool, type PoolConfig, type PoolStatus,
  type StartError, CheckoutTimedOut, ConnectFailed, InvalidHealthCheckInterval,
  InvalidSize, PoolConfig, PoolStatus, PoolStopped,
}
import dream_postgres/driver/statement_cache
import dream_postgres/driver/transport.{ConnectRefused, NoTls, TransportConfig}
import dream_postgres/internal/cell.{
  type TransactionStatus, type TypeDescription, Idle, InTransaction, Text,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process.{
  type Down, type ExitMessage, type ExitReason, type Pid, type Subject, Abnormal,
}
import gleam/int.{to_string}
import gleam/list.{map, unique}
import gleam/option.{type Option, None, Some}
import gleam/result.{try}

@external(erlang, "port_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "pool_proxy_ffi", "start")
fn start_proxy(server_port: Int) -> #(Int, Proxy)

@external(erlang, "pool_proxy_ffi", "freeze")
fn freeze(proxy: Proxy) -> KeptBytes

@external(erlang, "pool_proxy_ffi", "next_kept")
fn next_kept(kept: KeptBytes) -> BitArray

@external(erlang, "pool_proxy_ffi", "close_client")
fn close_client(proxy: Proxy) -> Nil

@external(erlang, "pool_proxy_ffi", "watch_client_end")
fn watch_client_end(proxy: Proxy) -> ClientEndWatch

@external(erlang, "pool_proxy_ffi", "client_end")
fn client_end(watch: ClientEndWatch) -> BitArray

@external(erlang, "pool_proxy_ffi", "stop")
fn stop_proxy(proxy: Proxy) -> Nil

@external(erlang, "pool_test_ffi", "supervisor_of")
fn supervisor_of(pool: Pool(extra)) -> Pid

@external(erlang, "pool_test_ffi", "members_of")
fn members_of(pool: Pool(extra)) -> List(Pid)

@external(erlang, "driver_connection_test_ffi", "pid_of")
fn connection_pid(connection: Connection) -> Pid

type Proxy

type KeptBytes

type ClientEndWatch

/// Why a test could not get to its assertion.
type Failure {
  Checkout(error: CheckoutError)
  Driver(error: DriverError)
  Start(error: StartError)
  Unexpected(what: String)
}

/// The tests of the pool.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/pool", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("starting", start_tests()),
    group("checkouts", checkout_tests()),
    group("connect errors", connect_error_tests()),
    group("replacing connections", replace_tests()),
    group("stopping", stop_tests()),
  ])
}

// Settings --------------------------------------------------------------------

fn connection_config(
  port: Int,
  user: String,
  password: Password,
  events: Option(Subject(ConnectionEvent)),
) -> Result(ConnectionConfig, Failure) {
  use address <- try(
    transport.address("localhost", port)
    |> result.replace_error(Unexpected("no address")),
  )
  use login_config <- try(
    login.new(
      user:,
      database: servers.database,
      password:,
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.replace_error(Unexpected("no login settings")),
  )
  Ok(ConnectionConfig(
    transport: TransportConfig(address, NoTls, 5000, 500),
    login: login_config,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(10, 60_000),
    events:,
    notifications: None,
    statements: CacheStatements(statement_cache.default_limit),
  ))
}

/// The settings of a pool as `dream` on `port`, with no health check in
/// the time of a test.
fn dream_config(port: Int) -> Result(PoolConfig(Nil), Failure) {
  use settings <- try(connection_config(
    port,
    "dream",
    login.password(servers.password),
    None,
  ))
  Ok(pool_config(settings, Nil))
}

fn pool_config(settings: ConnectionConfig, extra: extra) -> PoolConfig(extra) {
  PoolConfig(
    connection: settings,
    health_check_interval_milliseconds: 60_000,
    health_check_deadline_milliseconds: 5000,
    rollback_deadline_milliseconds: 5000,
    shutdown_deadline_milliseconds: 5000,
    extra:,
  )
}

fn with_health_check(
  config: PoolConfig(extra),
  interval: Int,
  deadline: Int,
) -> PoolConfig(extra) {
  PoolConfig(
    ..config,
    health_check_interval_milliseconds: interval,
    health_check_deadline_milliseconds: deadline,
  )
}

fn with_events(
  config: PoolConfig(extra),
  events: Subject(ConnectionEvent),
) -> PoolConfig(extra) {
  PoolConfig(
    ..config,
    connection: ConnectionConfig(..config.connection, events: Some(events)),
  )
}

/// Starts a pool, gives it to `body`, and stops it.
fn with_pool(
  config: PoolConfig(extra),
  size: Int,
  body: fn(Pool(extra)) -> Result(value, Failure),
) -> Result(value, Failure) {
  use started <- try(pool.start(config, size) |> result.map_error(Start))
  let value = body(started)
  pool.stop(started, 1000)
  value
}

/// Holds a connection of the pool for `body`.
fn held(
  pool: Pool(extra),
  body: fn(Connection) -> Result(value, Failure),
) -> Result(value, Failure) {
  pool.hold(pool, 5000, body)
  |> result.map_error(Checkout)
  |> result.flatten
}

fn script(
  connection: Connection,
  sql: String,
) -> Result(List(Outcome), Failure) {
  connection.run_script(connection, sql, 5000) |> result.map_error(Driver)
}

/// The text of the one cell of the one row of the last statement.
fn single_text(outcomes: List(Outcome)) -> Result(String, Failure) {
  case list.last(outcomes) |> result.map(outcome_rows) {
    Ok([[Text(bytes)]]) ->
      bit_array.to_string(bytes) |> result.replace_error(Unexpected("not text"))
    _ -> Error(Unexpected("not one text cell"))
  }
}

fn outcome_rows(outcome: Outcome) {
  outcome.result.rows
}

/// The backend process ID of the connection, as text.
fn backend_pid(connection: Connection) -> Result(String, Failure) {
  script(connection, "SELECT pg_backend_pid()::text") |> try(single_text)
}

fn held_backend_pid(pool: Pool(extra)) -> Result(String, Failure) {
  held(pool, backend_pid)
}

fn transaction_status(
  connection: Connection,
) -> Result(TransactionStatus, Failure) {
  connection.transaction_status(connection) |> result.map_error(Driver)
}

/// A connection straight to the server, for control queries.
fn with_control(
  port: Int,
  body: fn(Connection) -> Result(value, Failure),
) -> Result(value, Failure) {
  use settings <- try(connection_config(
    port,
    "dream",
    login.password(servers.password),
    None,
  ))
  use control <- try(
    connection.start(settings)
    |> result.replace_error(Unexpected("no control connection")),
  )
  let value = body(control)
  connection.stop(control)
  value
}

fn first_server() -> Server {
  case driver_servers() {
    [server, ..] -> server
    [] -> servers.Server(version: 16, port: 5441)
  }
}

/// Waits for the next event of the kind `wanted`, and drops the others.
fn wait_for_event(
  events: Subject(ConnectionEvent),
  wanted: String,
) -> Result(Nil, Failure) {
  use event <- try(
    process.receive(events, 5000)
    |> result.replace_error(Unexpected("no " <> wanted)),
  )
  case event_kind(event) == wanted {
    True -> Ok(Nil)
    False -> wait_for_event(events, wanted)
  }
}

fn event_kind(event: ConnectionEvent) -> String {
  case event {
    Disconnected(..) -> "disconnected"
    ReconnectFailed(..) -> "reconnect failed"
    Reconnected -> "reconnected"
  }
}

// Callers in other processes --------------------------------------------------

/// A caller in its own process that holds a connection until the test
/// releases it.
type Holder {
  Holder(release: Subject(Nil), answer: Subject(Result(Nil, CheckoutError)))
}

fn start_holder(pool: Pool(extra)) -> Result(Holder, Failure) {
  let ready = process.new_subject()
  let answer = process.new_subject()
  process.spawn(fn() { hold_until_released(pool, ready, answer) })
  use release <- try(
    process.receive(ready, 5000)
    |> result.replace_error(Unexpected("no holder")),
  )
  Ok(Holder(release:, answer:))
}

fn hold_until_released(
  pool: Pool(extra),
  ready: Subject(Subject(Nil)),
  answer: Subject(Result(Nil, CheckoutError)),
) -> Nil {
  let release = process.new_subject()
  process.send(
    answer,
    pool.hold(pool, 5000, wait_for_release(_, ready, release)),
  )
}

fn wait_for_release(
  _connection: Connection,
  ready: Subject(Subject(Nil)),
  release: Subject(Nil),
) -> Nil {
  process.send(ready, release)
  process.receive_forever(release)
}

fn release(holder: Holder) -> Result(Nil, Failure) {
  process.send(holder.release, Nil)
  process.receive(holder.answer, 5000)
  |> result.replace_error(Unexpected("no answer of the holder"))
  |> try(result.map_error(_, Checkout))
}

/// A caller in its own process that runs one script on a held connection.
fn start_script_caller(
  pool: Pool(extra),
  sql: String,
) -> Subject(Result(List(Outcome), Failure)) {
  let answer = process.new_subject()
  process.spawn(fn() { hold_and_run(pool, sql, answer) })
  answer
}

fn hold_and_run(
  pool: Pool(extra),
  sql: String,
  answer: Subject(Result(List(Outcome), Failure)),
) -> Nil {
  process.send(answer, held(pool, script(_, sql)))
}

fn script_answer(
  answer: Subject(Result(List(Outcome), Failure)),
) -> Result(List(Outcome), Failure) {
  process.receive(answer, 5000)
  |> result.replace_error(Unexpected("no answer of the caller"))
  |> result.flatten
}

/// Waits until the server has a session that waits for the advisory lock
/// `key`. It asks the control connection again each time: no sleep.
fn wait_for_lock_waiter(
  control: Connection,
  key: Int,
  attempts: Int,
) -> Result(Nil, Failure) {
  use waiters <- try(
    script(
      control,
      "SELECT count(*)::text FROM pg_locks WHERE locktype = 'advisory'"
        <> " AND NOT granted AND objid = "
        <> to_string(key),
    )
    |> try(single_text),
  )
  case waiters, attempts {
    "1", _ -> Ok(Nil)
    _, 0 -> Error(Unexpected("no lock waiter"))
    _, _ -> wait_for_lock_waiter(control, key, attempts - 1)
  }
}

/// Asks for the status until `count_of` gives `wanted`: no sleep.
fn wait_for_status(
  pool: Pool(extra),
  count_of: fn(PoolStatus) -> Int,
  wanted: Int,
  attempts: Int,
) -> Result(Nil, Failure) {
  use current <- try(pool.status(pool) |> result.map_error(Checkout))
  case count_of(current) == wanted, attempts {
    True, _ -> Ok(Nil)
    False, 0 -> Error(Unexpected("the status did not come"))
    False, _ -> wait_for_status(pool, count_of, wanted, attempts - 1)
  }
}

fn waiting_count(status: PoolStatus) -> Int {
  status.waiting
}

fn held_count(status: PoolStatus) -> Int {
  status.held
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("starts the set number of connections", fn() { check_size(server) }),
    it("rolls back a transaction that a hold leaves open", fn() {
      check_rollback(server)
    }),
    it("rolls back the transaction of a caller that exits", fn() {
      check_rollback_after_exit(server)
    }),
    it("waits for the request of a caller that exits before the reset", fn() {
      check_reset_after_running_request(server)
    }),
    it("gives a catalog that describes the server's types", fn() {
      check_catalog(server)
    }),
  ])
}

/// Three nested holds get three backends, and a fourth finds no free
/// connection.
fn check_size(server: Server) {
  // Arrange
  let config = dream_config(server.port)

  // Act
  let counts = {
    use config <- try(config)
    use pool <- with_pool(config, 3)
    use first <- held(pool)
    use second <- held(pool)
    use third <- held(pool)
    use pids <- try(list.try_map([first, second, third], backend_pid))
    let fourth = pool.hold(pool, 0, backend_pid)
    Ok(#(list.length(unique(pids)), result.replace(fourth, Nil)))
  }

  // Assert
  counts
  |> should
  |> be_equal(Ok(#(3, Error(CheckoutTimedOut))))
  |> or_fail_with("Expected three backends and a timed out fourth hold")
}

fn check_rollback(server: Server) {
  // Arrange
  let config = dream_config(server.port)

  // Act
  let after = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use began <- try(held(pool, begin_and_give_backend))
    use connection <- held(pool)
    use status <- try(transaction_status(connection))
    use pid <- try(backend_pid(connection))
    Ok(#(status, pid == began))
  }

  // Assert
  after
  |> should
  |> be_equal(Ok(#(Idle, True)))
  |> or_fail_with("Expected the same backend outside any transaction")
}

/// Begins a transaction, and gives the backend.
fn begin_and_give_backend(connection: Connection) -> Result(String, Failure) {
  use _begun <- try(script(connection, "BEGIN"))
  backend_pid(connection)
}

fn check_rollback_after_exit(server: Server) {
  // Arrange
  let config = dream_config(server.port)

  // Act
  let status = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    let began = process.new_subject()
    let caller = process.spawn_unlinked(fn() { begin_and_wait(pool, began) })
    use in_transaction <- try(
      process.receive(began, 5000)
      |> result.replace_error(Unexpected("no BEGIN")),
    )
    process.kill(caller)
    use after <- try(held(pool, transaction_status))
    Ok(#(in_transaction, after))
  }

  // Assert
  status
  |> should
  |> be_equal(Ok(#(Ok(InTransaction), Idle)))
  |> or_fail_with("Expected the transaction to be rolled back")
}

/// A caller's script begins a transaction and waits for an advisory lock
/// of the control connection. The caller is killed, so the pool starts the
/// reset while the script still runs. The next holder must get the
/// connection only after the script finished and the reset rolled its
/// transaction back.
fn check_reset_after_running_request(server: Server) {
  // Arrange
  let config = dream_config(server.port)
  let key = 82_610 + server.version

  // Act
  let status = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use control <- with_control(server.port)
    let lock = "pg_advisory_lock(" <> to_string(key) <> ")"
    use _locked <- try(script(control, "SELECT " <> lock))
    let begin = "BEGIN; SELECT pg_advisory_xact_lock(" <> to_string(key) <> ")"
    let answer = process.new_subject()
    let caller =
      process.spawn_unlinked(fn() { hold_and_run(pool, begin, answer) })
    use Nil <- try(wait_for_lock_waiter(control, key, 5000))
    process.kill(caller)
    use Nil <- try(wait_for_status(pool, held_count, 0, 100_000))
    let unlock = "SELECT pg_advisory_unlock(" <> to_string(key) <> ")"
    use _unlocked <- try(script(control, unlock))
    held(pool, transaction_status)
  }

  // Assert
  status
  |> should
  |> be_equal(Ok(Idle))
  |> or_fail_with("Expected the next holder outside the caller's transaction")
}

/// Each pool's catalog describes a type on a held connection, and stops
/// with the pool.
fn check_catalog(server: Server) {
  // Arrange
  let config = dream_config(server.port)

  // Act
  let descriptions = {
    use config <- try(config)
    use pool <- try(pool.start(config, 1) |> result.map_error(Start))
    use described <- try(held(pool, describe_int4(pool, _)))
    pool.stop(pool, 1000)
    use control <- with_control(server.port)
    let after_stop = catalog.describe(pool.catalog(pool), control, 23, 5000)
    Ok(#(described, result.replace(after_stop, Nil)))
  }

  // Assert
  descriptions
  |> should
  |> be_equal(Ok(#("int4", Error(CatalogProcessDown))))
  |> or_fail_with("Expected int4, then CatalogProcessDown after the stop")
}

fn describe_int4(
  pool: Pool(extra),
  connection: Connection,
) -> Result(String, Failure) {
  catalog.describe(pool.catalog(pool), connection, 23, 5000)
  |> result.map(type_name)
  |> result.replace_error(Unexpected("no description of int4"))
}

fn type_name(description: TypeDescription) -> String {
  description.name
}

/// Holds a connection, begins a transaction, says so, and waits until it
/// is killed.
fn begin_and_wait(
  pool: Pool(extra),
  began: Subject(Result(TransactionStatus, Failure)),
) -> Result(Nil, CheckoutError) {
  use connection <- pool.hold(pool, 5000)
  process.send(began, begin_status(connection))
  process.receive_forever(process.new_subject())
}

fn begin_status(connection: Connection) -> Result(TransactionStatus, Failure) {
  use _begun <- try(script(connection, "BEGIN"))
  transaction_status(connection)
}

// Starting --------------------------------------------------------------------

fn start_tests() {
  [
    it("refuses a size below 1", fn() {
      // Arrange
      let config = dream_config(first_server().port)

      // Act
      let started = config |> result.map(pool.start(_, 0))

      // Assert
      started
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(InvalidSize(0))))
      |> or_fail_with("Expected InvalidSize(0)")
    }),
    it("refuses a health check interval below 1", fn() {
      // Arrange
      let config =
        dream_config(first_server().port)
        |> result.map(with_health_check(_, 0, 5000))

      // Act
      let started = config |> result.map(pool.start(_, 1))

      // Assert
      started
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(InvalidHealthCheckInterval(0))))
      |> or_fail_with("Expected InvalidHealthCheckInterval(0)")
    }),
    it("gives the extra value of each pool, and its own settings", fn() {
      check_two_pools()
    }),
    it("gives its status", fn() { check_status() }),
  ]
}

/// Two pools with other users and other extra values: each connection
/// logs in with the user of its own pool, and each pool has its own
/// catalog.
fn check_two_pools() {
  // Arrange
  let port = first_server().port
  let first_settings =
    connection_config(port, "dream", login.password(servers.password), None)
  let second_settings =
    connection_config(port, "dream_trust", login.no_password(), None)

  // Act
  let users = {
    use first_settings <- try(first_settings)
    use second_settings <- try(second_settings)
    use first <- with_pool(pool_config(first_settings, "first"), 1)
    use second <- with_pool(pool_config(second_settings, "second"), 1)
    use first_user <- try(held(first, current_user))
    use second_user <- try(held(second, current_user))
    let separate_catalogs = pool.catalog(first) != pool.catalog(second)
    Ok(#(
      first_user,
      pool.extra(first),
      second_user,
      pool.extra(second),
      separate_catalogs,
    ))
  }

  // Assert
  users
  |> should
  |> be_equal(Ok(#("dream", "first", "dream_trust", "second", True)))
  |> or_fail_with("Expected each pool's user, extra value and catalog")
}

fn current_user(connection: Connection) -> Result(String, Failure) {
  script(connection, "SELECT current_user::text") |> try(single_text)
}

fn check_status() {
  // Arrange
  let config = dream_config(first_server().port)

  // Act
  let status = {
    use config <- try(config)
    use pool <- with_pool(config, 2)
    use _first <- held(pool)
    use _second <- held(pool)
    pool.status(pool) |> result.map_error(Checkout)
  }

  // Assert
  status
  |> should
  |> be_equal(
    Ok(PoolStatus(
      size: 2,
      connected: 2,
      available: 0,
      held: 2,
      waiting: 0,
      last_connect_error: None,
    )),
  )
  |> or_fail_with("Expected two connected and held connections")
}

// Checkouts -------------------------------------------------------------------

fn checkout_tests() {
  [
    it("gives CheckoutTimedOut when no connection is free in time", fn() {
      // Arrange
      let config = dream_config(first_server().port)

      // Act
      let answer = {
        use config <- try(config)
        use pool <- with_pool(config, 1)
        use holder <- try(start_holder(pool))
        let answer = pool.hold(pool, 20, backend_pid)
        use Nil <- try(release(holder))
        Ok(result.replace(answer, Nil))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(CheckoutTimedOut)))
      |> or_fail_with("Expected CheckoutTimedOut")
    }),
    it("gives a waiting checkout the connection that comes back", fn() {
      check_queue()
    }),
  ]
}

fn check_queue() {
  // Arrange
  let config = dream_config(first_server().port)

  // Act
  let answer = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use holder <- try(start_holder(pool))
    let waiter = start_script_caller(pool, "SELECT 'served'")
    use Nil <- try(wait_for_status(pool, waiting_count, 1, 100_000))
    use Nil <- try(release(holder))
    script_answer(waiter) |> try(single_text)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok("served"))
  |> or_fail_with("Expected the waiting checkout to run")
}

// Connect errors --------------------------------------------------------------

fn connect_error_tests() {
  [
    it("gives the connect error of a wrong password", fn() {
      // Arrange
      let settings =
        connection_config(
          first_server().port,
          "dream",
          login.password("wrong"),
          None,
        )

      // Act
      let answer = {
        use settings <- try(settings)
        use pool <- with_pool(pool_config(settings, Nil), 1)
        Ok(pool.hold(pool, 5000, backend_pid) |> result.map_error(login_code))
      }

      // Assert
      answer
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error("28P01")))
      |> or_fail_with("Expected the login refusal 28P01")
    }),
    it("gives the connect error of a server that is down", fn() {
      // Arrange
      let config = dream_config(free_port())

      // Act
      let answer = {
        use config <- try(config)
        use pool <- with_pool(config, 2)
        Ok(pool.hold(pool, 5000, backend_pid) |> result.replace(Nil))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(ConnectFailed(TransportRefused(ConnectRefused)))))
      |> or_fail_with(
        "Expected ConnectFailed(TransportRefused(ConnectRefused))",
      )
    }),
    it("gives the last connect error when every connection is lost", fn() {
      check_lost_server()
    }),
  ]
}

fn login_code(error: CheckoutError) -> String {
  case error {
    ConnectFailed(LoginRefused(ServerRejectedLogin(report))) -> report.code
    _ -> "not a login refusal"
  }
}

/// The proxy ends: the connection is lost, and its reconnect is refused.
fn check_lost_server() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let events = process.new_subject()
  let config = dream_config(port) |> result.map(with_events(_, events))

  // Act
  let answers = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use _pid <- try(held_backend_pid(pool))
    stop_proxy(proxy)
    use Nil <- try(wait_for_event(events, "reconnect failed"))
    let answer = pool.hold(pool, 5000, backend_pid) |> result.replace(Nil)
    use status <- try(pool.status(pool) |> result.map_error(Checkout))
    Ok(#(answer, status.last_connect_error))
  }

  // Assert
  answers
  |> should
  |> be_equal(
    Ok(#(
      Error(ConnectFailed(TransportRefused(ConnectRefused))),
      Some(TransportRefused(ConnectRefused)),
    )),
  )
  |> or_fail_with("Expected the refused reconnect for the hold and the status")
}

// Replacing connections -------------------------------------------------------

fn replace_tests() {
  [
    it("never hands out a connection that the server ended", fn() {
      check_server_ended()
    }),
    it("replaces a connection whose process was killed during a hold", fn() {
      check_killed_connection()
    }),
    it("replaces a connection that its holder stopped", fn() {
      check_stopped_connection()
    }),
    it("starts a member again after it was killed", fn() {
      check_killed_member()
    }),
    it("runs a health check on an idle connection", fn() {
      check_health_check()
    }),
    it(
      "replaces an idle connection whose health check passes its deadline",
      fn() { check_health_check_deadline() },
    ),
    it("drops the events of a connection that it replaced", fn() {
      check_stale_events()
    }),
    it("replaces a connection whose rollback passes its deadline", fn() {
      check_rollback_deadline()
    }),
  ]
}

fn check_server_ended() {
  // Arrange
  let events = process.new_subject()
  let config =
    dream_config(first_server().port) |> result.map(with_events(_, events))

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try(held_backend_pid(pool))
    use _terminated <- try({
      use control <- with_control(first_server().port)
      script(control, "SELECT pg_terminate_backend(" <> first <> ")")
    })
    use Nil <- try(wait_for_event(events, "disconnected"))
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend after the server ended the first")
}

/// The holder kills its connection's process and holds again inside its
/// hold: the member replaced the connection, and the end of the first
/// hold changes nothing.
fn check_killed_connection() {
  // Arrange
  let config = dream_config(first_server().port)

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use pids <- try({
      use connection <- held(pool)
      use first <- try(backend_pid(connection))
      process.kill(connection_pid(connection))
      use second <- try(held_backend_pid(pool))
      Ok(#(first, second))
    })
    use third <- try(held_backend_pid(pool))
    Ok(#(pids.0 != pids.1, pids.1 == third))
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(#(True, True)))
  |> or_fail_with("Expected a new backend that stays after the first hold")
}

fn check_stopped_connection() {
  // Arrange
  let config = dream_config(first_server().port)

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try({
      use connection <- held(pool)
      use pid <- try(backend_pid(connection))
      connection.stop(connection)
      Ok(pid)
    })
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend after the holder stopped the first")
}

fn check_killed_member() {
  // Arrange
  let config = dream_config(first_server().port)

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try(held_backend_pid(pool))
    use member <- try(
      list.first(members_of(pool))
      |> result.replace_error(Unexpected("no member")),
    )
    let monitor = process.monitor(member)
    process.kill(member)
    use _down <- try(
      process.new_selector()
      |> process.select_specific_monitor(monitor, down_reason)
      |> process.selector_receive(5000)
      |> result.replace_error(Unexpected("no exit of the member")),
    )
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend from the new member")
}

fn down_reason(down: Down) -> ExitReason {
  down.reason
}

/// The control connection asks for the last query of the idle backend
/// until it is the health check's.
fn check_health_check() {
  // Arrange
  let config =
    dream_config(first_server().port)
    |> result.map(with_health_check(_, 10, 5000))

  // Act
  let last_query = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use pid <- try(held_backend_pid(pool))
    use control <- with_control(first_server().port)
    wait_for_last_query(control, pid, "SELECT 1", 2000)
  }

  // Assert
  last_query
  |> should
  |> be_equal(Ok("SELECT 1"))
  |> or_fail_with("Expected the health check query")
}

fn wait_for_last_query(
  control: Connection,
  pid: String,
  wanted: String,
  attempts: Int,
) -> Result(String, Failure) {
  use query <- try(
    script(control, "SELECT query FROM pg_stat_activity WHERE pid = " <> pid)
    |> try(single_text),
  )
  case query == wanted, attempts {
    True, _ -> Ok(query)
    False, 0 -> Error(Unexpected("last query " <> query))
    False, _ -> wait_for_last_query(control, pid, wanted, attempts - 1)
  }
}

/// The proxy keeps the bytes of the health check, so its query passes
/// its deadline. A hold after it gets a new connection.
fn check_health_check_deadline() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let config = dream_config(port) |> result.map(with_health_check(_, 10, 50))

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try(held_backend_pid(pool))
    let kept = freeze(proxy)
    let _health_check = next_kept(kept)
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend after the health check failed")
}

/// The proxy keeps the bytes of the health check, then closes the
/// connection: the health check fails, and the connection's Disconnected
/// waits in the member's mailbox while the member replaces it. The new
/// connection must not be taken for lost.
fn check_stale_events() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let config =
    dream_config(port)
    |> result.map(with_health_check(_, 10, 5000))
    |> result.map(slow_reconnect)

  // Act
  let pids = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try(held_backend_pid(pool))
    let kept = freeze(proxy)
    let _health_check = next_kept(kept)
    close_client(proxy)
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  pids
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend that the pool hands out")
}

/// A connection that connects again only after the test.
fn slow_reconnect(config: PoolConfig(extra)) -> PoolConfig(extra) {
  PoolConfig(
    ..config,
    connection: ConnectionConfig(
      ..config.connection,
      reconnect: Backoff(60_000, 60_000),
    ),
  )
}

/// The hold leaves a transaction open, and the proxy keeps the ROLLBACK,
/// so it passes its deadline. A hold after it gets a new connection.
fn check_rollback_deadline() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let config = dream_config(port) |> result.map(short_rollback)

  // Act
  let after = {
    use config <- try(config)
    use pool <- with_pool(config, 1)
    use first <- try({
      use connection <- held(pool)
      use _begun <- try(script(connection, "BEGIN"))
      use pid <- try(backend_pid(connection))
      let _kept = freeze(proxy)
      Ok(pid)
    })
    use connection <- held(pool)
    use status <- try(transaction_status(connection))
    use second <- try(backend_pid(connection))
    Ok(#(status, first != second))
  }

  // Assert
  after
  |> should
  |> be_equal(Ok(#(Idle, True)))
  |> or_fail_with("Expected a new backend outside any transaction")
}

fn short_rollback(config: PoolConfig(extra)) -> PoolConfig(extra) {
  PoolConfig(..config, rollback_deadline_milliseconds: 50)
}

// Stopping --------------------------------------------------------------------

fn stop_tests() {
  [
    it("sends Terminate on each connection when it stops", fn() {
      check_terminate()
    }),
    it("lets a running hold finish when it stops", fn() { check_drain() }),
    it("closes a running hold at the deadline", fn() { check_drain_deadline() }),
    it("gives PoolStopped after it stopped", fn() {
      // Arrange
      let config = dream_config(first_server().port)

      // Act
      let answers = {
        use config <- try(config)
        use pool <- try(pool.start(config, 1) |> result.map_error(Start))
        pool.stop(pool, 1000)
        let answer = pool.hold(pool, 5000, backend_pid) |> result.replace(Nil)
        Ok(#(answer, pool.status(pool)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(PoolStopped), Error(PoolStopped))))
      |> or_fail_with("Expected PoolStopped for a hold and for the status")
    }),
    it("stops when the process that started it exits", fn() {
      check_owner_exit()
    }),
    it("stops with an error when the supervisor of its members stops", fn() {
      check_supervisor_exit()
    }),
  ]
}

fn check_terminate() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let config = dream_config(port)

  // Act
  let last_bytes = {
    use config <- try(config)
    use pool <- try(pool.start(config, 1) |> result.map_error(Start))
    use _pid <- try(held_backend_pid(pool))
    let watch = watch_client_end(proxy)
    pool.stop(pool, 1000)
    Ok(client_end(watch))
  }

  // Assert
  last_bytes
  |> should
  |> be_equal(Ok(<<"X", 4:32>>))
  |> or_fail_with("Expected a Terminate as the last bytes")
}

/// A hold waits on an advisory lock while the pool stops. The pool
/// refuses each checkout that comes after the stop, and closes only after
/// the hold finished.
fn check_drain() {
  // Arrange
  let port = first_server().port
  let config = dream_config(port)

  // Act
  let answers = {
    use config <- try(config)
    use pool <- try(pool.start(config, 1) |> result.map_error(Start))
    use control <- with_control(port)
    use _locked <- try(script(control, "SELECT pg_advisory_lock(82601)"))
    let running = start_script_caller(pool, "SELECT pg_advisory_lock(82601)")
    use Nil <- try(wait_for_lock_waiter(control, 82_601, 5000))
    let stopped = start_stopper(pool, 5000)
    use Nil <- try(wait_for_refusal(pool, 100_000))
    let refused = pool.hold(pool, 5000, backend_pid) |> result.replace(Nil)
    use _unlocked <- try(script(control, "SELECT pg_advisory_unlock(82601)"))
    let finished = script_answer(running) |> result.map(list.length)
    Ok(#(refused, finished, process.receive(stopped, 5000)))
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error(PoolStopped), Ok(1), Ok(Nil))))
  |> or_fail_with("Expected the hold to finish before the pool closed")
}

fn start_stopper(pool: Pool(extra), deadline: Int) -> Subject(Nil) {
  let stopped = process.new_subject()
  process.spawn(fn() { stop_and_tell(pool, deadline, stopped) })
  stopped
}

fn stop_and_tell(pool: Pool(extra), deadline: Int, stopped: Subject(Nil)) {
  pool.stop(pool, deadline)
  process.send(stopped, Nil)
}

/// Checks out until the pool refuses with PoolStopped: no sleep.
fn wait_for_refusal(pool: Pool(extra), attempts: Int) -> Result(Nil, Failure) {
  case pool.hold(pool, 0, backend_pid), attempts {
    Error(PoolStopped), _ -> Ok(Nil)
    _, 0 -> Error(Unexpected("the pool did not stop"))
    _, _ -> wait_for_refusal(pool, attempts - 1)
  }
}

fn check_drain_deadline() {
  // Arrange
  let port = first_server().port
  let config = dream_config(port)

  // Act
  let answer = {
    use config <- try(config)
    use pool <- try(pool.start(config, 1) |> result.map_error(Start))
    use control <- with_control(port)
    use _locked <- try(script(control, "SELECT pg_advisory_lock(82602)"))
    let running = start_script_caller(pool, "SELECT pg_advisory_lock(82602)")
    use Nil <- try(wait_for_lock_waiter(control, 82_602, 5000))
    pool.stop(pool, 20)
    let answer = script_answer(running) |> result.replace(Nil)
    use _unlocked <- try(script(control, "SELECT pg_advisory_unlock(82602)"))
    Ok(answer)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(Error(Driver(ConnectionProcessDown))))
  |> or_fail_with("Expected the hold's command to end with the pool")
}

/// The owner starts the pool, and exits after the test watches the end of
/// the connection.
fn check_owner_exit() {
  // Arrange
  let #(port, proxy) = start_proxy(first_server().port)
  let config = dream_config(port)
  let started = process.new_subject()

  // Act
  let last_bytes = {
    use config <- try(config)
    process.spawn(fn() { own_pool(config, started) })
    use #(pool, go) <- try(
      process.receive(started, 5000)
      |> result.replace_error(Unexpected("no pool"))
      |> result.flatten,
    )
    use _pid <- try(held_backend_pid(pool))
    let watch = watch_client_end(proxy)
    process.send(go, Nil)
    Ok(client_end(watch))
  }

  // Assert
  last_bytes
  |> should
  |> be_equal(Ok(<<"X", 4:32>>))
  |> or_fail_with("Expected a Terminate when the owner exits")
}

fn own_pool(
  config: PoolConfig(Nil),
  started: Subject(Result(#(Pool(Nil), Subject(Nil)), Failure)),
) -> Nil {
  let go = process.new_subject()
  let pool = pool.start(config, 1) |> result.map_error(Start)
  process.send(started, result.map(pool, with_go(_, go)))
  process.receive_forever(go)
}

fn with_go(pool: Pool(Nil), go: Subject(Nil)) -> #(Pool(Nil), Subject(Nil)) {
  #(pool, go)
}

/// The owner traps exits, kills the supervisor of the members, and tells
/// the exit reason of the pool.
fn check_supervisor_exit() {
  // Arrange
  let config = dream_config(first_server().port)
  let exits = process.new_subject()

  // Act
  let reason = {
    use config <- try(config)
    process.spawn(fn() { kill_supervisor(config, exits) })
    process.receive(exits, 5000)
    |> result.replace_error(Unexpected("no exit"))
    |> result.flatten
  }

  // Assert
  reason
  |> should
  |> be_equal(Ok(Abnormal(dynamic.string("a process of the pool stopped"))))
  |> or_fail_with("Expected the pool to stop with an error")
}

fn kill_supervisor(
  config: PoolConfig(Nil),
  exits: Subject(Result(ExitReason, Failure)),
) -> Nil {
  process.trap_exits(True)
  let reason = {
    use pool <- try(pool.start(config, 1) |> result.map_error(Start))
    process.kill(supervisor_of(pool))
    process.new_selector()
    |> process.select_trapped_exits(exit_reason)
    |> process.selector_receive(5000)
    |> result.replace_error(Unexpected("no exit of the pool"))
  }
  process.send(exits, reason)
}

fn exit_reason(exit: ExitMessage) -> ExitReason {
  exit.reason
}
