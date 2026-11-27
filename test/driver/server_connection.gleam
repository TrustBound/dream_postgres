//// Test fixtures that start connection processes on the driver servers:
//// the connection config, a started connection, a connection through a
//// test proxy with a control connection beside it, the backend process
//// IDs, and callers in their own processes.
////
//// Each fixture that can fail gives a `Result` with a text error, so a
//// setup of dream_test reports the failure as a failed setup. The hooks
//// are for `dream_test/unit_context`: a describe gets its first context
//// from `connection_setup` or `proxied_setup`, each test starts its own
//// connection in `before_each` and stops it in `after_each`. The shared
//// servers keep a connection open until it ends, so every start has a
//// stop.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type ConnectionEvent, type DriverError,
  type Outcome, Backoff, ConnectionConfig, LoginRefused, Outcome,
  ReconnectFailed, run, run_script, server_parameter, start, stop,
}
import dream_postgres/driver/login.{
  type LoginConfig, PreferChannelBinding, ServerRejectedLogin,
}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/transport.{
  type Address, type Tls, NoTls, TransportConfig, address,
}
import dream_postgres/internal/cell.{CommandResult, Text}
import dream_test/context.{type Context}
import driver/proxy.{type Proxy, inject, start_proxy, stop_proxy, stop_reading}
import driver/servers.{type Server}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/option.{None, Some}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect, repeat}

// Configs ---------------------------------------------------------------------

/// The config of a connection to localhost on `port` as `user`, over plain
/// TCP, with a first reconnect delay of 10 milliseconds and no events.
pub fn user_config(
  port: Int,
  user: String,
  password: String,
) -> Result(ConnectionConfig, String) {
  use server_address <- try(server_address(port))
  use login <- try(login_config(user, password))
  Ok(ConnectionConfig(
    transport: TransportConfig(server_address, NoTls, 5000, 500),
    login:,
    setup_timeout_milliseconds: 5000,
    reconnect: Backoff(10, 60_000),
    events: None,
  ))
}

/// The config of a connection to localhost on `port` as `dream`.
pub fn connection_config(port: Int) -> Result(ConnectionConfig, String) {
  user_config(port, "dream", servers.password)
}

/// The config with its events sent to `events`, and a first reconnect
/// delay of `first_delay` milliseconds.
pub fn watched_config(
  config: ConnectionConfig,
  events: Subject(ConnectionEvent),
  first_delay: Int,
) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    reconnect: Backoff(first_delay, 60_000),
    events: Some(events),
  )
}

/// The config with the TLS setting `tls`.
pub fn tls_config(config: ConnectionConfig, tls: Tls) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    transport: TransportConfig(..config.transport, tls:),
  )
}

fn server_address(port: Int) -> Result(Address, String) {
  address("localhost", port)
  |> map_error(fn(error) { "could not build the address: " <> inspect(error) })
}

fn login_config(user: String, password: String) -> Result(LoginConfig, String) {
  login.new(
    user:,
    database: servers.database,
    password: login.password(password),
    parameters: [],
    channel_binding: PreferChannelBinding,
    protocol_version: Protocol30,
  )
  |> map_error(fn(error) {
    "could not build the login config: " <> inspect(error)
  })
}

// Started connections ---------------------------------------------------------

/// Starts a connection as `dream` to localhost on `port`.
pub fn start_connection(port: Int) -> Result(Connection, String) {
  connection_config(port) |> try(start_configured)
}

/// Starts a connection with `config`.
pub fn start_configured(
  config: ConnectionConfig,
) -> Result(Connection, String) {
  start(config)
  |> map_error(fn(error) { "could not start a connection: " <> inspect(error) })
}

/// Stops the connection. A teardown for `after_each` and for the context
/// setup. A connection that stopped already stays stopped.
pub fn stop_connection(connection: Connection) -> Result(Nil, String) {
  Ok(stop(connection))
}

