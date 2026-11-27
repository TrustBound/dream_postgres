//// Test fixtures that start connection processes on the driver servers:
//// the connection config, a started connection, a text query, a
//// connection through a test proxy with a control connection beside it,
//// the backend process IDs, a suspended connection process, the mailbox
//// and the memory of the connection process, and callers in their own
//// processes. A test stops each connection that it starts, because the
//// shared servers keep a connection open until it ends.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type DriverError, type Outcome, type StatementCaching,
  Backoff, CacheStatements, ConnectionConfig, LoginRefused, Outcome,
  ReconnectFailed, run_script, server_parameter, start, stop, transaction_status,
}
import dream_postgres/driver/login.{
  type LoginConfig, PreferChannelBinding, ServerRejectedLogin,
}
import dream_postgres/driver/message.{type ProtocolVersion, Protocol30}
import dream_postgres/driver/statement_cache.{default_limit}
import dream_postgres/driver/transport.{
  type Address, type Tls, NoTls, TransportConfig, address,
}
import dream_postgres/internal/cell.{CommandResult, Text}
import driver/proxy.{type Proxy, start_proxy}
import driver/servers.{type Server}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/option.{None, Some}
import gleam/string.{inspect}

// Configs ---------------------------------------------------------------------

/// The config of a connection to localhost on `port` as `user`, over plain
/// TCP, with a first reconnect delay of 10 milliseconds and no events.
/// It panics when the address or the login config is not valid: that is a
/// setup failure.
pub fn user_config(
  port: Int,
  user: String,
  password: String,
) -> ConnectionConfig {
  ConnectionConfig(
    transport: TransportConfig(server_address(port), NoTls, 5000, 500),
    login: login_config(user, password, [], Protocol30),
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(10, 60_000),
    events: None,
    notifications: None,
    statements: CacheStatements(default_limit),
  )
}

/// The config of a connection to localhost on `port` as `dream`.
pub fn connection_config(port: Int) -> ConnectionConfig {
  user_config(port, "dream", servers.password)
}

/// The config of a connection as `dream` that sets the server parameter
/// `application_name`, so a control connection can find its session in
/// `pg_stat_activity`.
pub fn application_config(
  port: Int,
  application_name: String,
) -> ConnectionConfig {
  parameter_config(port, "application_name", application_name)
}

