//// Tests for `dream_postgres/driver/connection`, the connection process,
//// on the driver servers of PostgreSQL 16 to 19. A test proxy between the
//// process and the server breaks the connection on purpose, and a second
//// connection controls the server, so no test sleeps.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type CopyError, type CopySender, type DriverError,
  type Outcome, type StatementCaching, AppFailed, Backoff, CacheStatements,
  ConnectionConfig, ConnectionLost, ConnectionProcessDown, CopyNotRunning,
  CopyNotStarted, CopyStatementRefused, DeadlinePassed, Disconnected,
  DriverFailed, InvalidRequest, LoginRefused, ProtocolViolation, ReconnectFailed,
  Reconnected, ScriptFailed, ServerEndedConnection, ServerRefused, SetupTimedOut,
  TransportRefused, UndecodableMessage, UnexpectedIdleMessage,
  UnexpectedServerMessage, UnnamedStatements,
}
import dream_postgres/driver/login.{PreferChannelBinding, ServerRejectedLogin}
import dream_postgres/driver/message.{
  BindComplete, Protocol30, TooManyItems, UnknownMessageType, ZeroByteInString,
}
import dream_postgres/driver/statement_cache
import dream_postgres/driver/transport.{
  ConnectRefused, ConnectionReset, NoTls, SendTimedOut, SocketClosed,
  TransportConfig,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type ServerReport, Binary, BinaryFormat,
  ColumnDescription, CommandResult, Idle, InFailedTransaction, InTransaction,
  Null, ParameterDescription, StatementDescription, Text,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/result.{try}
import gleam/string.{contains, repeat, starts_with}

@external(erlang, "port_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "driver_proxy_ffi", "start")
fn start_proxy(server_port: Int) -> #(Int, Proxy)

@external(erlang, "driver_proxy_ffi", "inject")
fn inject(proxy: Proxy, bytes: BitArray) -> Nil

@external(erlang, "driver_proxy_ffi", "close_client")
fn close_client(proxy: Proxy) -> Nil

@external(erlang, "driver_proxy_ffi", "reset_client")
fn reset_client(proxy: Proxy) -> Nil

@external(erlang, "driver_proxy_ffi", "answer_next_request")
fn answer_next_request(proxy: Proxy, bytes: BitArray) -> Nil

@external(erlang, "driver_proxy_ffi", "stop_listening")
fn stop_listening(proxy: Proxy) -> Nil

@external(erlang, "driver_proxy_ffi", "watch_client_end")
fn watch_client_end(proxy: Proxy) -> ClientEndWatch

@external(erlang, "driver_proxy_ffi", "client_end")
fn client_end(watch: ClientEndWatch) -> BitArray

@external(erlang, "driver_fake_server_ffi", "start")
fn start_fake_server(behavior: FakeBehavior) -> #(Int, FakeServer)

/// What the fake server does after the first 8 bytes (see the FFI).
type FakeBehavior {
  Answer(BitArray)
}

type FakeServer

@external(erlang, "driver_fake_server_ffi", "start_silent")
fn start_silent_server() -> Int

@external(erlang, "erlang", "send")
fn send_raw(pid: Pid, message: String) -> String

type Proxy

type ClientEndWatch

/// The tests of the connection process.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/connection", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("starting", start_tests()),
    group("losing the connection", loss_tests()),
    group("callers", caller_tests()),
    group("more paths", more_tests()),
    group("the statement cache", map(driver_servers(), cache_tests)),
    group("deadlines on each server", map(driver_servers(), deadline_tests)),
    group("deadlines", more_deadline_tests()),
    group("what dream_model needs", map(driver_servers(), model_tests)),
    group("COPY on each server", map(driver_servers(), copy_tests)),
    group("COPY", copy_more_tests()),
  ])
}

// Settings --------------------------------------------------------------------

fn config(
  port: Int,
  user: String,
  password: String,
  first_delay: Int,
  events: Option(Subject(ConnectionEvent)),
) -> Result(ConnectionConfig, DriverError) {
  use address <- try(
    transport.address("localhost", port)
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  use login_config <- try(
    login.new(
      user:,
      database: servers.database,
      password: login.password(password),
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
    reconnect: Backoff(first_delay, 60_000),
    events:,
    notifications: None,
    statements: CacheStatements(statement_cache.default_limit),
  ))
}

/// Starts a connection as `dream`, gives it to `body`, and stops it.
fn with_connection(
  port: Int,
  body: fn(Connection) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  use settings <- try(config(port, "dream", "dream", 10, None))
  with_started(settings, body)
}

fn with_started(
  settings: ConnectionConfig,
  body: fn(Connection) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  use connection <- try(
    connection.start(settings)
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  let value = body(connection)
  connection.stop(connection)
  value
}

fn script(
  connection: Connection,
  sql: String,
) -> Result(List(Outcome), DriverError) {
  connection.run_script(connection, sql, 5000)
}

fn run(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
) -> Result(Outcome, DriverError) {
  connection.run(connection, sql, parameters, [], 5000)
}

fn tags(outcomes: List(Outcome)) -> List(String) {
  map(outcomes, tag)
}

fn tag(outcome: Outcome) -> String {
  outcome.result.tag
}

fn rows(outcome: Outcome) -> List(List(Cell)) {
  outcome.result.rows
}

fn code(error: DriverError) -> String {
  case error {
    ServerRefused(report, _) -> report.code
    ServerEndedConnection(report) -> report.code
    ScriptFailed(_, report, _) -> report.code
    _ -> "not a server error"
  }
}

fn report_code(report: Option(ServerReport)) -> Option(String) {
  option.map(report, report_code_of)
}

fn report_code_of(report: ServerReport) -> String {
  report.code
}

/// The backend process ID of the connection, as text.
fn backend_pid(connection: Connection) -> Result(String, DriverError) {
  use outcome <- try(run(connection, "SELECT pg_backend_pid()::text", []))
  case rows(outcome) {
    [[Text(pid)]] -> Ok(bit_array_text(pid))
    _ -> Error(ConnectionLost(SocketClosed))
  }
}

fn bit_array_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

/// Ends the backend of `pid` from the control connection. The server sends
/// it the FATAL error 57P01, then closes its socket.
fn terminate_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  script(control, "SELECT pg_terminate_backend(" <> pid <> ")")
  |> result.replace(Nil)
}

fn next_event(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  process.receive(events, 5000)
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("keeps the server_version that the login reported", fn() {
      check_server_version(server)
    }),
    it("prepares a statement", fn() { check_prepare(server) }),
    it("runs a statement with a binary parameter and a binary result", fn() {
      check_run(server)
    }),
    it("runs a script with one outcome for each statement", fn() {
      check_script(server)
    }),
    it("answers a COMMIT of a failed transaction with ROLLBACK", fn() {
      check_commit_of_failed_transaction(server)
    }),
    it("knows the transaction status after BEGIN", fn() {
      check_transaction_status(server)
    }),
    it("gives the notices and notifications with the outcome", fn() {
      check_notices_and_notifications(server)
    }),
  ])
}

fn check_server_version(server: Server) {
  // Act
  let version = {
    use connection <- with_connection(server.port)
    connection.server_parameter(connection, "server_version")
  }

  // Assert
  version
  |> result.map(option.map(_, starts_with(_, to_string(server.version) <> ".")))
  |> should
  |> be_equal(Ok(Some(True)))
  |> or_fail_with("Expected the server_version of the server")
}

fn check_prepare(server: Server) {
  // Act
  let description = {
    use connection <- with_connection(server.port)
    connection.prepare(
      connection,
      "SELECT relname FROM pg_class WHERE oid = $1",
      5000,
    )
  }

  // Assert
  description
  |> should
  |> be_equal(
    Ok(
      StatementDescription(parameters: [ParameterDescription(26)], columns: [
        ColumnDescription("relname", 19, -1, 1259, 2),
      ]),
    ),
  )
  |> or_fail_with("Expected the description of the statement")
}

fn check_run(server: Server) {
  // Act
  let result = {
    use connection <- with_connection(server.port)
    connection.run(
      connection,
      "SELECT $1::int4 + 1",
      [Binary(<<41:32>>)],
      [
        BinaryFormat,
      ],
      5000,
    )
    |> result.map(outcome_result)
  }

  // Assert
  result
  |> should
  |> be_equal(
    Ok(#(
      [ColumnDescription("?column?", 23, -1, 0, 0)],
      CommandResult(rows: [[Binary(<<42:32>>)]], tag: "SELECT 1", count: 1),
    )),
  )
  |> or_fail_with("Expected 42 as a binary int4")
}

fn outcome_result(outcome: Outcome) {
  #(outcome.columns, outcome.result)
}

fn check_script(server: Server) {
  // Act
  let script_tags = {
    use connection <- with_connection(server.port)
    script(
      connection,
      "CREATE TEMP TABLE t (id int); INSERT INTO t VALUES (1); SELECT id FROM t",
    )
    |> result.map(tags)
  }

  // Assert
  script_tags
  |> should
  |> be_equal(Ok(["CREATE TABLE", "INSERT 0 1", "SELECT 1"]))
  |> or_fail_with("Expected one tag for each statement")
}

/// A statement fails inside a transaction: aborted_by gives its report,
/// COMMIT through run_script answers with the tag ROLLBACK, and aborted_by
/// gives nothing after it.
fn check_commit_of_failed_transaction(server: Server) {
  // Act
  let answers = {
    use connection <- with_connection(server.port)
    use _begun <- try(script(connection, "BEGIN"))
    let failed = run(connection, "SELECT 1/0", []) |> result.map_error(code)
    use before <- try(connection.aborted_by(connection))
    use committed <- try(script(connection, "COMMIT"))
    use after <- try(connection.aborted_by(connection))
    Ok(#(failed, report_code(before), tags(committed), report_code(after)))
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error("22012"), Some("22012"), ["ROLLBACK"], None)))
  |> or_fail_with("Expected 22012, then the tag ROLLBACK, then no report")
}

