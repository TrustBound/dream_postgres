//// Tests for `dream_postgres/driver/connection`, the connection process,
//// on the driver servers of PostgreSQL 16 to 19. A test proxy between the
//// process and the server breaks the connection on purpose, and a second
//// connection controls the server, so no test sleeps.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type DriverError, type Outcome, Backoff,
  ConnectionConfig, ConnectionLost, ConnectionProcessDown, CopyStatementRefused,
  DeadlinePassed, Disconnected, InvalidRequest, LoginRefused, ProtocolViolation,
  ReconnectFailed, Reconnected, ScriptFailed, ServerEndedConnection,
  ServerRefused, SetupTimedOut, TransportRefused, UndecodableMessage,
  UnexpectedIdleMessage, UnexpectedServerMessage,
}
import dream_postgres/driver/login.{PreferChannelBinding, ServerRejectedLogin}
import dream_postgres/driver/message.{
  BindComplete, Protocol30, UnknownMessageType, ZeroByteInString,
}
import dream_postgres/driver/transport.{
  ConnectRefused, ConnectionReset, NoTls, SendTimedOut, SocketClosed,
  TransportConfig,
}
import dream_postgres/internal/cell.{
  type Cell, type ServerReport, Binary, BinaryFormat, ColumnDescription,
  CommandResult, Idle, InFailedTransaction, InTransaction, Null,
  ParameterDescription, StatementDescription, Text,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/result.{try}
import gleam/string.{repeat, starts_with}

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

@external(erlang, "driver_proxy_ffi", "stop_reading")
fn stop_reading(proxy: Proxy) -> Nil

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
    reconnect: Backoff(first_delay, 60_000),
    events:,
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
  let server = first_server()
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  use settings <- try(config(port, "dream", "dream", first_delay, Some(events)))
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

/// The proxy stops reading, and a large script fills the socket's send
/// queue. The proxy then sends a CopyInResponse as if the server answered.
/// The step answers it with a CopyFail, whose send waits behind the full
/// queue and fails after the send timeout of 500 milliseconds.
fn check_send_timeout() {
  // Act
  let event = {
    use setup <- with_setup(60_000)
    stop_reading(setup.proxy)
    let large = "SELECT '" <> repeat("x", 64_000_000) <> "'"
    let _queued = connection.run_script(setup.connection, large, 50)
    inject(setup.proxy, <<"G", 7:32, 0, 0:16>>)
    Ok(next_event(setup.events) |> result.map(event_code))
  }

  // Assert
  event
  |> should
  |> be_equal(Ok(Ok("lost send timeout")))
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
    it("gives DeadlinePassed and stays usable after a late answer", fn() {
      // Act
      let answers = {
        use setup <- with_setup(60_000)
        use _locked <- try(script(setup.control, "SELECT pg_advisory_lock(826)"))
        let late =
          connection.run_script(
            setup.connection,
            "SELECT pg_advisory_lock(826)",
            50,
          )
        use _unlocked <- try(script(
          setup.control,
          "SELECT pg_advisory_unlock(826)",
        ))
        use outcome <- try(run(setup.connection, "SELECT 3", []))
        Ok(#(late |> result.replace(Nil), rows(outcome)))
      }

      // Assert
      answers
      |> should
      |> be_equal(
        Ok(#(Error(DeadlinePassed(cancelled: False)), [[Text(<<"3">>)]])),
      )
      |> or_fail_with("Expected DeadlinePassed, then the next query's result")
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
    it("fails a running run when the network closes", fn() {
      check_running_lost(RunCaller)
    }),
    it("fails a running prepare when the network closes", fn() {
      check_running_lost(PrepareCaller)
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

/// A run waits on an advisory lock. A prepare waits on a table that the
/// control connection locks: its Parse needs a lock on the table too. The
/// proxy closes the connection, and the caller gets the loss.
fn check_running_lost(kind: CallerKind) {
  // Act
  let answer = {
    use setup <- with_setup(60_000)
    use _held <- try(hold_lock(setup.control, kind))
    let answers = process.new_subject()
    process.spawn_unlinked(fn() {
      blocked_call(setup.connection, kind, answers)
    })
    use Nil <- try(wait_for_blocked(setup.control, kind, 5000))
    close_client(setup.proxy)
    let answer = process.receive(answers, 5000)
    use _released <- try(release_lock(setup.control, kind))
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
) -> Result(List(Outcome), DriverError) {
  case kind {
    RunCaller -> script(control, "SELECT pg_advisory_lock(830)")
    PrepareCaller -> {
      use _created <- try(script(
        control,
        "CREATE TABLE IF NOT EXISTS driver_prepare_lock (x int)",
      ))
      script(
        control,
        "BEGIN; LOCK TABLE driver_prepare_lock IN ACCESS EXCLUSIVE MODE",
      )
    }
  }
}

fn release_lock(
  control: Connection,
  kind: CallerKind,
) -> Result(List(Outcome), DriverError) {
  case kind {
    RunCaller -> script(control, "SELECT pg_advisory_unlock(830)")
    PrepareCaller -> script(control, "ROLLBACK")
  }
}

fn blocked_call(
  connection: Connection,
  kind: CallerKind,
  answers: Subject(Result(Nil, DriverError)),
) -> Nil {
  let answer = case kind {
    RunCaller ->
      run(connection, "SELECT pg_advisory_lock(830)", []) |> result.replace(Nil)
    PrepareCaller ->
      connection.prepare(connection, "SELECT x FROM driver_prepare_lock", 5000)
      |> result.replace(Nil)
  }
  process.send(answers, answer)
}

fn wait_for_blocked(
  control: Connection,
  kind: CallerKind,
  attempts: Int,
) -> Result(Nil, DriverError) {
  case kind {
    RunCaller -> wait_for_lock_waiter(control, 830, attempts)
    PrepareCaller -> wait_for_table_waiter(control, attempts)
  }
}

fn wait_for_table_waiter(
  control: Connection,
  attempts: Int,
) -> Result(Nil, DriverError) {
  use outcomes <- try(script(
    control,
    "SELECT count(*)::text FROM pg_locks WHERE locktype = 'relation' AND NOT granted AND relation = 'driver_prepare_lock'::regclass",
  ))
  case map(outcomes, rows), attempts {
    [[[Text(<<"1">>)]]], _ -> Ok(Nil)
    _, 0 -> Error(ConnectionLost(SocketClosed))
    _, _ -> wait_for_table_waiter(control, attempts - 1)
  }
}
