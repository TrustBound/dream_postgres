//// Connections to the driver servers, for the driver tests: one straight
//// to a server, and one through the test proxy
//// (`test/driver/driver_proxy_ffi.erl`) with a control connection beside
//// it. Also the gates that let a test wait for the connection process
//// with no sleep.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type ConnectionEvent, type DriverError,
  type Outcome, Backoff, CacheStatements, ConnectionConfig, ConnectionLost,
}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/statement_cache
import dream_postgres/driver/transport.{
  type Tls, AuthorityFile, CheckAuthorityAndHost, NoTls, PostgresNegotiation,
  RequireTls, SocketClosed, TransportConfig,
}
import dream_postgres/internal/cell.{type Cell, Text}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result.{try}
import gleam/string

/// The test proxy between a connection and a server.
pub type Proxy

/// A connection through a proxy, with its events, and a control connection
/// straight to the server.
pub type Setup {
  Setup(
    connection: Connection,
    control: Connection,
    proxy: Proxy,
    events: Subject(ConnectionEvent),
  )
}

@external(erlang, "driver_proxy_ffi", "start")
fn start_proxy(server_port: Int) -> #(Int, Proxy)

/// Sends bytes to the client, as if the server sent them.
@external(erlang, "driver_proxy_ffi", "inject")
pub fn inject(proxy: Proxy, bytes: BitArray) -> Nil

/// Closes the client's socket.
@external(erlang, "driver_proxy_ffi", "close_client")
pub fn close_client(proxy: Proxy) -> Nil

/// Resets the client's socket.
@external(erlang, "driver_proxy_ffi", "reset_client")
pub fn reset_client(proxy: Proxy) -> Nil

/// Answers the client's next bytes with `bytes`, which never reach the
/// server; then the proxy reads nothing more from the client.
@external(erlang, "driver_proxy_ffi", "answer_next_request")
pub fn answer_next_request(proxy: Proxy, bytes: BitArray) -> Nil

/// The process of a connection.
@external(erlang, "driver_connection_test_ffi", "pid_of")
pub fn pid_of(connection: Connection) -> Pid

/// The memory of a process, with the binaries it references, and the
/// length of its mailbox.
@external(erlang, "driver_copy_test_ffi", "memory_of")
pub fn memory_of(pid: Pid) -> #(Int, Int)

/// Sends a process a DOWN message of a monitor that it never made.
@external(erlang, "driver_copy_test_ffi", "send_stray_down")
pub fn send_stray_down(pid: Pid) -> Nil

/// Waits until a message with one of the tags waits in the mailbox of
/// `pid`, for example `request`, `copy_call` or `tcp`.
@external(erlang, "driver_copy_test_ffi", "wait_for_message")
pub fn wait_for_message(pid: Pid, tags: List(String), attempts: Int) -> Bool

/// Waits until the reset of the peer reached the TCP socket of `pid`.
@external(erlang, "driver_copy_test_ffi", "wait_for_reset")
pub fn wait_for_reset(pid: Pid, attempts: Int) -> Bool

/// Stops a process from taking its messages.
@external(erlang, "sys", "suspend")
pub fn suspend(pid: Pid) -> Nil

/// Lets a process take its messages again.
@external(erlang, "sys", "resume")
pub fn resume(pid: Pid) -> Nil

/// The PostgreSQL 16 server.
pub fn first_server() -> Server {
  case driver_servers() {
    [server, ..] -> server
    [] -> servers.Server(version: 16, port: 5441)
  }
}

/// The settings of a connection as `dream`, with a long reconnect delay.
pub fn config(
  port: Int,
  events: Option(Subject(ConnectionEvent)),
) -> Result(ConnectionConfig, DriverError) {
  use address <- try(
    transport.address("localhost", port)
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  use login_config <- try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password(servers.password),
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  Ok(ConnectionConfig(
    transport: TransportConfig(address, NoTls, 5000, 500),
    login: login_config,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(60_000, 60_000),
    events:,
    notifications: None,
    statements: CacheStatements(statement_cache.default_limit),
  ))
}

/// Starts a connection as `dream`, gives it to `body`, and stops it.
pub fn with_connection(
  port: Int,
  body: fn(Connection) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  use settings <- try(config(port, None))
  use connection <- try(
    connection.start(settings)
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  let value = body(connection)
  connection.stop(connection)
  value
}

/// A connection to the PostgreSQL 16 server through a new proxy, and a
/// control connection straight to it.
pub fn with_setup(
  body: fn(Setup) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  with_setup_over(NoTls, body)
}

/// The same as `with_setup`, with TLS through the proxy, checked against
/// the test CA and the host name.
pub fn with_tls_setup(
  body: fn(Setup) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile("test/fixtures/ssl/ca.crt")),
    PostgresNegotiation,
  )
  |> with_setup_over(body)
}