fn check_transaction_status(server: Server) {
  // Act
  let statuses = {
    use connection <- with_connection(server.port)
    use _begun <- try(script(connection, "BEGIN"))
    use in_transaction <- try(connection.transaction_status(connection))
    use _failed <- try(script(connection, "SELECT 1/0") |> result.or(Ok([])))
    use failed <- try(connection.transaction_status(connection))
    use _rolled_back <- try(script(connection, "ROLLBACK"))
    use idle <- try(connection.transaction_status(connection))
    Ok(#(in_transaction, failed, idle))
  }

  // Assert
  statuses
  |> should
  |> be_equal(Ok(#(InTransaction, InFailedTransaction, Idle)))
  |> or_fail_with("Expected the three statuses")
}

fn check_notices_and_notifications(server: Server) {
  // Act
  let messages = {
    use connection <- with_connection(server.port)
    use outcomes <- try(script(
      connection,
      "LISTEN jobs; DO $$ BEGIN RAISE NOTICE 'hello'; END $$; NOTIFY jobs, 'done'",
    ))
    Ok(map(outcomes, notices_and_notifications))
  }

  // Assert
  messages
  |> should
  |> be_equal(Ok([#([], []), #([], []), #(["hello"], [#("jobs", "done")])]))
  |> or_fail_with(
    "Expected the notice and the notification on the last outcome",
  )
}

fn notices_and_notifications(outcome: Outcome) {
  #(
    map(outcome.notices, notice_message),
    map(outcome.notifications, notification_parts),
  )
}

fn notice_message(report: ServerReport) -> String {
  report.message
}

fn notification_parts(notification: connection.Notification) {
  #(notification.channel, notification.payload)
}

// Starting --------------------------------------------------------------------

fn first_server() -> Server {
  case driver_servers() {
    [server, ..] -> server
    [] -> servers.Server(version: 16, port: 5441)
  }
}

fn start_tests() {
  [
    it("gives the server's 28P01 for a wrong password", fn() {
      // Arrange
      let settings = config(first_server().port, "dream", "wrong", 10, None)

      // Act
      let started = settings |> result.map(connection.start)

      // Assert
      started
      |> result.map(result.map_error(_, connect_error_code))
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error("28P01")))
      |> or_fail_with("Expected the login refusal 28P01")
    }),
    it("gives TransportRefused for a port with no listener", fn() {
      // Arrange
      let settings = config(free_port(), "dream", "dream", 10, None)

      // Act
      let started = settings |> result.map(connection.start)

      // Assert
      started
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(TransportRefused(ConnectRefused))))
      |> or_fail_with("Expected TransportRefused(ConnectRefused)")
    }),
    it("gives SetupTimedOut for a server that never answers", fn() {
      // Arrange
      let port = start_silent_server()
      let settings =
        config(port, "dream", "dream", 10, None)
        |> result.map(short_setup)

      // Act
      let started = settings |> result.map(connection.start)

      // Assert
      started
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(SetupTimedOut)))
      |> or_fail_with("Expected SetupTimedOut")
    }),
    it("sends Terminate when it stops", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_server().port)

      // Act
      let last_bytes = {
        use settings <- try(config(port, "dream", "dream", 10, None))
        use started <- try(
          connection.start(settings)
          |> result.replace_error(ConnectionLost(SocketClosed)),
        )
        let watch = watch_client_end(proxy)
        connection.stop(started)
        Ok(client_end(watch))
      }

      // Assert
      last_bytes
      |> should
      |> be_equal(Ok(<<"X", 4:32>>))
      |> or_fail_with("Expected a Terminate as the last bytes")
    }),
    it("gives ConnectionProcessDown after it stopped", fn() {
      // Act
      let status = {
        use settings <- try(config(
          first_server().port,
          "dream",
          "dream",
          10,
          None,
        ))
        use started <- try(
          connection.start(settings)
          |> result.replace_error(ConnectionLost(SocketClosed)),
        )
        connection.stop(started)
        connection.transaction_status(started)
      }

      // Assert
      status
      |> should
      |> be_equal(Error(ConnectionProcessDown))
      |> or_fail_with("Expected ConnectionProcessDown")
    }),
  ]
}

fn with_caching(
  settings: ConnectionConfig,
  caching: StatementCaching,
) -> ConnectionConfig {
  ConnectionConfig(..settings, statements: caching)
}

fn short_setup(settings: ConnectionConfig) -> ConnectionConfig {
  ConnectionConfig(..settings, setup_timeout_milliseconds: 100)
}

fn connect_error_code(error: ConnectError) -> String {
  case error {
    LoginRefused(ServerRejectedLogin(report)) -> report.code
    _ -> "not a login refusal"
  }
}

// Losing the connection ---------------------------------------------------------

/// A connection through a proxy, with its events, and a control connection
/// straight to the server.
type Setup {
  Setup(
    connection: Connection,
    control: Connection,
    proxy: Proxy,
    events: Subject(ConnectionEvent),
  )
}

fn with_setup(
  first_delay: Int,
  body: fn(Setup) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  with_caching_setup(
    first_delay,
    CacheStatements(statement_cache.default_limit),
    body,
  )
}

fn with_caching_setup(
  first_delay: Int,
  caching: StatementCaching,
  body: fn(Setup) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  let server = first_server()
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  use settings <- try(
    config(port, "dream", "dream", first_delay, Some(events))
    |> result.map(with_caching(_, caching)),
  )
  use connection <- with_started(settings)
  use control <- with_connection(server.port)
  body(Setup(connection:, control:, proxy:, events:))
}

fn loss_tests() {
  [
    it("notices at once when the server ends an idle session", fn() {
      // Act
      let events = {
        use setup <- with_setup(10)
        use pid <- try(backend_pid(setup.connection))
        use Nil <- try(terminate_backend(setup.control, pid))
        Ok(#(
          next_event(setup.events) |> result.map(event_code),
          next_event(setup.events) |> result.map(event_code),
        ))
      }

      // Assert
      events
      |> should
      |> be_equal(Ok(#(Ok("disconnected 57P01"), Ok("reconnected"))))
      |> or_fail_with("Expected the loss, then the reconnect")
    }),
    it("runs a statement again after it reconnected", fn() {
      // Act
      let tag = {
        use setup <- with_setup(10)
        use pid <- try(backend_pid(setup.connection))
        use Nil <- try(terminate_backend(setup.control, pid))
        let _lost = next_event(setup.events)
        let _back = next_event(setup.events)
        script(setup.connection, "SELECT 1") |> result.map(tags)
      }

      // Assert
      tag
      |> should
      |> be_equal(Ok(["SELECT 1"]))
      |> or_fail_with("Expected SELECT 1 on the new session")
    }),
    it("fails a request while the connection is lost", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use pid <- try(backend_pid(setup.connection))
        use Nil <- try(terminate_backend(setup.control, pid))
        let _lost = next_event(setup.events)
        send_stray_message(setup.connection)
        Ok(script(setup.connection, "SELECT 1") |> result.map_error(code))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("57P01")))
      |> or_fail_with("Expected the error of the loss")
    }),
    loss_event_test("a close by the network", close_client, "lost closed"),
    loss_event_test("a reset by the network", reset_client, "lost reset"),
    loss_event_test(
      "bytes that are not a message",
      inject_garbage,
      "violation undecodable",
    ),
    loss_event_test(
      "a message between requests that is not allowed",
      inject_bind_complete,
      "violation idle",
    ),
    it("fails a running request with the loss and the waiting ones too", fn() {
      check_running_and_waiting_fail()
    }),
    it("gives a violation to the running request", fn() {
      check_running_violation()
    }),
    it("fails a send that the server never reads", fn() { check_send_timeout() }),
    it("tells of a failed reconnect, and tries again", fn() {
      check_reconnect_failed()
    }),
    it("ignores a message that is not about its socket", fn() {
      // Act
      let tag = {
        use setup <- with_setup(10)
        send_stray_message(setup.connection)
        script(setup.connection, "SELECT 1") |> result.map(tags)
      }

      // Assert
      tag
      |> should
      |> be_equal(Ok(["SELECT 1"]))
      |> or_fail_with("Expected the connection to work")
    }),
  ]
}

@external(erlang, "driver_connection_test_ffi", "pid_of")
fn pid_of(connection: Connection) -> Pid

fn send_stray_message(connection: Connection) -> Nil {
  let _sent = send_raw(pid_of(connection), "not a socket message")
  Nil
}

fn inject_garbage(proxy: Proxy) -> Nil {
  inject(proxy, <<"x", 4:32>>)
}

fn inject_bind_complete(proxy: Proxy) -> Nil {
  inject(proxy, <<"2", 4:32>>)
}

fn loss_event_test(name: String, breaking: fn(Proxy) -> Nil, expected: String) {
  it("tells of " <> name, fn() { check_loss_event(breaking, expected) })
}

fn check_loss_event(breaking: fn(Proxy) -> Nil, expected: String) {
  // Act
  let event = {
    use setup <- with_setup(60_000)
    breaking(setup.proxy)
    Ok(next_event(setup.events) |> result.map(event_code))
  }

  // Assert
  event
  |> should
  |> be_equal(Ok(Ok(expected)))
  |> or_fail_with("Expected the event " <> expected)
}

fn event_code(event: ConnectionEvent) -> String {
  case event {
    Disconnected(ServerEndedConnection(report)) ->
      "disconnected " <> report.code
    Disconnected(ConnectionLost(SocketClosed)) -> "lost closed"
    Disconnected(ConnectionLost(ConnectionReset)) -> "lost reset"
    Disconnected(ConnectionLost(SendTimedOut)) -> "lost send timeout"
    Disconnected(ProtocolViolation(UndecodableMessage(UnknownMessageType(_)))) ->
      "violation undecodable"
    Disconnected(ProtocolViolation(UnexpectedIdleMessage(BindComplete))) ->
      "violation idle"
    Disconnected(ProtocolViolation(UnexpectedServerMessage(_))) ->
      "violation running"
    ReconnectFailed(LoginRefused(ServerRejectedLogin(report))) ->
      "reconnect failed " <> report.code
    Disconnected(DeadlinePassed(cancelled: False)) -> "lost at deadline"
    Reconnected -> "reconnected"
    _ -> "another event"
  }
}

/// A caller waits on an advisory lock that the control connection holds,
/// a second request waits behind it, and the server ends the session: both
/// get the error of the loss.
fn check_running_and_waiting_fail() {
  // Act
  let answers = {
    use setup <- with_setup(60_000)
    use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(823)"))
    let running = start_caller(setup.connection, "SELECT pg_advisory_lock(823)")
    use Nil <- try(wait_for_lock_waiter(setup.control, 823, 5000))
    let waiting = start_caller(setup.connection, "SELECT 1")
    use pid <- try(backend_pid_from_control(setup.control, 823))
    use Nil <- try(terminate_backend(setup.control, pid))
    let answers = #(caller_answer(running), caller_answer(waiting))
    use _unlocked <- try(script(setup.control, "SELECT pg_advisory_unlock(823)"))
    Ok(answers)
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error("57P01"), Error("57P01"))))
  |> or_fail_with("Expected the loss for both requests")
}

fn check_running_violation() {
  // Act
  let answer = {
    use setup <- with_setup(60_000)
    use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(824)"))
    let running = start_caller(setup.connection, "SELECT pg_advisory_lock(824)")
    use Nil <- try(wait_for_lock_waiter(setup.control, 824, 5000))
    inject_bind_complete(setup.proxy)
    let answer = caller_error(running)
    use _unlocked <- try(script(setup.control, "SELECT pg_advisory_unlock(824)"))
    Ok(answer)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok("violation running"))
  |> or_fail_with("Expected a protocol violation for the running request")
}

/// The proxy reads the first bytes of a large script, answers them with a
/// CopyInResponse as if the server did, and reads nothing more. The step
/// answers with a CopyFail, whose send waits behind the rest of the script
/// in the socket's queue and fails after the send timeout of 500
/// milliseconds.
fn check_send_timeout() {
  // Act
  let answer = {
    use setup <- with_setup(60_000)
    answer_next_request(setup.proxy, <<"G", 7:32, 0, 0:16>>)
    let large = "SELECT '" <> repeat("x", 64_000_000) <> "'"
    Ok(script(setup.connection, large) |> result.replace(Nil))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(Error(ConnectionLost(SendTimedOut))))
  |> or_fail_with("Expected the loss by a send timeout")
}