/// The config of a connection as `dream` that sends the startup parameter
/// `name` with `value`.
pub fn parameter_config(
  port: Int,
  name: String,
  value: String,
) -> ConnectionConfig {
  ConnectionConfig(
    ..connection_config(port),
    login: login_config("dream", servers.password, [#(name, value)], Protocol30),
  )
}

/// The config of a connection as `dream` that asks for the protocol
/// version `protocol_version`.
pub fn protocol_config(
  port: Int,
  protocol_version: ProtocolVersion,
) -> ConnectionConfig {
  ConnectionConfig(
    ..connection_config(port),
    login: login_config("dream", servers.password, [], protocol_version),
  )
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

/// The config with the statement caching `caching`.
pub fn caching_config(
  config: ConnectionConfig,
  caching: StatementCaching,
) -> ConnectionConfig {
  ConnectionConfig(..config, statements: caching)
}

fn server_address(port: Int) -> Address {
  case address("localhost", port) {
    Ok(server_address) -> server_address
    Error(error) ->
      panic as { "could not build the address: " <> inspect(error) }
  }
}

fn login_config(
  user: String,
  password: String,
  parameters: List(#(String, String)),
  protocol_version: ProtocolVersion,
) -> LoginConfig {
  let config =
    login.new(
      user:,
      database: servers.database,
      password: login.password(password),
      parameters:,
      channel_binding: PreferChannelBinding,
      protocol_version:,
    )
  case config {
    Ok(config) -> config
    Error(error) ->
      panic as { "could not build the login config: " <> inspect(error) }
  }
}

// Started connections ---------------------------------------------------------

/// Starts a connection as `dream` to localhost on `port`. It panics with
/// the start error when the connection does not start: that is a setup
/// failure, not an assertion.
pub fn start_connection(port: Int) -> Connection {
  start_configured(connection_config(port))
}

/// Starts a connection with `config`. It panics with the start error when
/// the connection does not start.
pub fn start_configured(config: ConnectionConfig) -> Connection {
  case start(config) {
    Ok(connection) -> connection
    Error(error) -> panic_on_start(error)
  }
}

fn panic_on_start(error: ConnectError) -> Connection {
  panic as { "could not start a connection: " <> inspect(error) }
}

/// A connection through a test proxy, with its events, and a control
/// connection straight to the server.
pub type ProxiedConnection {
  ProxiedConnection(
    connection: Connection,
    control: Connection,
    proxy: Proxy,
    events: Subject(ConnectionEvent),
  )
}

/// Starts a connection to `server` through a new proxy, with a first
/// reconnect delay of `first_delay` milliseconds, and a control connection.
pub fn start_proxied(server: Server, first_delay: Int) -> ProxiedConnection {
  start_proxied_with_caching(
    server,
    first_delay,
    CacheStatements(default_limit),
  )
}

/// Starts a connection to `server` through a new proxy, as `start_proxied`
/// does, with the statement caching `caching`.
pub fn start_proxied_with_caching(
  server: Server,
  first_delay: Int,
  caching: StatementCaching,
) -> ProxiedConnection {
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  let config =
    connection_config(port)
    |> watched_config(events, first_delay)
    |> caching_config(caching)
  let connection = start_configured(config)
  let control = start_connection(server.port)
  ProxiedConnection(connection:, control:, proxy:, events:)
}

/// Starts a connection to `server` through a new proxy, as `start_proxied`
/// does, with the TLS setting `tls` through the proxy.
pub fn start_proxied_with_tls(
  server: Server,
  first_delay: Int,
  tls: Tls,
) -> ProxiedConnection {
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  let config =
    connection_config(port)
    |> watched_config(events, first_delay)
    |> tls_config(tls)
  let connection = start_configured(config)
  let control = start_connection(server.port)
  ProxiedConnection(connection:, control:, proxy:, events:)
}

/// Stops the connection and the control connection.
pub fn stop_proxied(proxied: ProxiedConnection) -> Nil {
  stop(proxied.connection)
  stop(proxied.control)
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

/// The backend process ID of the connection, as text. It panics when the
/// query fails: that is a setup failure.
pub fn backend_pid(connection: Connection) -> String {
  query_text(connection, "SELECT pg_backend_pid()::text")
}

/// The one text cell that `sql` gives on the connection. It panics when
/// the query fails or gives other rows: that is a setup failure.
pub fn query_text(connection: Connection, sql: String) -> String {
  single_text(run_script(connection, sql, 5000))
}

/// The backend process ID of the session that waits for the advisory lock
/// `key`, as text. It panics when there is no such session.
pub fn lock_waiter_pid(control: Connection, key: Int) -> String {
  query_text(control, lock_waiters(key, "pid::text"))
}

fn single_text(answer: Result(List(Outcome), DriverError)) -> String {
  case answer {
    Ok([Outcome(result: CommandResult(rows: [[Text(bytes)]], ..), ..)]) ->
      text_of(bytes)
    other -> panic as { "expected one text cell: " <> inspect(other) }
  }
}

fn text_of(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> panic as "expected UTF-8 text"
  }
}

/// Ends the backend of `pid` from the control connection. The server sends
/// it the FATAL error 57P01, then closes its socket.
pub fn terminate_backend(
  control: Connection,
  pid: String,
) -> Result(List(Outcome), DriverError) {
  run_script(control, "SELECT pg_terminate_backend(" <> pid <> ")", 5000)
}

/// Sends the connection process a message that is not about its socket.
pub fn send_stray_message(connection: Connection) -> Nil {
  let _sent = send_raw(pid_of(connection), "not a socket message")
  Nil
}

/// Suspends the connection process, so it answers no request until
/// `resume_connection`.
pub fn suspend_connection(connection: Connection) -> Nil {
  suspend(pid_of(connection))
}

/// Resumes a connection process that `suspend_connection` suspended.
pub fn resume_connection(connection: Connection) -> Nil {
  resume(pid_of(connection))
}

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "sys", "resume")
fn resume(pid: Pid) -> Nil

/// The process of a connection.
@external(erlang, "driver_connection_test_ffi", "pid_of")
pub fn pid_of(connection: Connection) -> Pid

@external(erlang, "erlang", "send")
fn send_raw(pid: Pid, message: String) -> String

/// The memory of a process, with the binaries it references, and the
/// length of its mailbox.
@external(erlang, "driver_copy_test_ffi", "memory_of")
pub fn memory_of(pid: Pid) -> #(Int, Int)

/// Sends a process a DOWN message of a monitor that it never made.
@external(erlang, "driver_copy_test_ffi", "send_stray_down")
pub fn send_stray_down(pid: Pid) -> Nil

/// The bytes of the ErrorResponse that a server sends when an
/// administrator ends the session: FATAL, 57P01.
pub fn fatal_error_bytes() -> BitArray {
  let body = <<
    "SFATAL":utf8, 0, "VFATAL":utf8, 0, "C57P01":utf8, 0,
    "Mterminating connection due to administrator command":utf8, 0, 0,
  >>
  <<"E", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

// Waiting without a sleep -----------------------------------------------------

/// Waits until a message with one of the tags waits in the mailbox of
/// `pid`, for example `request`, `copy_call` or `tcp`. It looks again each
/// time, at most `attempts` times: no sleep. Gives whether it came.
@external(erlang, "driver_copy_test_ffi", "wait_for_message")
pub fn wait_for_message(pid: Pid, tags: List(String), attempts: Int) -> Bool

/// Waits until at least `length` messages wait in the mailbox of `pid`.
/// Gives whether they came.
@external(erlang, "driver_copy_test_ffi", "wait_for_mailbox_length")
pub fn wait_for_mailbox_length(pid: Pid, length: Int, attempts: Int) -> Bool

/// Waits until the reset of the peer reached the TCP socket of `pid`.
/// Gives whether it did.
@external(erlang, "driver_copy_test_ffi", "wait_for_reset")
pub fn wait_for_reset(pid: Pid, attempts: Int) -> Bool

/// Waits until the backend of `pid` is idle. It asks the control
/// connection again each time: no sleep.
pub fn wait_for_idle_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, Nil) {
  wait_for_idle(control, pid, 1_000_000)
}

fn wait_for_idle(
  control: Connection,
  pid: String,
  attempts: Int,
) -> Result(Nil, Nil) {
  let sql = "SELECT state FROM pg_stat_activity WHERE pid = " <> pid
  case run_script(control, sql, 5000), attempts {
    Ok([Outcome(result: CommandResult(rows: [[Text(<<"idle">>)]], ..), ..)]), _
    -> Ok(Nil)
    Error(_error), _ -> Error(Nil)
    _, 0 -> Error(Nil)
    _, _ -> wait_for_idle(control, pid, attempts - 1)
  }
}

/// Waits until one session of the server waits for the advisory lock
/// `key`. It asks the control connection again each time: no sleep.
/// Tests that run at the same time use different keys.
pub fn wait_for_lock_waiter(control: Connection, key: Int) -> Result(Nil, Nil) {
  wait_for_one(control, lock_waiters(key, "count(*)::text"), 5000)
}

/// Waits until one session of the server waits for a lock on `table`.
pub fn wait_for_table_waiter(
  control: Connection,
  table: String,
) -> Result(Nil, Nil) {
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
) -> Result(Nil, Nil) {
  case run_script(control, sql, 5000), attempts {
    Ok([Outcome(result: CommandResult(rows: [[Text(<<"1">>)]], ..), ..)]), _ ->
      Ok(Nil)
    Error(_error), _ -> Error(Nil)
    _, 0 -> Error(Nil)
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
) -> Result(Nil, Nil) {
  wait_for_value(connection, name, value, 5000)
}

fn wait_for_value(
  connection: Connection,
  name: String,
  value: String,
  attempts: Int,
) -> Result(Nil, Nil) {
  case server_parameter(connection, name) == Ok(Some(value)), attempts {
    True, _ -> Ok(Nil)
    False, 0 -> Error(Nil)
    False, _ -> wait_for_value(connection, name, value, attempts - 1)
  }
}

/// Asks for the transaction status `count` times more, so a request that
/// a caller sent before has reached the connection process. No sleep.
pub fn ask_transaction_status(
  connection: Connection,
  count: Int,
) -> Result(Nil, DriverError) {
  case transaction_status(connection), count {
    Error(error), _ -> Error(error)
    Ok(_status), 0 -> Ok(Nil)
    Ok(_status), _ -> ask_transaction_status(connection, count - 1)
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

/// Starts a process, not linked to the test, that sends `Nil` to
/// `calling`, then makes `call` and sends the answer back. A test that
/// receives from `calling` knows that the call is about to start.
pub fn start_announced_caller(
  call: fn() -> answer,
  calling: Subject(Nil),
) -> Caller(answer) {
  start_caller(fn() { announce_and_call(call, calling) })
}

fn announce_and_call(call: fn() -> answer, calling: Subject(Nil)) -> answer {
  process.send(calling, Nil)
  call()
}

/// The answer of the caller, or `Error(Nil)` after 5 seconds.
pub fn caller_answer(caller: Caller(answer)) -> Result(answer, Nil) {
  process.receive(caller.answers, 5000)
}

/// Makes `start` in a process that traps exits and then ends, and gives
/// what `start` gave. A supervisor that fails to start does not take the
/// process down before it answers, and what `start` linked to the process
/// sees it end.
pub fn start_in_ended_owner(start: fn() -> answer) -> Result(answer, Nil) {
  let answers = process.new_subject()
  process.spawn_unlinked(fn() { owner_body(start, answers) })
  process.receive(answers, 5000)
}

fn owner_body(start: fn() -> answer, answers: Subject(answer)) -> Nil {
  process.trap_exits(True)
  process.send(answers, start())
}