/// Runs `sql` on the connection, for a step that prepares the state of a
/// test.
pub fn run_control_script(
  connection: Connection,
  sql: String,
) -> Result(Nil, String) {
  run_script(connection, sql, 5000)
  |> replace(Nil)
  |> map_error(fn(error) { "could not run " <> sql <> ": " <> inspect(error) })
}

// Hooks for a describe whose context is a connection --------------------------

/// The context of a describe whose tests each get a connection: one
/// connection to `server` for the tree, which gives the context its first
/// value. `start_test_connection` gives each test its own.
///
/// ```gleam
/// describe("connection", connection_setup(first_driver_server), [
///   before_each(start_test_connection(first_driver_server)),
///   after_each(stop_connection),
///   it("runs a script", fn(connection) {
///     run_script(connection, "SELECT 1", 5000)
///     |> should
///     |> be_ok
///     |> or_fail_with("Expected the outcome")
///   }),
/// ])
/// ```
pub fn connection_setup(server: Server) -> Context(Connection) {
  context.setup(
    setup: fn() { start_connection(server.port) },
    teardown: stop_connection,
  )
}

/// A `before_each` hook that starts a connection to `server` for the test.
/// The connection in the context it gets stays as it is.
pub fn start_test_connection(
  server: Server,
) -> fn(Connection) -> Result(Connection, String) {
  fn(_tree_connection) { start_connection(server.port) }
}

/// A `before_each` hook that starts a connection with `config` for the
/// test.
pub fn start_test_configured(
  config: Result(ConnectionConfig, String),
) -> fn(Connection) -> Result(Connection, String) {
  fn(_tree_connection) { try(config, start_configured) }
}

/// A hook that runs `step` on its context and keeps the context. The setup
/// fails with the error of the step.
pub fn setup_step(
  step: fn(context) -> Result(a, String),
) -> fn(context) -> Result(context, String) {
  fn(context) { step(context) |> replace(context) }
}

/// A hook that runs the script `sql`, which must work.
pub fn run_setup_script(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  setup_step(run_control_script(_, sql))
}

/// A hook that runs the script `sql`, which must fail: for a test of the
/// state after a failure. The setup fails when the script works.
pub fn run_failing_script(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  fn(connection) {
    run_script(connection, sql, 5000) |> require_failure(connection, sql)
  }
}

/// A hook that runs the statement `sql` with no parameters, which must
/// fail. The setup fails when the statement works.
pub fn run_failing_statement(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  fn(connection) {
    run(connection, sql, [], [], 5000) |> require_failure(connection, sql)
  }
}

fn require_failure(
  answer: Result(a, DriverError),
  context: context,
  sql: String,
) -> Result(context, String) {
  case answer {
    Error(_expected) -> Ok(context)
    Ok(value) ->
      Error("expected " <> sql <> " to fail, it gave " <> inspect(value))
  }
}

// Connections through a proxy -------------------------------------------------

/// A connection through a test proxy, with its events, a control
/// connection straight to the server, and an advisory lock key that no
/// other test uses.
pub type ProxiedConnection {
  ProxiedConnection(
    connection: Connection,
    control: Connection,
    proxy: Proxy,
    events: Subject(ConnectionEvent),
    lock_key: Int,
  )
}