/// The password of dream_reconnect changes while it is logged in, so the
/// reconnect fails with 28P01. The password goes back, and the next
/// attempt works.
fn check_reconnect_failed() {
  // Act
  let events = {
    let server = first_server()
    let events = process.new_subject()
    use settings <- try(config(
      server.port,
      "dream_reconnect",
      "dream",
      10,
      Some(events),
    ))
    use connection <- with_started(settings)
    use control <- with_connection(server.port)
    use pid <- try(backend_pid(connection))
    use _changed <- try(script(
      control,
      "ALTER ROLE dream_reconnect PASSWORD 'other'",
    ))
    use Nil <- try(terminate_backend(control, pid))
    let lost = next_event(events) |> result.map(event_code)
    let failed = next_event(events) |> result.map(event_code)
    use _restored <- try(script(
      control,
      "ALTER ROLE dream_reconnect PASSWORD 'dream'",
    ))
    let back = skip_failures(events)
    Ok(#(lost, failed, back))
  }

  // Assert
  events
  |> should
  |> be_equal(
    Ok(#(
      Ok("disconnected 57P01"),
      Ok("reconnect failed 28P01"),
      Ok("reconnected"),
    )),
  )
  |> or_fail_with("Expected the loss, a failed reconnect, then the reconnect")
}

/// Reads events until one that is not a failed reconnect.
fn skip_failures(events: Subject(ConnectionEvent)) -> Result(String, Nil) {
  case next_event(events) |> result.map(event_code) {
    Ok("reconnect failed 28P01") -> skip_failures(events)
    other -> other
  }
}

// Callers ---------------------------------------------------------------------

/// A caller process that runs one script and sends its answer back.
type Caller {
  Caller(answers: Subject(Result(List(Outcome), DriverError)), pid: Pid)
}

fn start_caller(connection: Connection, sql: String) -> Caller {
  let answers = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { caller_body(connection, sql, answers) })
  Caller(answers:, pid:)
}

fn caller_body(
  connection: Connection,
  sql: String,
  answers: Subject(Result(List(Outcome), DriverError)),
) -> Nil {
  process.send(answers, script(connection, sql))
}

fn caller_answer(caller: Caller) -> Result(List(String), String) {
  case process.receive(caller.answers, 5000) {
    Ok(answer) -> answer |> result.map(tags) |> result.map_error(code)
    Error(Nil) -> Error("no answer")
  }
}

fn caller_error(caller: Caller) -> String {
  case process.receive(caller.answers, 5000) {
    Ok(Error(error)) -> event_code(Disconnected(error))
    _ -> "no error"
  }
}

/// Waits until the server has a session that waits for an advisory lock.
/// It asks the control connection again each time: no sleep.
fn wait_for_lock_waiter(
  control: Connection,
  key: Int,
  attempts: Int,
) -> Result(Nil, DriverError) {
  use outcomes <- try(script(control, lock_waiters(key, "count(*)::text")))
  case map(outcomes, rows), attempts {
    [[[Text(<<"1">>)]]], _ -> Ok(Nil)
    _, 0 -> Error(ConnectionLost(SocketClosed))
    _, _ -> wait_for_lock_waiter(control, key, attempts - 1)
  }
}

/// The sessions of the server that wait for the advisory lock `key`.
/// Other tests use other keys at the same time.
fn lock_waiters(key: Int, column: String) -> String {
  "SELECT "
  <> column
  <> " FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid = "
  <> to_string(key)
}

/// The backend that waits for an advisory lock.
fn backend_pid_from_control(
  control: Connection,
  key: Int,
) -> Result(String, DriverError) {
  use outcomes <- try(script(control, lock_waiters(key, "pid::text")))
  case map(outcomes, rows) {
    [[[Text(pid)]]] -> Ok(bit_array_text(pid))
    _ -> Error(ConnectionLost(SocketClosed))
  }
}

fn caller_tests() {
  [
    it("stays usable after a caller is killed mid-query", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(825)"))
        let caller =
          start_caller(setup.connection, "SELECT pg_advisory_lock(825)")
        use Nil <- try(wait_for_lock_waiter(setup.control, 825, 5000))
        process.kill(caller.pid)
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(825)",
        ))
        use outcome <- try(run(setup.connection, "SELECT 2", []))
        Ok(rows(outcome))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok([[Text(<<"2">>)]]))
      |> or_fail_with("Expected the next query's own result")
    }),
    it("runs a request that waited behind another", fn() {
      // Act
      let answers = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(827)"))
        let first =
          start_caller(setup.connection, "SELECT pg_advisory_lock(827)")
        use Nil <- try(wait_for_lock_waiter(setup.control, 827, 5000))
        let second = start_caller(setup.connection, "SELECT 4")
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(827)",
        ))
        Ok(#(caller_answer(first), caller_answer(second)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(["SELECT 1"]), Ok(["SELECT 1"]))))
      |> or_fail_with("Expected both requests to run, in order")
    }),
    it("refuses SQL with a zero byte before it sends anything", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        Ok(run(connection, "SELECT 1\u{0000}", []) |> result.replace(Nil))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(InvalidRequest(ZeroByteInString("query")))))
      |> or_fail_with("Expected InvalidRequest")
    }),
    it("refuses a COPY statement and stays usable", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        let refused = script(connection, "SELECT 1; COPY (SELECT 1) TO STDOUT")
        use next <- try(script(connection, "SELECT 5"))
        Ok(#(refused |> result.map_error(copy_completed), tags(next)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(["SELECT 1"]), ["SELECT 1"])))
      |> or_fail_with("Expected the refusal with the statement before it")
    }),
    it("gives ScriptFailed with the statements that ran", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        Ok(
          script(connection, "SELECT 1; SELECT 1/0")
          |> result.map_error(script_failure),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(#(["SELECT 1"], "22012"))))
      |> or_fail_with("Expected the completed statement and 22012")
    }),
    it("refuses a prepare that the server refuses", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        Ok(
          connection.prepare(connection, "SELECT * FROM no_such_table", 5000)
          |> result.map_error(code),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("42P01")))
      |> or_fail_with("Expected 42P01")
    }),
    it("binds a NULL parameter", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        run(connection, "SELECT $1::text IS NULL", [Null]) |> result.map(rows)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok([[Text(<<"t">>)]]))
      |> or_fail_with("Expected true")
    }),
  ]
}

fn copy_completed(error: DriverError) -> List(String) {
  case error {
    CopyStatementRefused(completed) -> tags(completed)
    _ -> ["not a copy refusal"]
  }
}

fn script_failure(error: DriverError) -> #(List(String), String) {
  case error {
    ScriptFailed(completed, report, _) -> #(tags(completed), report.code)
    _ -> #([], "not a script failure")
  }
}

// More paths ------------------------------------------------------------------

fn verify_full_config(port: Int) -> Result(ConnectionConfig, DriverError) {
  use settings <- try(config(port, "dream", "dream", 10, None))
  Ok(
    ConnectionConfig(
      ..settings,
      transport: TransportConfig(
        ..settings.transport,
        tls: transport.RequireTls(
          transport.CheckAuthorityAndHost(transport.AuthorityFile(
            "test/fixtures/ssl/ca.crt",
          )),
          transport.PostgresNegotiation,
        ),
      ),
    ),
  )
}

/// Starts the connection in a process that then ends, and gives what the
/// starter saw.
fn start_in_owner(start: fn() -> Result(Nil, Nil)) -> Result(Nil, Nil) {
  let answers = process.new_subject()
  process.spawn_unlinked(fn() { owner_body(start, answers) })
  process.receive(answers, 5000) |> result.flatten
}

/// The owner traps exits, so a supervisor that fails to start does not
/// take the owner down before it reports.
fn owner_body(
  start: fn() -> Result(Nil, Nil),
  answers: Subject(Result(Nil, Nil)),
) -> Nil {
  process.trap_exits(True)
  process.send(answers, start())
}

fn start_connection_only(settings: ConnectionConfig) -> Result(Nil, Nil) {
  connection.start(settings) |> result.replace(Nil) |> result.replace_error(Nil)
}

fn start_supervised(settings: ConnectionConfig) -> Result(Nil, Nil) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(connection.supervised(settings))
  |> static_supervisor.start
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}