fn with_setup_over(
  tls: Tls,
  body: fn(Setup) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  let server = first_server()
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  use settings <- try(
    config(port, Some(events)) |> result.map(with_tls(_, tls)),
  )
  use connection <- try(
    connection.start(settings)
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  let value = {
    use control <- with_connection(server.port)
    body(Setup(connection:, control:, proxy:, events:))
  }
  connection.stop(connection)
  value
}

fn with_tls(settings: ConnectionConfig, tls: Tls) -> ConnectionConfig {
  ConnectionConfig(
    ..settings,
    transport: TransportConfig(..settings.transport, tls:),
  )
}

/// Runs a script with a deadline of 5 seconds.
pub fn script(
  connection: Connection,
  sql: String,
) -> Result(List(Outcome), DriverError) {
  connection.run_script(connection, sql, 5000)
}

/// The text of each cell of each outcome, in order.
pub fn texts(outcomes: List(Outcome)) -> List(String) {
  list.flat_map(outcomes, outcome_texts)
}

/// The text of each cell of an outcome, in order.
pub fn outcome_texts(outcome: Outcome) -> List(String) {
  list.flat_map(outcome.result.rows, row_texts)
}

fn row_texts(row: List(Cell)) -> List(String) {
  list.filter_map(row, cell_text)
}

fn cell_text(cell: Cell) -> Result(String, Nil) {
  case cell {
    Text(bytes) -> bit_array.to_string(bytes)
    _ -> Error(Nil)
  }
}

/// The tags of the outcomes, in order.
pub fn tags(outcomes: List(Outcome)) -> List(String) {
  list.map(outcomes, tag)
}

fn tag(outcome: Outcome) -> String {
  outcome.result.tag
}

/// The backend process ID of the connection, as text.
pub fn backend_pid(connection: Connection) -> Result(String, DriverError) {
  script(connection, "SELECT pg_backend_pid()::text")
  |> result.map(texts)
  |> result.map(string.concat)
}

/// Ends the backend `pid` from the control connection, and waits until it
/// is gone. The server sends the backend's client the FATAL error 57P01,
/// then closes its socket.
pub fn terminate_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use _terminated <- try(script(
    control,
    "SELECT pg_terminate_backend(" <> pid <> ", 5000)",
  ))
  Ok(Nil)
}

/// The state of the backend `pid` in pg_stat_activity, from the control
/// connection: none when the backend is gone.
pub fn backend_state(
  control: Connection,
  pid: String,
) -> Result(List(String), DriverError) {
  script(control, "SELECT state FROM pg_stat_activity WHERE pid = " <> pid)
  |> result.map(texts)
}

/// Waits until the backend `pid` is idle, asking the control connection
/// again each time: no sleep.
pub fn wait_until_idle(
  control: Connection,
  pid: String,
  attempts: Int,
) -> Result(Nil, DriverError) {
  use states <- try(backend_state(control, pid))
  case states, attempts {
    ["idle"], _ -> Ok(Nil)
    _, 0 -> Error(ConnectionLost(SocketClosed))
    _, _ -> wait_until_idle(control, pid, attempts - 1)
  }
}

/// The bytes of the ErrorResponse that a server sends when an
/// administrator ends the session: FATAL, 57P01.
pub fn fatal_error_bytes() -> BitArray {
  let body = <<
    "SFATAL":utf8, 0, "VFATAL":utf8, 0, "C57P01":utf8, 0,
    "Mterminating connection due to administrator command":utf8, 0, 0,
  >>
  <<"E", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}