/// Starts a connection to `server` through a new proxy, with a first
/// reconnect delay of `first_delay` milliseconds, and a control connection.
pub fn start_proxied(
  server: Server,
  first_delay: Int,
) -> Result(ProxiedConnection, String) {
  use #(port, proxy) <- try(start_proxy(server.port))
  start_through_proxy(server, first_delay, port, proxy)
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn start_through_proxy(
  server: Server,
  first_delay: Int,
  port: Int,
  proxy: Proxy,
) -> Result(ProxiedConnection, String) {
  let events = process.new_subject()
  use config <- try(connection_config(port))
  use connection <- try(
    start_configured(watched_config(config, events, first_delay)),
  )
  use control <- try(
    start_connection(server.port) |> map_error(stop_after_error(connection, _)),
  )
  let lock_key = unique_lock_key()
  Ok(ProxiedConnection(connection:, control:, proxy:, events:, lock_key:))
}

/// Stops the connection and gives `error`: for a setup that fails after it
/// started the connection.
pub fn stop_after_error(connection: Connection, error: String) -> String {
  stop(connection)
  error
}

/// Stops the connection, the proxy and the control connection. A teardown for
/// `after_each` and for the context setup.
pub fn stop_proxied(proxied: ProxiedConnection) -> Result(Nil, String) {
  Ok(stop_both(proxied))
}

fn stop_both(proxied: ProxiedConnection) -> Nil {
  stop(proxied.connection)
  stop_proxy(proxied.proxy)
  stop(proxied.control)
}

@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_lock_key() -> Int

/// The context of a describe whose tests each get a proxied connection:
/// one for the tree, which gives the context its first value.
/// `start_test_proxied` gives each test its own.
pub fn proxied_setup(
  server: Server,
  first_delay: Int,
) -> Context(ProxiedConnection) {
  context.setup(
    setup: fn() { start_proxied(server, first_delay) },
    teardown: stop_proxied,
  )
}

/// A `before_each` hook that starts a proxied connection for the test.
pub fn start_test_proxied(
  server: Server,
  first_delay: Int,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(_tree_proxied) { start_proxied(server, first_delay) }
}

/// What an act gave, with the proxied connection that it ran on.
pub type ProxiedOutcome(outcome) {
  ProxiedOutcome(proxied: ProxiedConnection, outcome: outcome)
}

/// The context of a describe whose tests each check one value of one
/// shared act: the setup starts a proxied connection and runs `act` on it
/// once, and the teardown stops the connection. Use it when the act waits
/// in real time, so the wait happens once.
///
/// ```gleam
/// describe("a late answer", proxied_act_setup(first_driver_server, 60_000, run_late), [
///   it("gives DeadlinePassed", fn(shared) {
///     shared.outcome.late
///     |> should
///     |> be_error
///     |> or_fail_with("Expected DeadlinePassed")
///   }),
/// ])
/// ```
pub fn proxied_act_setup(
  server: Server,
  first_delay: Int,
  act: fn(ProxiedConnection) -> Result(outcome, String),
) -> Context(ProxiedOutcome(outcome)) {
  context.setup(
    setup: fn() { start_proxied(server, first_delay) |> try(run_act(_, act)) },
    teardown: stop_proxied_outcome,
  )
}

fn run_act(
  proxied: ProxiedConnection,
  act: fn(ProxiedConnection) -> Result(outcome, String),
) -> Result(ProxiedOutcome(outcome), String) {
  act(proxied)
  |> result.map(ProxiedOutcome(proxied, _))
  |> map_error(fn(error) {
    stop_both(proxied)
    error
  })
}

fn stop_proxied_outcome(
  shared: ProxiedOutcome(outcome),
) -> Result(Nil, String) {
  stop_proxied(shared.proxied)
}

/// Takes the advisory lock `proxied.lock_key` on the control connection. A
/// hook: the stop of the control connection gives the lock back.
pub fn hold_advisory_lock(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  run_control_script(proxied.control, advisory_lock_sql(proxied.lock_key))
  |> replace(proxied)
}

/// Gives back the advisory lock `proxied.lock_key` of the control
/// connection.
pub fn release_advisory_lock(
  proxied: ProxiedConnection,
) -> Result(Nil, String) {
  run_control_script(
    proxied.control,
    "SELECT pg_advisory_unlock(" <> to_string(proxied.lock_key) <> ")",
  )
}

/// The call that waits for the advisory lock `proxied.lock_key` on the
/// proxied connection, for `start_caller`.
pub fn lock_request(
  proxied: ProxiedConnection,
) -> fn() -> Result(List(Outcome), DriverError) {
  fn() {
    run_script(proxied.connection, advisory_lock_sql(proxied.lock_key), 5000)
  }
}

/// A hook that runs the script `sql` on the control connection, which
/// must work.
pub fn run_control_setup_script(
  sql: String,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  setup_step(fn(proxied: ProxiedConnection) {
    run_control_script(proxied.control, sql)
  })
}

/// The SQL that waits for the advisory lock `key`.
pub fn advisory_lock_sql(key: Int) -> String {
  "SELECT pg_advisory_lock(" <> to_string(key) <> ")"
}

/// A hook that ends the backend of the proxied connection from the control
/// connection, and waits for the event of the loss.
pub fn terminate_session(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  use pid <- try(backend_pid(proxied.connection))
  use _terminated <- try(terminate_backend(proxied.control, pid))
  wait_for_event(proxied)
}

/// A hook that breaks the proxied connection with `breaking`, and waits
/// for the event of the loss.
pub fn break_session(
  breaking: fn(Proxy) -> Nil,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(proxied: ProxiedConnection) {
    breaking(proxied.proxy)
    wait_for_event(proxied)
  }
}

fn wait_for_event(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  next_event(proxied.events)
  |> replace(proxied)
  |> map_error(fn(_timeout) { "no event within 5 seconds" })
}

/// A hook that fills the send queue of the socket: the proxy stops
/// reading, and a script of 64 MB runs with a deadline of 50 milliseconds,
/// which must pass.
pub fn fill_send_queue(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  stop_reading(proxied.proxy)
  let large = "SELECT '" <> repeat("x", 64_000_000) <> "'"
  run_script(proxied.connection, large, 50)
  |> require_failure(proxied, "a script of 64 MB")
}

/// A hook that sends `bytes` to the client as if the server sent them, and
/// waits until the server parameter `name` is `value`.
pub fn inject_and_wait_for_parameter(
  bytes: BitArray,
  name: String,
  value: String,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(proxied: ProxiedConnection) {
    inject(proxied.proxy, bytes)
    wait_for_parameter(proxied.connection, name, value) |> replace(proxied)
  }
}

// Events ----------------------------------------------------------------------

/// The next event, or `Error(Nil)` after 5 seconds.
pub fn next_event(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  process.receive(events, 5000)
}

/// The next event that is not a reconnect refused with 28P01.
pub fn next_event_after_refused_reconnects(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  case next_event(events) {
    Ok(ReconnectFailed(LoginRefused(ServerRejectedLogin(report))))
      if report.code == "28P01"
    -> next_event_after_refused_reconnects(events)
    other -> other
  }
}

// Backends --------------------------------------------------------------------

/// The backend process ID of the connection, as text.
pub fn backend_pid(connection: Connection) -> Result(String, String) {
  run_script(connection, "SELECT pg_backend_pid()::text", 5000)
  |> single_text
}

/// The backend process ID of the session that waits for the advisory lock
/// `key`, as text.
pub fn lock_waiter_pid(
  control: Connection,
  key: Int,
) -> Result(String, String) {
  run_script(control, lock_waiters(key, "pid::text"), 5000) |> single_text
}

fn single_text(
  answer: Result(List(Outcome), DriverError),
) -> Result(String, String) {
  case answer {
    Ok([Outcome(result: CommandResult(rows: [[Text(bytes)]], ..), ..)]) ->
      bit_array.to_string(bytes)
      |> map_error(fn(_nil) { "expected UTF-8 text" })
    other -> Error("expected one text cell: " <> inspect(other))
  }
}

/// Ends the backend of `pid` from the control connection. The server sends
/// it the FATAL error 57P01, then closes its socket.
pub fn terminate_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, String) {
  run_control_script(control, "SELECT pg_terminate_backend(" <> pid <> ")")
}