fn more_tests() {
  [
    it("runs a statement over TLS", fn() {
      // Act
      let tag = {
        use settings <- try(verify_full_config(first_server().port))
        use connection <- with_started(settings)
        script(connection, "SELECT 1") |> result.map(tags)
      }

      // Assert
      tag
      |> should
      |> be_equal(Ok(["SELECT 1"]))
      |> or_fail_with("Expected SELECT 1 over TLS")
    }),
    it("sends Terminate when the process that started it ends", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_server().port)

      // Act
      let last_bytes = {
        use settings <- try(config(port, "dream", "dream", 10, None))
        let watch = watch_client_end(proxy)
        let _started = start_in_owner(fn() { start_connection_only(settings) })
        Ok(client_end(watch))
      }

      // Assert
      last_bytes
      |> should
      |> be_equal(Ok(<<"X", 4:32>>))
      |> or_fail_with("Expected a Terminate when the owner ended")
    }),
    it("starts under a supervisor", fn() {
      // Act
      let started = {
        use settings <- try(config(
          first_server().port,
          "dream",
          "dream",
          10,
          None,
        ))
        Ok(start_in_owner(fn() { start_supervised(settings) }))
      }

      // Assert
      started
      |> should
      |> be_equal(Ok(Ok(Nil)))
      |> or_fail_with("Expected the supervisor to start the connection")
    }),
    it("fails the supervisor's start when it cannot connect", fn() {
      // Act
      let started = {
        use settings <- try(config(free_port(), "dream", "dream", 10, None))
        Ok(start_in_owner(fn() { start_supervised(settings) }))
      }

      // Assert
      started
      |> should
      |> be_equal(Ok(Error(Nil)))
      |> or_fail_with("Expected the supervisor's start to fail")
    }),
    it("gives LoginUndecodable for bytes that are not a message", fn() {
      // Arrange
      let #(port, _server) = start_fake_server(Answer(<<"x", 4:32>>))

      // Act
      let started = {
        use settings <- try(config(port, "dream", "dream", 10, None))
        Ok(connection.start(settings) |> result.replace(Nil))
      }

      // Assert
      started
      |> should
      |> be_equal(
        Ok(Error(connection.LoginUndecodable(UnknownMessageType(120)))),
      )
      |> or_fail_with("Expected LoginUndecodable")
    }),
    it("refuses a prepare and a script with a zero byte", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        let prepared = connection.prepare(connection, "SELECT 1\u{0000}", 5000)
        let scripted = script(connection, "SELECT 1\u{0000}")
        Ok(#(prepared |> result.replace(Nil), scripted |> result.replace(Nil)))
      }

      // Assert
      answers
      |> should
      |> be_equal(
        Ok(#(
          Error(InvalidRequest(ZeroByteInString("query"))),
          Error(InvalidRequest(ZeroByteInString("query"))),
        )),
      )
      |> or_fail_with("Expected InvalidRequest for both")
    }),
    it("fails a prepare while the connection is lost", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        close_client(setup.proxy)
        let _lost = next_event(setup.events)
        Ok(
          connection.prepare(setup.connection, "SELECT 1", 5000)
          |> result.replace(Nil),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(ConnectionLost(SocketClosed))))
      |> or_fail_with("Expected the error of the loss")
    }),
    it(
      "keeps the parameter changes, notices and notifications between requests",
      fn() { check_idle_messages() },
    ),
    it("keeps a parameter change during a script", fn() {
      // Act
      let name = {
        use connection <- with_connection(first_server().port)
        use _set <- try(script(
          connection,
          "SET application_name = 'during a script'",
        ))
        connection.server_parameter(connection, "application_name")
      }

      // Assert
      name
      |> should
      |> be_equal(Ok(Some("during a script")))
      |> or_fail_with("Expected the new application_name")
    }),
    it("fails the running request when the network closes", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(828)"))
        let running =
          start_caller(setup.connection, "SELECT pg_advisory_lock(828)")
        use Nil <- try(wait_for_lock_waiter(setup.control, 828, 5000))
        close_client(setup.proxy)
        let answer = caller_error(running)
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(828)",
        ))
        Ok(answer)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok("lost closed"))
      |> or_fail_with("Expected the loss for the running request")
    }),
    it("fails a running cached run when the network closes", fn() {
      check_running_lost(RunCaller, Cached)
    }),
    it("fails a running named prepare when the network closes", fn() {
      check_running_lost(PrepareCaller, Cached)
    }),
    it("fails a running unnamed run when the network closes", fn() {
      check_running_lost(RunCaller, Unnamed)
    }),
    it("fails a running unnamed prepare when the network closes", fn() {
      check_running_lost(PrepareCaller, Unnamed)
    }),
    it("refuses COPY FROM STDIN in a run and stays usable", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use _created <- try(script(connection, "CREATE TEMP TABLE c (x int)"))
        let refused = run(connection, "COPY c FROM STDIN", [])
        use next <- try(script(connection, "SELECT 6"))
        Ok(#(
          refused |> result.map_error(copy_completed) |> result.replace(Nil),
          tags(next),
        ))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error([]), ["SELECT 1"])))
      |> or_fail_with("Expected the refusal, then SELECT 1")
    }),
  ]
}

/// The proxy sends a ParameterStatus and a NoticeResponse as if the server
/// sent them between requests, and the control connection notifies a
/// channel that the connection listens to. The next outcome carries the
/// notice and the notification, and the parameter has its new value.
fn check_idle_messages() {
  // Act
  let seen = {
    use setup <- with_setup(60_000)
    inject(
      setup.proxy,
      bit_array.concat([
        notice("an idle notice"),
        notification(4321, "idle_jobs", "idle"),
        parameter_status("application_name", "injected"),
      ]),
    )
    use Nil <- try(wait_for_parameter(setup.connection, "injected", 5000))
    use outcomes <- try(script(setup.connection, "SELECT 1"))
    Ok(map(outcomes, notices_and_notifications))
  }

  // Assert
  seen
  |> should
  |> be_equal(Ok([#(["an idle notice"], [#("idle_jobs", "idle")])]))
  |> or_fail_with("Expected the notice and the notification of the idle time")
}

/// Asks for application_name until it is `value`. The snapshot request
/// comes after the injected bytes, so once the value is there, the process
/// handled all of them while it was idle. No sleep.
fn wait_for_parameter(
  connection: Connection,
  value: String,
  attempts: Int,
) -> Result(Nil, DriverError) {
  use name <- try(connection.server_parameter(connection, "application_name"))
  case name == Some(value), attempts {
    True, _ -> Ok(Nil)
    False, 0 -> Error(ConnectionLost(SocketClosed))
    False, _ -> wait_for_parameter(connection, value, attempts - 1)
  }
}

fn notification(process_id: Int, channel: String, payload: String) -> BitArray {
  let body = <<process_id:32, channel:utf8, 0, payload:utf8, 0>>
  <<"A", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn parameter_status(name: String, value: String) -> BitArray {
  let body = <<name:utf8, 0, value:utf8, 0>>
  <<"S", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn notice(text: String) -> BitArray {
  let body = <<
    "S", "NOTICE":utf8, 0, "V", "NOTICE":utf8, 0, "C", "00000":utf8, 0, "M",
    text:utf8, 0, 0,
  >>
  <<"N", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

type CallerKind {
  RunCaller
  PrepareCaller
}

/// Whether the connection of the test caches statements. Each kind uses
/// its own lock key and table, so the tests can run at the same time.
type Caching {
  Cached
  Unnamed
}

fn caching_setting(caching: Caching) -> StatementCaching {
  case caching {
    Cached -> CacheStatements(statement_cache.default_limit)
    Unnamed -> UnnamedStatements
  }
}

fn lock_key(caching: Caching) -> Int {
  case caching {
    Cached -> 830
    Unnamed -> 831
  }
}

fn lock_table(caching: Caching) -> String {
  case caching {
    Cached -> "driver_prepare_lock_cached"
    Unnamed -> "driver_prepare_lock_unnamed"
  }
}

/// A run waits on an advisory lock. A prepare waits on a table that the
/// control connection locks: its Parse needs a lock on the table too. The
/// proxy closes the connection, and the caller gets the loss.
fn check_running_lost(kind: CallerKind, caching: Caching) {
  // Act
  let answer = {
    use setup <- with_caching_setup(60_000, caching_setting(caching))
    use _held <- try(hold_lock(setup.control, kind, caching))
    let answers = process.new_subject()
    process.spawn_unlinked(fn() {
      blocked_call(setup.connection, kind, caching, answers)
    })
    use Nil <- try(wait_for_blocked(setup.control, kind, caching, 5000))
    close_client(setup.proxy)
    let answer = process.receive(answers, 5000)
    use _released <- try(release_lock(setup.control, kind, caching))
    Ok(answer)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(Ok(Error(ConnectionLost(SocketClosed)))))
  |> or_fail_with("Expected the loss for the running request")
}

fn hold_lock(
  control: Connection,
  kind: CallerKind,
  caching: Caching,
) -> Result(List(Outcome), DriverError) {
  let table = lock_table(caching)
  case kind {
    RunCaller ->
      script(
        control,
        "SELECT pg_advisory_lock(" <> to_string(lock_key(caching)) <> ")",
      )
    PrepareCaller -> {
      use _created <- try(script(
        control,
        "CREATE TABLE IF NOT EXISTS " <> table <> " (x int)",
      ))
      script(
        control,
        "BEGIN; LOCK TABLE " <> table <> " IN ACCESS EXCLUSIVE MODE",
      )
    }
  }
}

fn release_lock(
  control: Connection,
  kind: CallerKind,
  caching: Caching,
) -> Result(List(Outcome), DriverError) {
  case kind {
    RunCaller ->
      script(
        control,
        "SELECT pg_advisory_unlock(" <> to_string(lock_key(caching)) <> ")",
      )
    PrepareCaller -> script(control, "ROLLBACK")
  }
}

fn blocked_call(
  connection: Connection,
  kind: CallerKind,
  caching: Caching,
  answers: Subject(Result(Nil, DriverError)),
) -> Nil {
  let answer = case kind {
    RunCaller ->
      run(
        connection,
        "SELECT pg_advisory_lock(" <> to_string(lock_key(caching)) <> ")",
        [],
      )
      |> result.replace(Nil)
    PrepareCaller ->
      connection.prepare(
        connection,
        "SELECT x FROM " <> lock_table(caching),
        5000,
      )
      |> result.replace(Nil)
  }
  process.send(answers, answer)
}

fn wait_for_blocked(
  control: Connection,
  kind: CallerKind,
  caching: Caching,
  attempts: Int,
) -> Result(Nil, DriverError) {
  case kind {
    RunCaller -> wait_for_lock_waiter(control, lock_key(caching), attempts)
    PrepareCaller ->
      wait_for_table_waiter(control, lock_table(caching), attempts)
  }
}

fn wait_for_table_waiter(
  control: Connection,
  table: String,
  attempts: Int,
) -> Result(Nil, DriverError) {
  use outcomes <- try(script(
    control,
    "SELECT count(*)::text FROM pg_locks WHERE locktype = 'relation' AND NOT granted AND relation = '"
      <> table
      <> "'::regclass",
  ))
  case map(outcomes, rows), attempts {
    [[[Text(<<"1">>)]]], _ -> Ok(Nil)
    _, 0 -> Error(ConnectionLost(SocketClosed))
    _, _ -> wait_for_table_waiter(control, table, attempts - 1)
  }
}

// The statement cache -------------------------------------------------------

fn with_caching_connection(
  port: Int,
  caching: StatementCaching,
  body: fn(Connection) -> Result(value, DriverError),
) -> Result(value, DriverError) {
  use settings <- try(
    config(port, "dream", "dream", 10, None)
    |> result.map(with_caching(_, caching)),
  )
  with_started(settings, body)
}

/// The prepared statements of the connection, from pg_prepared_statements,
/// as "name executions" in name order. A script runs with the simple
/// protocol, so it adds no statement of its own.
fn prepared_statements(
  connection: Connection,
) -> Result(List(String), DriverError) {
  use outcomes <- try(script(
    connection,
    "SELECT name || ' ' || (generic_plans + custom_plans)::text FROM pg_prepared_statements ORDER BY name",
  ))
  Ok(list.flat_map(outcomes, row_texts))
}

fn row_texts(outcome: Outcome) -> List(String) {
  list.flat_map(rows(outcome), cell_texts)
}

fn cell_texts(row: List(Cell)) -> List(String) {
  list.filter_map(row, cell_text)
}

fn cell_text(cell: Cell) -> Result(String, Nil) {
  case cell {
    Text(bytes) -> bit_array.to_string(bytes)
    _ -> Error(Nil)
  }
}

fn cache_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("prepares a statement one time and runs it again by its name", fn() {
      // Act
      let statements = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _first <- try(run(connection, "SELECT 41 + 1", []))
        use _second <- try(run(connection, "SELECT 41 + 1", []))
        prepared_statements(connection)
      }

      // Assert
      statements
      |> should
      |> be_equal(Ok(["dream_postgres_1 2"]))
      |> or_fail_with("Expected one named statement that ran two times")
    }),
    it("prepares a statement one time for two prepares", fn() {
      // Act
      let statements = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use first <- try(connection.prepare(connection, "SELECT 1", 5000))
        use second <- try(connection.prepare(connection, "SELECT 1", 5000))
        use statements <- try(prepared_statements(connection))
        Ok(#(first == second, statements))
      }

      // Assert
      statements
      |> should
      |> be_equal(Ok(#(True, ["dream_postgres_1 0"])))
      |> or_fail_with("Expected one statement and the same description")
    }),
    it("closes the least recently used statement when the cache is full", fn() {
      // Act
      let statements = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(2),
        )
        use _a <- try(run(connection, "SELECT 'a'", []))
        use _b <- try(run(connection, "SELECT 'b'", []))
        use _a_again <- try(run(connection, "SELECT 'a'", []))
        use _c <- try(run(connection, "SELECT 'c'", []))
        prepared_statements(connection)
      }

      // Assert
      statements
      |> should
      |> be_equal(Ok(["dream_postgres_1 2", "dream_postgres_3 1"]))
      |> or_fail_with("Expected b to be closed, as the least recently used")
    }),
    it("prepares again and runs when the statement is gone (26000)", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _first <- try(run(connection, "SELECT 41 + 1", []))
        use _gone <- try(script(connection, "DEALLOCATE ALL"))
        run(connection, "SELECT 41 + 1", []) |> result.map(rows)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok([[Text(<<"42">>)]]))
      |> or_fail_with("Expected the run to work after a new prepare")
    }),
    it("gives StatementChanged when the result type changed (0A000)", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _table <- try(script(
          connection,
          "CREATE TEMP TABLE changing (a int)",
        ))
        use _first <- try(run(connection, "SELECT * FROM changing", []))
        use _altered <- try(script(
          connection,
          "ALTER TABLE changing ADD COLUMN b int",
        ))
        Ok(
          run(connection, "SELECT * FROM changing", [])
          |> result.map_error(changed_columns),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(["a", "b"])))
      |> or_fail_with("Expected StatementChanged with both columns")
    }),
    it("runs the changed statement after StatementChanged", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _table <- try(script(
          connection,
          "CREATE TEMP TABLE changing (a int)",
        ))
        use _first <- try(run(connection, "SELECT * FROM changing", []))
        use _altered <- try(script(
          connection,
          "ALTER TABLE changing ADD COLUMN b int",
        ))
        let _changed = run(connection, "SELECT * FROM changing", [])
        run(connection, "SELECT * FROM changing", []) |> result.map(tag)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok("SELECT 0"))
      |> or_fail_with("Expected the new statement to run")
    }),
    it("gives the error inside a transaction (0A000)", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _table <- try(script(
          connection,
          "CREATE TEMP TABLE changing (a int)",
        ))
        use _first <- try(run(connection, "SELECT * FROM changing", []))
        use _begun <- try(script(
          connection,
          "BEGIN; ALTER TABLE changing ADD COLUMN b int",
        ))
        let failed =
          run(connection, "SELECT * FROM changing", [])
          |> result.map_error(refusal)
        use _rolled_back <- try(script(connection, "ROLLBACK"))
        Ok(failed)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(#("0A000", "in a failed transaction"))))
      |> or_fail_with("Expected 0A000 in the failed transaction")
    }),
    it("refuses a run with 65536 parameters before it sends them", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          CacheStatements(512),
        )
        use _prepared <- try(run(connection, "SELECT 1", []))
        Ok(
          run(connection, "SELECT 1", list.repeat(Null, 65_536))
          |> result.replace(Nil),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(InvalidRequest(TooManyItems("parameters", 65_536)))))
      |> or_fail_with("Expected TooManyItems for the Bind")
    }),
    it(
      "refuses a prepare and a run with a zero byte with UnnamedStatements",
      fn() {
        // Act
        let answers = {
          use connection <- with_caching_connection(
            server.port,
            UnnamedStatements,
          )
          let prepared =
            connection.prepare(connection, "SELECT 1\u{0000}", 5000)
          let ran = run(connection, "SELECT 1\u{0000}", [])
          Ok(#(prepared |> result.replace(Nil), ran |> result.replace(Nil)))
        }

        // Assert
        answers
        |> should
        |> be_equal(
          Ok(#(
            Error(InvalidRequest(ZeroByteInString("query"))),
            Error(InvalidRequest(ZeroByteInString("query"))),
          )),
        )
        |> or_fail_with("Expected InvalidRequest for both")
      },
    ),
    it("gives the server's error for a run with UnnamedStatements", fn() {
      // Act
      let answer = {
        use connection <- with_caching_connection(
          server.port,
          UnnamedStatements,
        )
        Ok(run(connection, "SELECT 1/0", []) |> result.map_error(code))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("22012")))
      |> or_fail_with("Expected 22012")
    }),
    it("prepares no named statement with UnnamedStatements", fn() {
      // Act
      let statements = {
        use connection <- with_caching_connection(
          server.port,
          UnnamedStatements,
        )
        use _first <- try(run(connection, "SELECT 1", []))
        use _second <- try(connection.prepare(connection, "SELECT 1", 5000))
        prepared_statements(connection)
      }

      // Assert
      statements
      |> should
      |> be_equal(Ok([]))
      |> or_fail_with("Expected no named statement")
    }),
  ])
}

fn changed_columns(error: DriverError) -> List(String) {
  case error {
    connection.StatementChanged(description) ->
      map(description.columns, column_name)
    _ -> ["not StatementChanged"]
  }
}

fn column_name(column: ColumnDescription) -> String {
  column.name
}

fn refusal(error: DriverError) -> #(String, String) {
  case error {
    ServerRefused(report, InFailedTransaction) -> #(
      report.code,
      "in a failed transaction",
    )
    _ -> #("", "not a refusal")
  }
}

// Deadlines -------------------------------------------------------------------

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "sys", "resume")
fn resume(pid: Pid) -> Nil

fn with_timeouts(
  settings: ConnectionConfig,
  setup: Int,
  cancel: Int,
) -> ConnectionConfig {
  ConnectionConfig(
    ..settings,
    setup_timeout_milliseconds: setup,
    cancel_timeout_milliseconds: cancel,
  )
}

fn protocol_32_config(port: Int) -> Result(ConnectionConfig, DriverError) {
  use settings <- try(config(port, "dream", "dream", 10, None))
  use login_config <- try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password("dream"),
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: message.Protocol32,
    )
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  Ok(
    ConnectionConfig(..settings, login: login_config)
    |> with_timeouts(5000, 200),
  )
}

/// The backend's state in pg_stat_activity, from the control connection.
fn backend_state(
  control: Connection,
  pid: String,
) -> Result(List(String), DriverError) {
  use outcomes <- try(script(
    control,
    "SELECT state FROM pg_stat_activity WHERE pid = " <> pid,
  ))
  Ok(list.flat_map(outcomes, row_texts))
}

fn deadline_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("cancels a statement at its deadline and stays usable", fn() {
      // Act
      let answers = {
        use settings <- try(protocol_32_config(server.port))
        use connection <- with_started(settings)
        use control <- with_connection(server.port)
        use pid <- try(backend_pid(connection))
        let late =
          connection.run(connection, "SELECT pg_sleep(30)", [], [], 300)
          |> result.replace(Nil)
        use after <- try(backend_state(control, pid))
        // The next statement runs longer than the cancel timeout, so the
        // cancel's timer ends while the connection serves another request.
        use next <- try(run(connection, "SELECT pg_sleep(0.3)::text", []))
        Ok(#(late, after, tag(next)))
      }

      // Assert
      answers
      |> should
      |> be_equal(
        Ok(#(Error(DeadlinePassed(cancelled: True)), ["idle"], "SELECT 1")),
      )
      |> or_fail_with("Expected the cancel, an idle backend, then a new run")
    }),
  ])
}

fn more_deadline_tests() {
  [
    it("gives the settled transaction status after a request that waited", fn() {
      // Act
      let answers = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(833)"))
        let begun =
          start_caller(setup.connection, "BEGIN; SELECT pg_advisory_lock(833)")
        use Nil <- try(wait_for_lock_waiter(setup.control, 833, 5000))
        let quick = connection.transaction_status(setup.connection)
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(833)",
        ))
        let settled =
          connection.settled_transaction_status(setup.connection, 5000)
        let _answer = caller_answer(begun)
        use _rolled_back <- try(script(setup.connection, "ROLLBACK"))
        Ok(#(quick, settled))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(Idle), Ok(InTransaction))))
      |> or_fail_with("Expected Idle at once, then InTransaction once settled")
    }),
    it("refuses the settled status while the connection is lost", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        close_client(setup.proxy)
        let _lost = next_event(setup.events)
        Ok(connection.settled_transaction_status(setup.connection, 5000))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(ConnectionLost(SocketClosed))))
      |> or_fail_with("Expected the error of the loss")
    }),
    it("closes the connection when the cancel never gets an answer", fn() {
      // The cancel goes to the proxy, which serves one session at a time,
      // so it never reaches the server.
      check_failed_cancel(fn(_proxy) { Nil })
    }),
    it("closes the connection when the cancel cannot connect", fn() {
      check_failed_cancel(stop_listening)
    }),
    it("closes the connection when the session has no cancel key", fn() {
      // Arrange
      let login_answer = <<"R", 8:32, 0:32, "Z", 5:32, "I">>
      let #(port, _server) = start_fake_server(Answer(login_answer))

      // Act
      let answer = {
        use settings <- try(
          config(port, "dream", "dream", 60_000, None)
          |> result.map(with_timeouts(_, 5000, 200)),
        )
        use connection <- with_started(settings)
        Ok(
          connection.run(connection, "SELECT 1", [], [], 100)
          |> result.replace(Nil),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(DeadlinePassed(cancelled: False))))
      |> or_fail_with("Expected DeadlinePassed with no cancel")
    }),
    it("ends a waiting request at its deadline", fn() {
      // Act
      let answers = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(832)"))
        let first =
          start_caller(setup.connection, "SELECT pg_advisory_lock(832)")
        use Nil <- try(wait_for_lock_waiter(setup.control, 832, 5000))
        let waiting =
          connection.run_script(setup.connection, "SELECT 1", 100)
          |> result.replace(Nil)
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(832)",
        ))
        Ok(#(waiting, caller_answer(first)))
      }

      // Assert
      answers
      |> should
      |> be_equal(
        Ok(#(Error(DeadlinePassed(cancelled: False)), Ok(["SELECT 1"]))),
      )
      |> or_fail_with(
        "Expected the waiting request to end, and the first to run",
      )
    }),
    it("gives DeadlinePassed when the process does not answer in time", fn() {
      // Act
      let answer = {
        use settings <- try(
          config(first_server().port, "dream", "dream", 10, None)
          |> result.map(with_timeouts(_, 100, 100)),
        )
        use connection <- with_started(settings)
        suspend(pid_of(connection))
        let answer = connection.run(connection, "SELECT 1", [], [], 10)
        resume(pid_of(connection))
        Ok(answer |> result.replace(Nil))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(DeadlinePassed(cancelled: False))))
      |> or_fail_with("Expected DeadlinePassed from the caller's wait")
    }),
  ]
}