/// Sends the connection process a message that is not about its socket.
@external(erlang, "driver_connection_test_ffi", "send_stray_message")
pub fn send_stray_message(connection: Connection) -> Nil

// Waiting without a sleep -----------------------------------------------------

/// Waits until one session of the server waits for the advisory lock
/// `key`. It asks the control connection again each time: no sleep.
pub fn wait_for_lock_waiter(
  control: Connection,
  key: Int,
) -> Result(Nil, String) {
  wait_for_one(control, lock_waiters(key, "count(*)::text"), 5000)
}

/// Waits until one session of the server waits for a lock on `table`.
pub fn wait_for_table_waiter(
  control: Connection,
  table: String,
) -> Result(Nil, String) {
  let sql =
    "SELECT count(*)::text FROM pg_locks WHERE locktype = 'relation' AND NOT granted AND relation = '"
    <> table
    <> "'::regclass"
  wait_for_one(control, sql, 5000)
}

fn lock_waiters(key: Int, column: String) -> String {
  "SELECT "
  <> column
  <> " FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid = "
  <> to_string(key)
}

fn wait_for_one(
  control: Connection,
  sql: String,
  attempts: Int,
) -> Result(Nil, String) {
  case run_script(control, sql, 5000), attempts {
    Ok([Outcome(result: CommandResult(rows: [[Text(<<"1">>)]], ..), ..)]), _ ->
      Ok(Nil)
    Error(error), _ -> Error("could not ask for waiters: " <> inspect(error))
    _, 0 -> Error("no session waited: " <> sql)
    _, _ -> wait_for_one(control, sql, attempts - 1)
  }
}