/// A statement passes its deadline through the proxy, and its cancel goes
/// to the proxy too, where it does not reach the server. After the cancel
/// timeout, the connection is closed and the caller gets DeadlinePassed.
fn check_failed_cancel(breaking: fn(Proxy) -> Nil) {
  // Act
  let answers = {
    let server = first_server()
    let #(port, proxy) = start_proxy(server.port)
    let events = process.new_subject()
    use settings <- try(
      config(port, "dream", "dream", 60_000, Some(events))
      |> result.map(with_timeouts(_, 5000, 200)),
    )
    use connection <- with_started(settings)
    breaking(proxy)
    let answer =
      connection.run(connection, "SELECT pg_sleep(30)", [], [], 100)
      |> result.replace(Nil)
    Ok(#(answer, next_event(events) |> result.map(event_code)))
  }

  // Assert
  answers
  |> should
  |> be_equal(
    Ok(#(Error(DeadlinePassed(cancelled: False)), Ok("lost at deadline"))),
  )
  |> or_fail_with("Expected DeadlinePassed and the loss of the connection")
}

// What dream_model needs -------------------------------------------------------

/// A connection that sets run-time parameters with the startup parameter
/// `options`, as dream_model does to get the rewritten query tree.
fn options_config(
  port: Int,
  options: String,
) -> Result(ConnectionConfig, DriverError) {
  use settings <- try(config(port, "dream", "dream", 10, None))
  use login_config <- try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password("dream"),
      parameters: [#("options", options)],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.replace_error(ConnectionLost(SocketClosed)),
  )
  Ok(ConnectionConfig(..settings, login: login_config))
}

fn model_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("reads the rewritten query tree from a notice, with options", fn() {
      // Act
      let seen = {
        use settings <- try(options_config(
          server.port,
          "-c debug_print_rewritten=on -c client_min_messages=log",
        ))
        use connection <- with_started(settings)
        use outcome <- try(
          run(
            connection,
            "SELECT relname FROM pg_class WHERE relname = 'pg_class'",
            [],
          ),
        )
        Ok(#(
          map(outcome.notices, notice_message),
          map(outcome.notices, tree_detail),
          map(outcome.columns, column_origin),
          rows(outcome),
        ))
      }

      // Assert
      seen
      |> should
      |> be_equal(
        Ok(
          #(["rewritten parse tree:"], [True], [#("relname", 1259, 2)], [
            [Text(<<"pg_class">>)],
          ]),
        ),
      )
      |> or_fail_with("Expected the tree notice, the column origin and the row")
    }),
    it("gives each notice in the middle of a result, and every row", fn() {
      // Act
      let seen = {
        use connection <- with_connection(server.port)
        use _function <- try(script(
          connection,
          "CREATE FUNCTION pg_temp.noisy(n int) RETURNS int LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'row %', n; RETURN n; END $$",
        ))
        use outcome <- try(
          run(
            connection,
            "SELECT pg_temp.noisy(g) FROM generate_series(1, 3) AS g",
            [],
          ),
        )
        Ok(#(map(outcome.notices, notice_message), rows(outcome)))
      }

      // Assert
      seen
      |> should
      |> be_equal(
        Ok(
          #(["row 1", "row 2", "row 3"], [
            [Text(<<"1">>)],
            [Text(<<"2">>)],
            [Text(<<"3">>)],
          ]),
        ),
      )
      |> or_fail_with("Expected three notices and three rows")
    }),
  ])
}

/// Whether the notice's detail holds the query tree.
fn tree_detail(report: ServerReport) -> Bool {
  case report.detail {
    Some(detail) -> contains(detail, "{QUERY")
    None -> False
  }
}

fn column_origin(column: ColumnDescription) -> #(String, Int, Int) {
  #(column.name, column.table_id, column.column_number)
}

// COPY ------------------------------------------------------------------------

@external(erlang, "driver_copy_test_ffi", "memory_of")
fn memory_of(pid: Pid) -> #(Int, Int)

@external(erlang, "driver_copy_test_ffi", "send_stray_down")
fn send_stray_down(pid: Pid) -> Nil

fn copy_from(
  connection: Connection,
  sql: String,
  produce: fn(CopySender) -> Result(Nil, reason),
) -> Result(Int, CopyError(reason)) {
  connection.copy_from(connection, sql, 5000, produce)
}

/// The rows of a table, counted on the connection.
fn count_rows(
  connection: Connection,
  table: String,
) -> Result(String, DriverError) {
  use outcome <- try(
    run(connection, "SELECT count(*)::text FROM " <> table, []),
  )
  Ok(row_texts(outcome) |> string.concat)
}

fn create_table(
  connection: Connection,
  table: String,
) -> Result(Nil, DriverError) {
  script(connection, "CREATE TEMP TABLE " <> table <> " (id int, name text)")
  |> result.replace(Nil)
}

/// Three rows in two chunks. The end of the first chunk is in the middle
/// of a row.
fn send_three_rows(sender: CopySender) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"1\tone\n2\ttw":utf8>>))
  connection.send_chunk(sender, <<"o\n3\tthree\n":utf8>>)
}

fn send_nothing(_sender: CopySender) -> Result(Nil, DriverError) {
  Ok(Nil)
}

fn collect_size(sizes: List(Int), row: BitArray) -> Result(List(Int), Nil) {
  Ok([bit_array.byte_size(row), ..sizes])
}

fn collect_row(
  rows: List(BitArray),
  row: BitArray,
) -> Result(List(BitArray), Nil) {
  Ok([row, ..rows])
}

/// Sends a row that is not valid, then valid rows until the server's error
/// comes back.
fn send_until_refused(sender: CopySender) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"x\tbad\n":utf8>>))
  send_rows_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// Sends the chunk again and again until a send fails, and gives that
/// failure.
fn send_rows_until_error(
  sender: CopySender,
  chunk: BitArray,
  attempts: Int,
) -> Result(Nil, DriverError) {
  case connection.send_chunk(sender, chunk), attempts {
    Ok(Nil), 0 -> Ok(Nil)
    Ok(Nil), _ -> send_rows_until_error(sender, chunk, attempts - 1)
    Error(error), _ -> Error(error)
  }
}

fn copy_error_text(error: CopyError(DriverError)) -> String {
  case error {
    AppFailed(reason) -> "app " <> driver_error_text(reason)
    DriverFailed(error) -> "driver " <> driver_error_text(error)
  }
}

fn driver_error_text(error: DriverError) -> String {
  case error {
    ServerRefused(report, _) -> report.code
    ServerEndedConnection(report) -> "ended " <> report.code
    ConnectionLost(reason) -> event_code(Disconnected(ConnectionLost(reason)))
    ProtocolViolation(_) -> "violation"
    DeadlinePassed(cancelled: True) -> "deadline cancelled"
    DeadlinePassed(cancelled: False) -> "deadline"
    CopyNotStarted -> "not started"
    CopyNotRunning -> "not running"
    _ -> "another error"
  }
}

fn copy_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("stores the rows of a COPY FROM STDIN and gives their count", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "copied"))
        let stored =
          copy_from(connection, "COPY copied FROM STDIN", send_three_rows)
        use outcome <- try(
          run(connection, "SELECT id::text, name FROM copied ORDER BY id", []),
        )
        Ok(#(stored, row_texts(outcome)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(3), ["1", "one", "2", "two", "3", "three"])))
      |> or_fail_with("Expected three rows stored")
    }),
    it("reads the rows of a COPY TO STDOUT one at a time", fn() {
      // Act
      let rows = {
        use connection <- with_connection(server.port)
        Ok(connection.copy_to(
          connection,
          "COPY (SELECT n, 'r' || n FROM generate_series(1, 3) n) TO STDOUT",
          5000,
          [],
          collect_row,
        ))
      }

      // Assert
      rows
      |> should
      |> be_equal(
        Ok(Ok([<<"3\tr3\n":utf8>>, <<"2\tr2\n":utf8>>, <<"1\tr1\n":utf8>>])),
      )
      |> or_fail_with("Expected each row as its own bytes")
    }),
    it("gives a row that is longer than one read of the socket", fn() {
      // Act
      let sizes = {
        use connection <- with_connection(server.port)
        Ok(connection.copy_to(
          connection,
          "COPY (SELECT repeat('x', 4000000)) TO STDOUT",
          5000,
          [],
          collect_size,
        ))
      }

      // Assert
      sizes
      |> should
      |> be_equal(Ok(Ok([4_000_001])))
      |> or_fail_with("Expected one row of 4,000,001 bytes")
    }),
    it("moves the bytes of a csv COPY both ways", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "csv"))
        let stored =
          copy_from(connection, "COPY csv FROM STDIN (FORMAT csv)", send_csv)
        let read =
          connection.copy_to(
            connection,
            "COPY csv TO STDOUT (FORMAT csv)",
            5000,
            [],
            collect_row,
          )
        Ok(#(stored, read))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(2), Ok([<<"2,\"b,c\"\n":utf8>>, <<"1,a\n":utf8>>]))))
      |> or_fail_with("Expected the csv rows back")
    }),
    it("moves the bytes of a binary COPY both ways", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use _created <- try(script(connection, "CREATE TEMP TABLE b (n int4)"))
        let stored =
          copy_from(
            connection,
            "COPY b FROM STDIN (FORMAT binary)",
            send_binary,
          )
        let read =
          connection.copy_to(
            connection,
            "COPY b TO STDOUT (FORMAT binary)",
            5000,
            [],
            collect_row,
          )
          |> result.map(list.reverse)
          |> result.map(bit_array.concat)
        Ok(#(stored, read))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(1), Ok(binary_copy()))))
      |> or_fail_with("Expected the same binary COPY data back")
    }),
    it("commits and rolls back a COPY with its transaction", fn() {
      // Act
      let counts = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "kept"))
        use _begun <- try(script(connection, "BEGIN"))
        let rolled_back =
          copy_from(connection, "COPY kept FROM STDIN", send_three_rows)
        use _rolled_back <- try(script(connection, "ROLLBACK"))
        use after_rollback <- try(count_rows(connection, "kept"))
        use _begun <- try(script(connection, "BEGIN"))
        let committed =
          copy_from(connection, "COPY kept FROM STDIN", send_three_rows)
        use _committed <- try(script(connection, "COMMIT"))
        use after_commit <- try(count_rows(connection, "kept"))
        Ok(#(rolled_back, after_rollback, committed, after_commit))
      }

      // Assert
      counts
      |> should
      |> be_equal(Ok(#(Ok(3), "0", Ok(3), "3")))
      |> or_fail_with("Expected no row after ROLLBACK and three after COMMIT")
    }),
    it("fails the transaction with a COPY that the app abandoned", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "failing"))
        use _begun <- try(script(connection, "BEGIN"))
        let failed =
          copy_from(connection, "COPY failing FROM STDIN", send_then_fail)
        use status <- try(connection.transaction_status(connection))
        use _rolled_back <- try(script(connection, "ROLLBACK"))
        Ok(#(failed, status))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(AppFailed("stopped")), InFailedTransaction)))
      |> or_fail_with("Expected the app's failure in a failed transaction")
    }),
    it("ends the COPY at a server error in the middle and stays usable", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "refused"))
        let refused =
          copy_from(connection, "COPY refused FROM STDIN", send_until_refused)
          |> result.map_error(copy_error_text)
        use count <- try(count_rows(connection, "refused"))
        Ok(#(refused, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error("app 22P02"), "0")))
      |> or_fail_with("Expected the app's failure with 22P02, and no row")
    }),
    it("gives the server's error when the app sent all its data", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "bad"))
        let refused =
          copy_from(connection, "COPY bad FROM STDIN", send_bad_row)
          |> result.map_error(copy_error_text)
        use status <- try(connection.transaction_status(connection))
        Ok(#(refused, status))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error("driver 22P02"), Idle)))
      |> or_fail_with("Expected the server's 22P02")
    }),
    it("abandons the COPY with CopyFail when the app fails", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "abandoned"))
        let failed =
          copy_from(connection, "COPY abandoned FROM STDIN", send_then_fail)
        use count <- try(count_rows(connection, "abandoned"))
        Ok(#(failed, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(AppFailed("stopped")), "0")))
      |> or_fail_with("Expected the app's failure, and no row stored")
    }),
    it("reads the rest of a COPY TO STDOUT when the app fails", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        let failed =
          connection.copy_to(
            connection,
            "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
            5000,
            0,
            fail_at_second_row,
          )
        use next <- try(script(connection, "SELECT 7"))
        Ok(#(failed, tags(next)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(AppFailed("enough")), ["SELECT 1"])))
      |> or_fail_with("Expected the app's failure, then a usable connection")
    }),
    it("refuses a statement that does not start its COPY", fn() {
      // Act
      let answers = {
        use connection <- with_connection(server.port)
        use Nil <- try(create_table(connection, "other"))
        let select = copy_from(connection, "SELECT 1", send_three_rows)
        let out = copy_from(connection, "COPY other TO STDOUT", send_three_rows)
        let into =
          connection.copy_to(
            connection,
            "COPY other FROM STDIN",
            5000,
            [],
            collect_row,
          )
        use count <- try(count_rows(connection, "other"))
        Ok(#(select, out, into, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(
        Ok(#(
          Error(DriverFailed(CopyNotStarted)),
          Error(DriverFailed(CopyNotStarted)),
          Error(DriverFailed(CopyNotStarted)),
          "0",
        )),
      )
      |> or_fail_with("Expected CopyNotStarted three times")
    }),
    it(
      "gives the server's error for a COPY of a table that does not exist",
      fn() {
        // Act
        let refused = {
          use connection <- with_connection(server.port)
          Ok(
            copy_from(
              connection,
              "COPY no_such_table FROM STDIN",
              send_three_rows,
            )
            |> result.map_error(copy_error_text),
          )
        }

        // Assert
        refused
        |> should
        |> be_equal(Ok(Error("driver 42P01")))
        |> or_fail_with("Expected 42P01")
      },
    ),
  ])
}

/// The binary COPY data of one row with the int4 1: the header, the row
/// and the trailer (docs, "COPY", "Binary Format").
fn binary_copy() -> BitArray {
  <<"PGCOPY\n":utf8, 255, "\r\n":utf8, 0, 0:32, 0:32, 1:16, 4:32, 1:32, -1:16>>
}

fn send_binary(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, binary_copy())
}

fn send_csv(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, <<"1,a\n2,\"b,c\"\n":utf8>>)
}

fn send_bad_row(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, <<"x\tbad\n":utf8>>)
}

fn send_then_fail(sender: CopySender) -> Result(Nil, String) {
  use Nil <- try(
    send_three_rows(sender) |> result.replace_error("the send failed"),
  )
  Error("stopped")
}

fn fail_at_second_row(rows: Int, _row: BitArray) -> Result(Int, String) {
  case rows {
    0 -> Ok(1)
    _ -> Error("enough")
  }
}

// COPY: memory, deadlines, callers and losses ---------------------------------

/// The largest memory and mailbox of the connection process, and the
/// largest memory of the caller, over the samples of a COPY.
type MemoryPeak {
  MemoryPeak(connection: Int, queue: Int, caller: Int)
}

/// The memory bound of the tests, in bytes: far less than the 16,000,000
/// bytes of the COPY data of the 1,000,000 rows.
const memory_bound = 2_000_000

fn sample_memory(peak: MemoryPeak, connection_pid: Pid) -> MemoryPeak {
  let #(connection_bytes, queue) = memory_of(connection_pid)
  let #(caller_bytes, _caller_queue) = memory_of(process.self())
  MemoryPeak(
    connection: int.max(peak.connection, connection_bytes),
    queue: int.max(peak.queue, queue),
    caller: int.max(peak.caller, caller_bytes),
  )
}

/// Loads 1,000,000 rows in 1,000 chunks of 1,000 rows, and samples the
/// memory after every 10 chunks. The peak goes to `peaks`.
fn load_million_rows(
  sender: CopySender,
  connection_pid: Pid,
  peaks: Subject(MemoryPeak),
) -> Result(Nil, DriverError) {
  let chunk = bit_array.from_string(repeat("12345\tsome text\n", 1000))
  use peak <- try(load_chunks(
    sender,
    chunk,
    1000,
    connection_pid,
    MemoryPeak(0, 0, 0),
  ))
  process.send(peaks, peak)
  Ok(Nil)
}

fn load_chunks(
  sender: CopySender,
  chunk: BitArray,
  left: Int,
  connection_pid: Pid,
  peak: MemoryPeak,
) -> Result(MemoryPeak, DriverError) {
  use <- bool.guard(left == 0, Ok(peak))
  use Nil <- try(connection.send_chunk(sender, chunk))
  load_chunks(
    sender,
    chunk,
    left - 1,
    connection_pid,
    sample_every(peak, left, 10, connection_pid),
  )
}

fn sample_every(
  peak: MemoryPeak,
  number: Int,
  interval: Int,
  connection_pid: Pid,
) -> MemoryPeak {
  case number % interval {
    0 -> sample_memory(peak, connection_pid)
    _ -> peak
  }
}

/// Counts the rows of a COPY TO STDOUT, and samples the memory after every
/// 10,000 rows.
fn count_and_sample(
  counted: #(Int, MemoryPeak),
  _row: BitArray,
  connection_pid: Pid,
) -> Result(#(Int, MemoryPeak), Nil) {
  let #(count, peak) = counted
  Ok(#(count + 1, sample_every(peak, count, 10_000, connection_pid)))
}

fn within_bounds(peak: MemoryPeak) -> #(Bool, Int, Bool) {
  #(peak.connection < memory_bound, peak.queue, peak.caller < memory_bound)
}

fn counted_within_bounds(
  counted: #(Int, MemoryPeak),
) -> #(Int, Bool, Bool, Bool) {
  let #(count, peak) = counted
  #(
    count,
    peak.connection < memory_bound,
    peak.queue <= 1,
    peak.caller < memory_bound,
  )
}

/// Waits until the backend `pid` is idle, asking the control connection
/// again each time: no sleep.
fn wait_until_idle(
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

/// Starts a process that tells when the backend `pid` is idle.
fn watch_until_idle(
  control: Connection,
  pid: String,
) -> Subject(Result(Nil, DriverError)) {
  let idle = process.new_subject()
  process.spawn(fn() { tell_when_idle(control, pid, idle) })
  idle
}

fn tell_when_idle(
  control: Connection,
  pid: String,
  idle: Subject(Result(Nil, DriverError)),
) -> Nil {
  process.send(idle, wait_until_idle(control, pid, 1_000_000))
}

fn await_idle(
  idle: Subject(Result(Nil, DriverError)),
) -> Result(Nil, DriverError) {
  process.receive(idle, 10_000)
  |> result.replace_error(ConnectionLost(SocketClosed))
  |> result.flatten
}

/// Waits, sending nothing, until the backend is idle, then sends a row.
fn send_after_idle(
  sender: CopySender,
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(watch_until_idle(control, pid) |> await_idle)
  connection.send_chunk(sender, <<"1\tone\n":utf8>>)
}

/// Takes the first row, then waits until the backend is idle.
fn read_until_idle(
  waited: Bool,
  _row: BitArray,
  control: Connection,
  pid: String,
) -> Result(Bool, DriverError) {
  use <- bool.guard(waited, Ok(True))
  watch_until_idle(control, pid) |> await_idle |> result.replace(True)
}

/// A caller process that runs `copy`, tells `started` what its function
/// did, and never ends by itself.
fn start_copy_caller(
  copy: fn(Subject(String)) -> value,
) -> #(Pid, Subject(String)) {
  let started = process.new_subject()
  let pid = process.spawn_unlinked(fn() { copy(started) })
  #(pid, started)
}

fn started_text(started: Subject(String)) -> String {
  process.receive(started, 5000) |> result.unwrap("no answer")
}

fn hang_after_rows(
  connection: Connection,
  started: Subject(String),
) -> Result(Int, CopyError(DriverError)) {
  copy_from(connection, "COPY hung FROM STDIN", send_and_hang(_, started))
}

fn send_and_hang(
  sender: CopySender,
  started: Subject(String),
) -> Result(Nil, DriverError) {
  use Nil <- try(send_three_rows(sender))
  process.send(started, "sent")
  process.receive_forever(process.new_subject())
}

fn hang_after_refusal(
  connection: Connection,
  started: Subject(String),
) -> Result(Int, CopyError(DriverError)) {
  copy_from(connection, "COPY hung FROM STDIN", refuse_and_hang(_, started))
}

fn refuse_and_hang(
  sender: CopySender,
  started: Subject(String),
) -> Result(Nil, DriverError) {
  process.send(started, send_until_refused(sender) |> refused_text)
  process.receive_forever(process.new_subject())
}

fn refused_text(refused: Result(Nil, DriverError)) -> String {
  case refused {
    Ok(Nil) -> "not refused"
    Error(error) -> driver_error_text(error)
  }
}

fn hang_at_first_row(
  connection: Connection,
  started: Subject(String),
) -> Result(Nil, CopyError(Nil)) {
  connection.copy_to(
    connection,
    "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
    5000,
    Nil,
    fn(value, row) { hang_at_row(value, row, started) },
  )
}

fn hang_at_row(
  _value: Nil,
  _row: BitArray,
  started: Subject(String),
) -> Result(Nil, Nil) {
  process.send(started, "row")
  process.receive_forever(process.new_subject())
}

/// Sends a row, breaks the connection, sends until a send fails, and
/// sends once more. A failure gives the first error and the answer to the
/// send after it.
fn send_across(
  sender: CopySender,
  breaking: fn() -> Result(Nil, DriverError),
) -> Result(Nil, #(DriverError, Result(Nil, DriverError))) {
  use Nil <- try(
    connection.send_chunk(sender, <<"1\tone\n":utf8>>)
    |> result.map_error(first_error),
  )
  use Nil <- try(breaking() |> result.map_error(first_error))
  send_rows_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
  |> result.map_error(with_next_send(_, sender))
}

fn first_error(error: DriverError) -> #(DriverError, Result(Nil, DriverError)) {
  #(error, Ok(Nil))
}

fn with_next_send(
  error: DriverError,
  sender: CopySender,
) -> #(DriverError, Result(Nil, DriverError)) {
  #(error, connection.send_chunk(sender, <<"3\tthree\n":utf8>>))
}