/// Asks for the server parameter `name` until it is `value`. A snapshot
/// request comes after the bytes that came before it, so once the value is
/// there, the process handled all of them. No sleep.
pub fn wait_for_parameter(
  connection: Connection,
  name: String,
  value: String,
) -> Result(Nil, String) {
  wait_for_value(connection, name, value, 5000)
}

fn wait_for_value(
  connection: Connection,
  name: String,
  value: String,
  attempts: Int,
) -> Result(Nil, String) {
  case server_parameter(connection, name) == Ok(Some(value)), attempts {
    True, _ -> Ok(Nil)
    False, 0 -> Error("the parameter " <> name <> " did not become " <> value)
    False, _ -> wait_for_value(connection, name, value, attempts - 1)
  }
}

// Callers in their own processes ----------------------------------------------

/// A process that makes one call and sends its answer back.
pub type Caller(answer) {
  Caller(answers: Subject(answer), pid: Pid)
}

/// Starts a process, not linked to the test, that makes `call` and sends
/// the answer back.
pub fn start_caller(call: fn() -> answer) -> Caller(answer) {
  let answers = process.new_subject()
  let pid = process.spawn_unlinked(fn() { process.send(answers, call()) })
  Caller(answers:, pid:)
}

/// The answer of the caller, or an error after 5 seconds.
pub fn caller_answer(caller: Caller(answer)) -> Result(answer, String) {
  process.receive(caller.answers, 5000)
  |> map_error(fn(_timeout) { "the caller gave no answer within 5 seconds" })
}

/// Makes `start` in a process that traps exits and then ends, and gives
/// what `start` gave. A supervisor that fails to start does not take the
/// process down before it answers, and what `start` linked to the process
/// sees it end.
pub fn start_in_ended_owner(start: fn() -> answer) -> Result(answer, String) {
  let answers = process.new_subject()
  process.spawn_unlinked(fn() { owner_body(start, answers) })
  process.receive(answers, 5000)
  |> map_error(fn(_timeout) { "the owner gave no answer within 5 seconds" })
}

fn owner_body(start: fn() -> answer, answers: Subject(answer)) -> Nil {
  process.trap_exits(True)
  process.send(answers, start())
}