fn across_text(
  error: CopyError(#(DriverError, Result(Nil, DriverError))),
) -> String {
  case error {
    DriverFailed(ConnectionLost(_reason)) -> "driver lost"
    AppFailed(#(first, next)) ->
      "app " <> driver_error_text(first) <> ", then " <> refused_text(next)
    DriverFailed(error) -> "driver " <> driver_error_text(error)
  }
}

fn break_nothing() -> Result(Nil, DriverError) {
  Ok(Nil)
}

fn close_proxy(proxy: Proxy) -> Result(Nil, DriverError) {
  close_client(proxy)
  Ok(Nil)
}

fn inject_into(proxy: Proxy) -> Result(Nil, DriverError) {
  inject_bind_complete(proxy)
  Ok(Nil)
}

fn keep_sender(
  sender: CopySender,
  senders: Subject(CopySender),
) -> Result(Nil, DriverError) {
  process.send(senders, sender)
  Ok(Nil)
}

/// Runs a script and a second COPY inside a COPY. Both wait behind the
/// COPY, so both reach their deadline.
fn copy_inside(
  _sender: CopySender,
  connection: Connection,
) -> Result(Nil, #(String, String)) {
  let inner_script =
    connection.run_script(connection, "SELECT 1", 50)
    |> result.replace("ran")
    |> result.map_error(driver_error_text)
    |> either_text
  let inner_copy =
    connection.copy_from(
      connection,
      "COPY waiting FROM STDIN",
      50,
      send_nothing,
    )
    |> result.replace("ran")
    |> result.map_error(copy_error_text)
    |> either_text
  Error(#(inner_script, inner_copy))
}

fn either_text(answer: Result(String, String)) -> String {
  case answer {
    Ok(text) | Error(text) -> text
  }
}

fn close_at_first_row(
  closed: Bool,
  _row: BitArray,
  proxy: Proxy,
) -> Result(Bool, DriverError) {
  use <- bool.guard(closed, Ok(True))
  close_client(proxy)
  Ok(True)
}

fn copy_more_tests() {
  [
    it("keeps the memory flat while it loads 1,000,000 rows", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use _created <- try(script(
          connection,
          "CREATE TEMP TABLE loaded (n int, name text)",
        ))
        let peaks = process.new_subject()
        let connection_pid = pid_of(connection)
        let stored =
          copy_from(connection, "COPY loaded FROM STDIN", load_million_rows(
            _,
            connection_pid,
            peaks,
          ))
        Ok(#(stored, process.receive(peaks, 0) |> result.map(within_bounds)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Ok(1_000_000), Ok(#(True, 0, True)))))
      |> or_fail_with(
        "Expected 1,000,000 rows, an empty mailbox, and memory within the bound",
      )
    }),
    it("keeps the memory flat while it reads 1,000,000 rows", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        let connection_pid = pid_of(connection)
        connection.copy_to(
          connection,
          "COPY (SELECT n, 'some text' FROM generate_series(1, 1000000) n) TO STDOUT",
          60_000,
          #(0, MemoryPeak(0, 0, 0)),
          fn(counted, row) { count_and_sample(counted, row, connection_pid) },
        )
        |> result.map(counted_within_bounds)
        |> Ok
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(Ok(#(1_000_000, True, True, True))))
      |> or_fail_with("Expected 1,000,000 rows, and memory within the bound")
    }),
    it("ends a COPY FROM STDIN at its deadline while the app sends", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use Nil <- try(create_table(connection, "late"))
        let chunk = bit_array.from_string(repeat("1\tone\n", 1000))
        let late =
          connection.copy_from(
            connection,
            "COPY late FROM STDIN",
            300,
            send_rows_until_error(_, chunk, 1_000_000),
          )
          |> result.map_error(copy_error_text)
        use count <- try(count_rows(connection, "late"))
        Ok(#(late, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error("driver deadline cancelled"), "0")))
      |> or_fail_with("Expected DeadlinePassed(True), and no row stored")
    }),
    it(
      "ends a COPY FROM STDIN at its deadline while the app sends nothing",
      fn() {
        // Act
        let answers = {
          use connection <- with_connection(first_server().port)
          use control <- with_connection(first_server().port)
          use Nil <- try(create_table(connection, "idle"))
          use pid <- try(backend_pid(connection))
          let late =
            connection.copy_from(
              connection,
              "COPY idle FROM STDIN",
              300,
              send_after_idle(_, control, pid),
            )
            |> result.map_error(copy_error_text)
          use count <- try(count_rows(connection, "idle"))
          Ok(#(late, count))
        }

        // Assert
        answers
        |> should
        |> be_equal(Ok(#(Error("driver deadline cancelled"), "0")))
        |> or_fail_with("Expected the end of the COPY at the deadline")
      },
    ),
    it("ends a COPY TO STDOUT at its deadline while the app holds a row", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use control <- with_connection(first_server().port)
        use pid <- try(backend_pid(connection))
        let late =
          connection.copy_to(
            connection,
            "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
            300,
            False,
            fn(waited, row) { read_until_idle(waited, row, control, pid) },
          )
          |> result.map_error(copy_error_text)
        use next <- try(script(connection, "SELECT 8"))
        Ok(#(late, tags(next)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error("driver deadline cancelled"), ["SELECT 1"])))
      |> or_fail_with("Expected DeadlinePassed(True), then a usable connection")
    }),
    it("abandons a COPY FROM STDIN when its caller ends", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use Nil <- try(create_table(connection, "hung"))
        let #(caller, started) =
          start_copy_caller(hang_after_rows(connection, _))
        let told = started_text(started)
        process.kill(caller)
        use count <- try(count_rows(connection, "hung"))
        Ok(#(told, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#("sent", "0")))
      |> or_fail_with("Expected no row stored, and a usable connection")
    }),
    it("drops the end of a COPY when its caller ends before it took it", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        use Nil <- try(create_table(connection, "hung"))
        let #(caller, started) =
          start_copy_caller(hang_after_refusal(connection, _))
        let told = started_text(started)
        process.kill(caller)
        use count <- try(count_rows(connection, "hung"))
        Ok(#(told, count))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#("22P02", "0")))
      |> or_fail_with("Expected the refusal, then a usable connection")
    }),
    it("reads the rest of a COPY TO STDOUT when its caller ends", fn() {
      // Act
      let answers = {
        use connection <- with_connection(first_server().port)
        let #(caller, started) =
          start_copy_caller(hang_at_first_row(connection, _))
        let told = started_text(started)
        process.kill(caller)
        use next <- try(script(connection, "SELECT 9"))
        Ok(#(told, tags(next)))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#("row", ["SELECT 1"])))
      |> or_fail_with("Expected a usable connection")
    }),
    it("ignores the DOWN of a process that it does not watch", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        send_stray_down(pid_of(connection))
        script(connection, "SELECT 10") |> result.map(tags)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(["SELECT 1"]))
      |> or_fail_with("Expected the connection to work")
    }),
    it("refuses a chunk after its COPY ended", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        use Nil <- try(create_table(connection, "stale"))
        let senders = process.new_subject()
        let stored =
          copy_from(connection, "COPY stale FROM STDIN", keep_sender(_, senders))
        let late =
          process.receive(senders, 0)
          |> result.map(connection.send_chunk(_, <<"1\tone\n":utf8>>))
        Ok(#(stored, late))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(#(Ok(0), Ok(Error(CopyNotRunning)))))
      |> or_fail_with("Expected CopyNotRunning")
    }),
    it("gives the error of the COPY again to a chunk after it", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        use _created <- try(script(
          connection,
          "CREATE TEMP TABLE again (id int CHECK (id < 2), name text)",
        ))
        Ok(
          copy_from(connection, "COPY again FROM STDIN", send_across(
            _,
            break_nothing,
          ))
          |> result.map_error(across_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("app 23514, then 23514")))
      |> or_fail_with("Expected 23514 for the chunk after the error")
    }),
    it("refuses a COPY with a zero byte before it sends anything", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        Ok(copy_from(connection, "COPY t FROM STDIN\u{0000}", send_three_rows))
      }

      // Assert
      answer
      |> should
      |> be_equal(
        Ok(Error(DriverFailed(InvalidRequest(ZeroByteInString("query"))))),
      )
      |> or_fail_with("Expected InvalidRequest")
    }),
    it("serves no other request of the caller while its COPY runs", fn() {
      // Act
      let answer = {
        use connection <- with_connection(first_server().port)
        use Nil <- try(create_table(connection, "waiting"))
        Ok(
          copy_from(connection, "COPY waiting FROM STDIN", copy_inside(
            _,
            connection,
          )),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(AppFailed(#("deadline", "driver deadline")))))
      |> or_fail_with("Expected both inner requests to wait to their deadline")
    }),
    it("gives the loss of the connection in the middle of a COPY", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use Nil <- try(create_table(setup.connection, "lost"))
        Ok(
          copy_from(
            setup.connection,
            "COPY lost FROM STDIN",
            send_across(_, fn() { close_proxy(setup.proxy) }),
          )
          |> result.map_error(across_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("driver lost")))
      |> or_fail_with("Expected the loss of the connection")
    }),
    it("gives the end of the session in the middle of a COPY", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use Nil <- try(create_table(setup.connection, "ended"))
        use pid <- try(backend_pid(setup.connection))
        Ok(
          copy_from(
            setup.connection,
            "COPY ended FROM STDIN",
            send_across(_, fn() { terminate_backend(setup.control, pid) }),
          )
          |> result.map_error(across_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("driver ended 57P01")))
      |> or_fail_with("Expected the server's 57P01")
    }),
    it("gives a violation in the middle of a COPY", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        use Nil <- try(create_table(setup.connection, "broken"))
        Ok(
          copy_from(
            setup.connection,
            "COPY broken FROM STDIN",
            send_across(_, fn() { inject_into(setup.proxy) }),
          )
          |> result.map_error(across_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("driver violation")))
      |> or_fail_with("Expected the violation")
    }),
    it("loses the connection when a chunk cannot be sent in time", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        answer_next_request(setup.proxy, <<
          "1", 4:32, "2", 4:32, "G", 7:32, 0, 0:16,
        >>)
        let chunk = bit_array.from_string(repeat("x", 65_536))
        Ok(
          copy_from(
            setup.connection,
            "COPY t FROM STDIN",
            send_rows_until_error(_, chunk, 1_000_000),
          )
          |> result.map_error(copy_error_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("driver lost send timeout")))
      |> or_fail_with("Expected the loss by a send timeout")
    }),
    it("gives the loss of the connection to the next row of a COPY", fn() {
      // Act
      let answer = {
        use setup <- with_setup(60_000)
        Ok(
          connection.copy_to(
            setup.connection,
            "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
            5000,
            False,
            fn(closed, row) { close_at_first_row(closed, row, setup.proxy) },
          )
          |> result.map_error(copy_error_text),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error("driver lost closed")))
      |> or_fail_with("Expected the loss of the connection")
    }),
  ]
}
