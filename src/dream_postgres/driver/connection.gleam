//// A connection process: one gleam_otp actor that owns one socket to a
//// PostgreSQL server for its whole life.
////
//// The process connects and logs in when it starts. After that it runs one
//// request at a time with the pure steps of `driver/query`, over the
//// socket of `driver/transport`, and gives the result back as cells of
//// bytes: the caller decodes them in its own process. Requests that come
//// while one runs wait in order.
////
//// The socket sends each of its messages to the process, so a close by
//// the server is seen at once, also while the connection is idle. When the
//// connection is lost, the process tells the subscriber of its events,
//// fails the requests that wait, and connects again with a backoff that
//// doubles from the first delay up to the longest one.
////
//// A caller that crashes or stops waiting never leaves the connection in
//// an unknown state: the process reads each answer to its end, whether a
//// caller still waits for it or not. A reply that comes after the caller
//// stopped waiting is dropped and never reaches the caller's mailbox.
////
//// Messages that the server sends between requests are kept, not dropped:
//// a parameter change updates `server_parameter`, and a notice or a
//// notification goes with the outcome of the next request.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/crypto.{random_bytes}
import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/login.{
  type LoginConfig, type LoginError, type LoginOutcome, type LoginState,
  Continue, LoggedIn,
}
import dream_postgres/driver/message.{
  type BackendMessage, type EncodeError, type FrontendMessage,
  type ProtocolError, Decoded, ErrorResponse, NeedMoreBytes, NoticeResponse,
  NotificationResponse, ParameterStatus,
}
import dream_postgres/driver/query.{
  type AsynchronousMessage, type Failure, type PrepareAndRunState,
  type PrepareState, type ScriptFailure, type SimpleQueryState, type Start,
  type StatementResult, type Step, type UnexpectedMessage, ConnectionEnded,
  CopyNotSupported, Finished, Notice, ParameterChanged, ScriptFailure, Send,
  ServerError, Wait,
}
import dream_postgres/driver/transaction.{
  type TransactionTracker, aborting_error, new_tracker, track, track_script,
  track_step, transaction_status as tracked_status,
}
import dream_postgres/driver/transport.{
  type TransportConfig, type TransportError, BytesReceived, NotThisSocket,
  SocketClosed, SocketEnded, SocketFailed,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type ServerReport, type StatementDescription, type TransactionStatus,
}
import gleam/bit_array.{concat}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/int.{min}
import gleam/list.{append, filter_map, fold, reverse, try_map}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result.{map_error, try}

// Types -----------------------------------------------------------------------

/// How long the process waits before it connects again after a loss: the
/// first delay, then twice that after each failed attempt, up to the
/// longest delay.
pub type Backoff {
  Backoff(first_delay_milliseconds: Int, longest_delay_milliseconds: Int)
}

/// Everything a connection process needs.
pub type ConnectionConfig {
  ConnectionConfig(
    transport: TransportConfig,
    login: LoginConfig,
    /// The longest time for the TCP connect, TLS and the login together.
    setup_timeout_milliseconds: Int,
    reconnect: Backoff,
    /// Where the process tells of each loss and each reconnect, for
    /// example to its pool.
    events: Option(Subject(ConnectionEvent)),
  )
}

/// What the process tells its subscriber about the connection.
pub type ConnectionEvent {
  /// The connection is lost. The process connects again after the backoff.
  Disconnected(error: DriverError)
  /// An attempt to connect again failed. The next one follows after the
  /// backoff.
  ReconnectFailed(error: ConnectError)
  /// The process connected and logged in again.
  Reconnected
}

/// Why the process could not connect and log in.
pub type ConnectError {
  /// The TCP connect or TLS failed.
  TransportRefused(error: TransportError)
  /// The login failed, for example with the server's 28P01.
  LoginRefused(error: LoginError)
  /// The server sent bytes during the login that are not a valid message.
  LoginUndecodable(error: ProtocolError)
  /// A login message could not be written.
  LoginUnencodable(error: EncodeError)
  /// The connect and the login took longer than the setup timeout.
  SetupTimedOut
  /// The process exited while it connected.
  SetupExited
}

/// A notification of `NOTIFY`, from the backend with this process ID.
pub type Notification {
  Notification(process_id: Int, channel: String, payload: String)
}

/// The result of one statement.
pub type Outcome {
  Outcome(
    /// The result columns, for the client's decoders.
    columns: List(ColumnDescription),
    result: CommandResult,
    /// Each notice since the last outcome, in order.
    notices: List(ServerReport),
    /// Each notification since the last outcome, in order. An app that
    /// wants notifications uses the listener, which has its own connection.
    notifications: List(Notification),
    transaction_status: TransactionStatus,
  )
}

/// A message of the server that the driver did not expect.
pub type Violation {
  /// Bytes that are not a valid message.
  UndecodableMessage(error: ProtocolError)
  /// A valid message that the protocol does not allow at this point of a
  /// request.
  UnexpectedServerMessage(error: UnexpectedMessage)
  /// A message between requests that is not a parameter change, a notice,
  /// a notification or an error.
  UnexpectedIdleMessage(message: BackendMessage)
}

/// Why a request failed.
pub type DriverError {
  /// The server refused the statement. The connection stays usable.
  ServerRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// A statement of a script failed, after the ones in `completed` ran.
  ScriptFailed(
    completed: List(Outcome),
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// The deadline passed before the result came. `cancelled` says whether
  /// the server confirmed a cancel.
  DeadlinePassed(cancelled: Bool)
  /// The socket closed or failed.
  ConnectionLost(reason: TransportError)
  /// The server ended the session with a FATAL or PANIC error, for example
  /// `57P01` when an administrator stops it.
  ServerEndedConnection(report: ServerReport)
  /// The server broke the protocol. The process connects again.
  ProtocolViolation(violation: Violation)
  /// A COPY statement went to `run` or `run_script`. COPY goes through
  /// `copy_from` and `copy_to`. `completed` holds the statements of a
  /// script that ran before it.
  CopyStatementRefused(completed: List(Outcome))
  /// The request cannot be written, for example SQL with a zero byte.
  InvalidRequest(error: EncodeError)
  /// The connection process is gone.
  ConnectionProcessDown
}

/// A connection process.
pub opaque type Connection {
  Connection(subject: Subject(Message), pid: Pid)
}

/// What a caller can read of the connection without a request to the
/// server.
type Snapshot {
  Snapshot(
    transaction_status: TransactionStatus,
    aborted_by: Option(ServerReport),
    parameters: Dict(String, String),
  )
}

/// A reply target: an alias of the caller (see the FFI module).
type ReplyTo(reply)

type CallFailure {
  CallProcessDown
  CallDeadlinePassed
}

type Message {
  Request(request: Request)
  SnapshotRequest(reply: ReplyTo(Snapshot))
  StopRequest(reply: ReplyTo(Nil))
  SocketMessage(message: Dynamic)
  ReconnectNow(error: DriverError, attempt: Int)
  ExitSignal(exit: ExitMessage)
}

/// A request that goes to the server.
type Request {
  PrepareRequest(
    sql: String,
    reply: ReplyTo(Result(StatementDescription, DriverError)),
  )
  RunRequest(
    sql: String,
    parameters: List(Cell),
    result_formats: List(Format),
    reply: ReplyTo(Result(Outcome, DriverError)),
  )
  ScriptRequest(sql: String, reply: ReplyTo(Result(List(Outcome), DriverError)))
}

/// The request that runs, with the state of its step.
type Running {
  RunningPrepare(
    state: PrepareState,
    reply: ReplyTo(Result(StatementDescription, DriverError)),
  )
  RunningRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, DriverError)),
  )
  RunningScript(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), DriverError)),
  )
}

type Link {
  /// Connected and logged in. `bytes` are read but not decoded yet.
  Connected(socket: transport.Connection, bytes: BitArray)
  /// Lost. Requests fail with `error` until the process connects again.
  Lost(error: DriverError)
}

type State {
  State(
    config: ConnectionConfig,
    subject: Subject(Message),
    link: Link,
    parameters: Dict(String, String),
    tracker: TransactionTracker,
    running: Option(Running),
    /// The requests that wait, newest first.
    waiting: List(Request),
    /// The notices and notifications since the last outcome, newest first.
    pending: List(AsynchronousMessage),
  )
}

/// A connection after the login: the socket, the bytes after the login's
/// ReadyForQuery, and what the login gave.
type Session {
  Session(socket: transport.Connection, bytes: BitArray, outcome: LoginOutcome)
}

@external(erlang, "dream_postgres_connection_ffi", "call")
fn call_process(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
  timeout: Int,
) -> Result(reply, CallFailure)

@external(erlang, "dream_postgres_connection_ffi", "reply")
fn reply(to: ReplyTo(reply), value: reply) -> Nil

// Starting and stopping -------------------------------------------------------

/// Starts a connection process, linked to the caller, and waits until it
/// connected and logged in.
///
/// ## Parameters
///
/// - `config`: the server, the login and the reconnect settings
///
/// ## Returns
///
/// - `Ok(Connection)`: the process is connected and ready
/// - `Error(ConnectError)`: the connect or the login failed. No process
///   stays.
pub fn start(config: ConnectionConfig) -> Result(Connection, ConnectError) {
  start_process(config) |> result.map(started_connection)
}

fn started_connection(started: actor.Started(Connection)) -> Connection {
  started.data
}

fn start_process(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), ConnectError) {
  let failure = process.new_subject()
  actor.new_with_initialiser(config.setup_timeout_milliseconds, initialise(
    _,
    config,
    failure,
  ))
  |> actor.on_message(handle_message)
  |> actor.start
  |> map_error(start_error(_, failure))
}

/// The process as a child of a gleam_otp supervisor.
///
/// ## Parameters
///
/// - `config`: the server, the login and the reconnect settings
///
/// ## Returns
///
/// A worker child that starts the process with `config`. The supervisor's
/// shutdown makes the process send Terminate before it stops.
pub fn supervised(config: ConnectionConfig) -> ChildSpecification(Connection) {
  supervision.worker(fn() { start_child(config) })
}

fn start_child(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), actor.StartError) {
  start_process(config) |> map_error(child_start_error)
}

fn child_start_error(_error: ConnectError) -> actor.StartError {
  actor.InitFailed("connect failed")
}

fn initialise(
  subject: Subject(Message),
  config: ConnectionConfig,
  failure: Subject(ConnectError),
) -> Result(actor.Initialised(State, Message, Connection), String) {
  process.trap_exits(True)
  case open_session(config) {
    Ok(session) -> Ok(initialised(subject, config, session))
    Error(error) -> {
      process.send(failure, error)
      Error("connect failed")
    }
  }
}

fn initialised(
  subject: Subject(Message),
  config: ConnectionConfig,
  session: Session,
) -> actor.Initialised(State, Message, Connection) {
  let state = connected_state(new_state(config, subject), session)
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_trapped_exits(ExitSignal)
    |> process.select_other(SocketMessage)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Connection(subject:, pid: process.self()))
}

fn new_state(config: ConnectionConfig, subject: Subject(Message)) -> State {
  State(
    config:,
    subject:,
    link: Lost(ConnectionLost(SocketClosed)),
    parameters: dict.new(),
    tracker: new_tracker(),
    running: None,
    waiting: [],
    pending: [],
  )
}

fn connected_state(state: State, session: Session) -> State {
  let notices = reverse(session.outcome.notices) |> list.map(Notice)
  State(
    ..state,
    link: Connected(session.socket, session.bytes),
    parameters: session.outcome.parameters,
    tracker: track(new_tracker(), session.outcome.transaction_status, None),
    pending: append(notices, state.pending),
  )
}

fn start_error(
  error: actor.StartError,
  failure: Subject(ConnectError),
) -> ConnectError {
  case error {
    actor.InitFailed(_) | actor.InitExited(_) ->
      process.receive(failure, 0) |> result.unwrap(SetupExited)
    actor.InitTimeout -> SetupTimedOut
  }
}

/// Stops the process: it sends Terminate to the server and closes the
/// socket.
///
/// ## Parameters
///
/// - `connection`: the connection to stop
///
/// ## Returns
///
/// `Nil`, also when the process is gone already.
pub fn stop(connection: Connection) -> Nil {
  call(connection, StopRequest, 5000) |> result.unwrap(Nil)
}

// Requests --------------------------------------------------------------------

/// Prepares a statement and describes it, before any run.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the statement
/// - `deadline_milliseconds`: the longest time to wait for the answer
///
/// ## Returns
///
/// - `Ok(StatementDescription)`: the parameter types and the result columns
/// - `Error(DriverError)`: the server refused it, or the request failed
pub fn prepare(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(StatementDescription, DriverError) {
  request(connection, PrepareRequest(sql, _), deadline_milliseconds)
}

/// Runs a statement with its parameters. Each cell carries its own format.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the statement
/// - `parameters`: one cell for each parameter
/// - `result_formats`: the format of the result columns: none for text,
///   one for all, or one for each column
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(Outcome)`: the columns, the rows of cells, the tag and the count
/// - `Error(DriverError)`: the server refused it, or the request failed
pub fn run(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  deadline_milliseconds: Int,
) -> Result(Outcome, DriverError) {
  request(
    connection,
    RunRequest(sql, parameters, result_formats, _),
    deadline_milliseconds,
  )
}

/// Runs a script of statements with the simple query protocol, for example
/// `BEGIN`, `COMMIT` or several statements at once. Cells come in text.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the script
/// - `deadline_milliseconds`: the longest time to wait for all results
///
/// ## Returns
///
/// - `Ok(outcomes)`: one outcome for each statement, in order
/// - `Error(DriverError)`: a statement failed (`ScriptFailed` keeps the
///   ones before it), or the request failed
pub fn run_script(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), DriverError) {
  request(connection, ScriptRequest(sql, _), deadline_milliseconds)
}

/// The transaction status after the last request.
///
/// ## Parameters
///
/// - `connection`: the connection
///
/// ## Returns
///
/// - `Ok(TransactionStatus)`: idle, in a transaction, or in a failed one
/// - `Error(ConnectionProcessDown)`: the process is gone
pub fn transaction_status(
  connection: Connection,
) -> Result(TransactionStatus, DriverError) {
  snapshot(connection) |> result.map(snapshot_status)
}

fn snapshot_status(snapshot: Snapshot) -> TransactionStatus {
  snapshot.transaction_status
}

/// The report of the statement that failed the transaction.
///
/// ## Parameters
///
/// - `connection`: the connection
///
/// ## Returns
///
/// - `Ok(Some(report))`: while the transaction status is
///   `InFailedTransaction`
/// - `Ok(None)`: in any other status. It clears when the status is idle
///   again.
/// - `Error(ConnectionProcessDown)`: the process is gone
pub fn aborted_by(
  connection: Connection,
) -> Result(Option(ServerReport), DriverError) {
  snapshot(connection) |> result.map(snapshot_aborted_by)
}

fn snapshot_aborted_by(snapshot: Snapshot) -> Option(ServerReport) {
  snapshot.aborted_by
}

/// A run-time parameter that the server reported, for example
/// `server_version` or `TimeZone`, with its latest value.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `name`: the parameter's name
///
/// ## Returns
///
/// - `Ok(Some(value))`: the latest value
/// - `Ok(None)`: the server reported no parameter of that name
/// - `Error(ConnectionProcessDown)`: the process is gone
pub fn server_parameter(
  connection: Connection,
  name: String,
) -> Result(Option(String), DriverError) {
  snapshot(connection) |> result.map(parameter_of(_, name))
}

fn parameter_of(snapshot: Snapshot, name: String) -> Option(String) {
  dict.get(snapshot.parameters, name) |> option.from_result
}

fn snapshot(connection: Connection) -> Result(Snapshot, DriverError) {
  call(connection, SnapshotRequest, 5000)
}

fn request(
  connection: Connection,
  make: fn(ReplyTo(Result(value, DriverError))) -> Request,
  deadline_milliseconds: Int,
) -> Result(value, DriverError) {
  call(connection, request_message(make, _), deadline_milliseconds)
  |> result.flatten
}

fn request_message(
  make: fn(ReplyTo(Result(value, DriverError))) -> Request,
  reply_to: ReplyTo(Result(value, DriverError)),
) -> Message {
  Request(make(reply_to))
}

fn call(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  timeout: Int,
) -> Result(reply, DriverError) {
  call_process(connection.pid, send_request(connection, make, _), timeout)
  |> map_error(call_error)
}

fn send_request(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(connection.subject, make(reply_to))
}

fn call_error(failure: CallFailure) -> DriverError {
  case failure {
    CallProcessDown -> ConnectionProcessDown
    CallDeadlinePassed -> DeadlinePassed(cancelled: False)
  }
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Request(request) -> actor.continue(accept_request(state, request))
    SnapshotRequest(reply_to) -> {
      reply(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    StopRequest(reply_to) -> stop_process(state, Some(reply_to))
    ExitSignal(_exit) -> stop_process(state, None)
    SocketMessage(socket_message) ->
      actor.continue(socket_message_received(state, socket_message))
    ReconnectNow(error:, attempt:) ->
      actor.continue(reconnect(state, error, attempt))
  }
}

fn snapshot_of(state: State) -> Snapshot {
  Snapshot(
    transaction_status: tracked_status(state.tracker),
    aborted_by: aborting_error(state.tracker),
    parameters: state.parameters,
  )
}

/// Stops the process. A connected socket gets a Terminate first, so the
/// server ends the session cleanly.
fn stop_process(
  state: State,
  reply_to: Option(ReplyTo(Nil)),
) -> actor.Next(State, Message) {
  case state.link {
    Connected(socket:, ..) -> terminate(socket)
    Lost(..) -> Nil
  }
  option.map(reply_to, reply(_, Nil))
  actor.stop()
}

/// Sends Terminate and closes the socket. A socket that cannot take the
/// Terminate is broken already, so closing it is all that is left to do.
fn terminate(socket: transport.Connection) -> Nil {
  case transport.send(socket, encode.terminate()) {
    Ok(Nil) | Error(_broken) -> transport.close(socket)
  }
}

/// A request runs at once when no other runs, and waits otherwise.
fn accept_request(state: State, request: Request) -> State {
  case state.running, state.link {
    None, Connected(socket:, ..) -> begin(state, socket, request)
    Some(_running), _ -> State(..state, waiting: [request, ..state.waiting])
    None, Lost(error:) -> {
      refuse(request, error)
      state
    }
  }
}

fn begin(
  state: State,
  socket: transport.Connection,
  request: Request,
) -> State {
  case request {
    PrepareRequest(sql:, reply: reply_to) ->
      start_step(
        state,
        socket,
        query.start_prepare("", sql, []),
        RunningPrepare(_, reply_to),
        refuse(request, _),
      )
    RunRequest(sql:, parameters:, result_formats:, reply: reply_to) ->
      start_step(
        state,
        socket,
        query.start_prepare_and_run(sql, [], parameters, result_formats),
        RunningRun(_, reply_to),
        refuse(request, _),
      )
    ScriptRequest(sql:, reply: reply_to) ->
      start_step(
        state,
        socket,
        query.start_simple_query(sql),
        RunningScript(_, reply_to),
        refuse(request, _),
      )
  }
}

/// Sends the first messages of a step. A message that cannot be written
/// fails the request before any byte goes out.
fn start_step(
  state: State,
  socket: transport.Connection,
  start: Start(step_state),
  running: fn(step_state) -> Running,
  fail: fn(DriverError) -> Nil,
) -> State {
  case encode_all(start.messages) {
    Ok(bytes) ->
      State(..state, running: Some(running(start.state)))
      |> sent(socket, transport.send(socket, bytes))
    Error(error) -> {
      fail(InvalidRequest(error))
      next_request(state)
    }
  }
}

fn refuse(request: Request, error: DriverError) -> Nil {
  case request {
    PrepareRequest(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunRequest(reply: reply_to, ..) -> reply(reply_to, Error(error))
    ScriptRequest(reply: reply_to, ..) -> reply(reply_to, Error(error))
  }
}

fn refuse_running(running: Running, error: DriverError) -> Nil {
  case running {
    RunningPrepare(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunningRun(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunningScript(reply: reply_to, ..) -> reply(reply_to, Error(error))
  }
}

fn encode_all(
  messages: List(FrontendMessage),
) -> Result(BitArray, EncodeError) {
  try_map(messages, encode) |> result.map(concat)
}

fn sent(
  state: State,
  socket: transport.Connection,
  sent: Result(Nil, TransportError),
) -> State {
  case sent {
    Ok(Nil) -> state
    Error(error) -> lose(state, socket, ConnectionLost(error))
  }
}

/// Starts the oldest waiting request, if any.
fn next_request(state: State) -> State {
  case reverse(state.waiting) {
    [] -> state
    [oldest, ..others] ->
      accept_request(State(..state, waiting: reverse(others)), oldest)
  }
}

// Socket messages -------------------------------------------------------------

fn socket_message_received(state: State, socket_message: Dynamic) -> State {
  case state.link {
    Connected(socket:, bytes:) ->
      socket_event(
        state,
        socket,
        bytes,
        transport.socket_event(socket, socket_message),
      )
    Lost(..) -> state
  }
}

fn socket_event(
  state: State,
  socket: transport.Connection,
  bytes: BitArray,
  event: transport.SocketEvent,
) -> State {
  case event {
    BytesReceived(more) ->
      State(..state, link: Connected(socket, <<bytes:bits, more:bits>>))
      |> read_messages
      |> receive_next
    SocketEnded -> lose(state, socket, ConnectionLost(SocketClosed))
    SocketFailed(error) -> lose(state, socket, ConnectionLost(error))
    NotThisSocket -> state
  }
}

fn receive_next(state: State) -> State {
  case state.link {
    Connected(socket:, ..) ->
      sent(state, socket, transport.receive_next(socket))
    Lost(..) -> state
  }
}

/// Decodes and handles each whole message of the buffer.
fn read_messages(state: State) -> State {
  case state.link {
    Connected(socket:, bytes:) -> read_message(state, socket, bytes)
    Lost(..) -> state
  }
}

fn read_message(
  state: State,
  socket: transport.Connection,
  bytes: BitArray,
) -> State {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      State(..state, link: Connected(socket, rest))
      |> handle_server_message(socket, message)
      |> read_messages
    Ok(NeedMoreBytes) -> state
    Error(error) ->
      lose(state, socket, ProtocolViolation(UndecodableMessage(error)))
  }
}

fn handle_server_message(
  state: State,
  socket: transport.Connection,
  message: BackendMessage,
) -> State {
  case state.running {
    Some(running) ->
      advance(State(..state, running: None), socket, running, message)
    None -> idle_message(state, socket, message)
  }
}

/// A message between requests: a parameter change, a notice, a
/// notification, or the error that ends the session.
fn idle_message(
  state: State,
  socket: transport.Connection,
  message: BackendMessage,
) -> State {
  case message {
    ParameterStatus(name:, value:) ->
      State(..state, parameters: dict.insert(state.parameters, name, value))
    NoticeResponse(report) ->
      State(..state, pending: [Notice(report), ..state.pending])
    NotificationResponse(process_id:, channel:, payload:) ->
      State(..state, pending: [
        query.Notification(process_id, channel, payload),
        ..state.pending
      ])
    ErrorResponse(report) -> lose(state, socket, ServerEndedConnection(report))
    _other ->
      lose(state, socket, ProtocolViolation(UnexpectedIdleMessage(message)))
  }
}

// Steps -----------------------------------------------------------------------

fn advance(
  state: State,
  socket: transport.Connection,
  running: Running,
  message: BackendMessage,
) -> State {
  case running {
    RunningPrepare(state: step_state, reply: reply_to) ->
      follow(
        state,
        socket,
        query.step_prepare(step_state, message),
        RunningPrepare(_, reply_to),
        prepare_finisher(reply_to),
        running,
      )
    RunningRun(state: step_state, reply: reply_to) ->
      follow(
        state,
        socket,
        query.step_prepare_and_run(step_state, message),
        RunningRun(_, reply_to),
        run_finisher(reply_to),
        running,
      )
    RunningScript(state: step_state, reply: reply_to) ->
      follow(
        state,
        socket,
        query.step_simple_query(step_state, message),
        RunningScript(_, reply_to),
        script_finisher(reply_to),
        running,
      )
  }
}

fn prepare_finisher(
  reply_to: ReplyTo(Result(StatementDescription, DriverError)),
) -> fn(State, query.Outcome(StatementDescription, Failure)) -> State {
  fn(state, outcome) { finish_prepare(state, outcome, reply_to) }
}

fn run_finisher(
  reply_to: ReplyTo(Result(Outcome, DriverError)),
) -> fn(State, query.Outcome(StatementResult, Failure)) -> State {
  fn(state, outcome) { finish_run(state, outcome, reply_to) }
}

fn script_finisher(
  reply_to: ReplyTo(Result(List(Outcome), DriverError)),
) -> fn(State, query.Outcome(List(StatementResult), ScriptFailure)) -> State {
  fn(state, outcome) { finish_script(state, outcome, reply_to) }
}

/// Goes on with a step: sends what it asks, waits, or finishes it.
fn follow(
  state: State,
  socket: transport.Connection,
  step: Result(Step(step_state, outcome), UnexpectedMessage),
  running: fn(step_state) -> Running,
  finish: fn(State, outcome) -> State,
  current: Running,
) -> State {
  case step {
    Ok(Wait(step_state)) -> State(..state, running: Some(running(step_state)))
    Ok(Send(bytes, step_state)) ->
      State(..state, running: Some(running(step_state)))
      |> sent(socket, transport.send(socket, bytes))
    Ok(Finished(outcome)) -> finish(state, outcome) |> next_request
    Ok(ConnectionEnded(report, messages)) ->
      ended(state, socket, current, report, messages)
    Error(unexpected) ->
      failed(
        state,
        socket,
        current,
        ProtocolViolation(UnexpectedServerMessage(unexpected)),
      )
  }
}

fn ended(
  state: State,
  socket: transport.Connection,
  current: Running,
  report: ServerReport,
  messages: List(AsynchronousMessage),
) -> State {
  let state = State(..state, pending: append(reverse(messages), state.pending))
  failed(state, socket, current, ServerEndedConnection(report))
}

/// The request failed in a way that leaves the connection in an unknown
/// state: the caller gets the error, and the process connects again.
fn failed(
  state: State,
  socket: transport.Connection,
  current: Running,
  error: DriverError,
) -> State {
  lose(State(..state, running: Some(current)), socket, error)
}

fn finish_prepare(
  state: State,
  outcome: query.Outcome(StatementDescription, Failure),
  reply_to: ReplyTo(Result(StatementDescription, DriverError)),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let result = outcome.result |> map_error(step_failure(_, outcome.status, []))
  reply(reply_to, result)
  State(..state, tracker:)
}

fn finish_run(
  state: State,
  outcome: query.Outcome(StatementResult, Failure),
  reply_to: ReplyTo(Result(Outcome, DriverError)),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let #(state, result) = case outcome.result {
    Ok(statement) -> {
      let #(state, single) =
        take_pending(state, plain_outcome(statement, outcome.status))
      #(state, Ok(single))
    }
    Error(failure) -> #(state, Error(step_failure(failure, outcome.status, [])))
  }
  reply(reply_to, result)
  State(..state, tracker:)
}

fn finish_script(
  state: State,
  outcome: query.Outcome(List(StatementResult), ScriptFailure),
  reply_to: ReplyTo(Result(List(Outcome), DriverError)),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_script(state.tracker, outcome)
  let #(state, result) = script_result(state, outcome)
  reply(reply_to, result)
  State(..state, tracker:)
}

fn script_result(
  state: State,
  outcome: query.Outcome(List(StatementResult), ScriptFailure),
) -> #(State, Result(List(Outcome), DriverError)) {
  case outcome.result {
    Ok(statements) -> {
      let #(state, outcomes) = outcomes_of(state, statements, outcome.status)
      #(state, Ok(outcomes))
    }
    Error(ScriptFailure(completed:, failure:)) -> {
      let #(state, outcomes) = outcomes_of(state, completed, outcome.status)
      #(state, Error(step_failure(failure, outcome.status, outcomes)))
    }
  }
}

fn step_failure(
  failure: Failure,
  status: TransactionStatus,
  completed: List(Outcome),
) -> DriverError {
  case failure, completed {
    ServerError(report), [] -> ServerRefused(report, status)
    ServerError(report), _ -> ScriptFailed(completed, report, status)
    CopyNotSupported(_report), _ -> CopyStatementRefused(completed)
  }
}

/// Keeps the parameter changes, and adds the notices and notifications to
/// the pending ones.
fn after_step(state: State, messages: List(AsynchronousMessage)) -> State {
  fold(messages, state, after_message)
}

fn after_message(state: State, message: AsynchronousMessage) -> State {
  case message {
    ParameterChanged(name:, value:) ->
      State(..state, parameters: dict.insert(state.parameters, name, value))
    _notice_or_notification ->
      State(..state, pending: [message, ..state.pending])
  }
}

/// One outcome for each statement. The last one carries the pending
/// notices and notifications. With no statement, they stay pending for
/// the next outcome.
fn outcomes_of(
  state: State,
  statements: List(StatementResult),
  status: TransactionStatus,
) -> #(State, List(Outcome)) {
  let outcomes = list.map(statements, plain_outcome(_, status))
  case reverse(outcomes) {
    [] -> #(state, [])
    [last, ..earlier] -> {
      let #(state, last) = take_pending(state, last)
      #(state, reverse([last, ..earlier]))
    }
  }
}

/// Gives the outcome the pending notices and notifications, which are
/// then no longer pending.
fn take_pending(state: State, outcome: Outcome) -> #(State, Outcome) {
  #(State(..state, pending: []), with_pending(outcome, state.pending))
}

fn plain_outcome(
  statement: StatementResult,
  status: TransactionStatus,
) -> Outcome {
  Outcome(
    columns: statement.columns,
    result: statement.result,
    notices: [],
    notifications: [],
    transaction_status: status,
  )
}

fn with_pending(
  outcome: Outcome,
  pending: List(AsynchronousMessage),
) -> Outcome {
  let messages = reverse(pending)
  Outcome(
    ..outcome,
    notices: filter_map(messages, notice_of),
    notifications: filter_map(messages, notification_of),
  )
}

fn notice_of(message: AsynchronousMessage) -> Result(ServerReport, Nil) {
  case message {
    Notice(report) -> Ok(report)
    _other -> Error(Nil)
  }
}

fn notification_of(message: AsynchronousMessage) -> Result(Notification, Nil) {
  case message {
    query.Notification(process_id:, channel:, payload:) ->
      Ok(Notification(process_id:, channel:, payload:))
    _other -> Error(Nil)
  }
}

// Losing and connecting again -------------------------------------------------

/// The connection is lost: the socket closes, the running request and
/// every waiting one fail with the error, the subscriber hears of it, and
/// a reconnect follows after the first delay of the backoff.
fn lose(
  state: State,
  socket: transport.Connection,
  error: DriverError,
) -> State {
  transport.close(socket)
  option.map(state.running, refuse_running(_, error))
  list.each(reverse(state.waiting), refuse(_, error))
  tell(state, Disconnected(error))
  schedule_reconnect(state, error, 0)
  State(
    ..state,
    link: Lost(error),
    running: None,
    waiting: [],
    tracker: new_tracker(),
  )
}

fn tell(state: State, event: ConnectionEvent) -> Nil {
  option.map(state.config.events, process.send(_, event))
  Nil
}

fn schedule_reconnect(state: State, error: DriverError, attempt: Int) -> Nil {
  let delay = backoff_delay(state.config.reconnect, attempt)
  process.send_after(state.subject, delay, ReconnectNow(error, attempt))
  Nil
}

/// The first delay, doubled for each failed attempt, up to the longest.
fn backoff_delay(backoff: Backoff, attempt: Int) -> Int {
  let doubled =
    int.bitwise_shift_left(backoff.first_delay_milliseconds, min(attempt, 30))
  min(doubled, backoff.longest_delay_milliseconds)
}

/// Each `ReconnectNow` comes from one loss or one failed attempt, while
/// the link is lost, so the process connects only when it has no socket.
fn reconnect(state: State, error: DriverError, attempt: Int) -> State {
  case open_session(state.config) {
    Ok(session) -> {
      tell(state, Reconnected)
      connected_state(state, session)
    }
    Error(connect_error) -> {
      tell(state, ReconnectFailed(connect_error))
      schedule_reconnect(state, error, attempt + 1)
      state
    }
  }
}

// Connecting and logging in ---------------------------------------------------

/// Connects and logs in, with the socket in passive mode. After it, the
/// socket sends its next message to this process.
fn open_session(config: ConnectionConfig) -> Result(Session, ConnectError) {
  use socket <- try(
    transport.connect(config.transport) |> map_error(TransportRefused),
  )
  case log_in(socket, config) {
    Ok(session) -> Ok(session)
    Error(error) -> {
      transport.close(socket)
      Error(error)
    }
  }
}

fn log_in(
  socket: transport.Connection,
  config: ConnectionConfig,
) -> Result(Session, ConnectError) {
  use #(state, first) <- try(
    login.start(
      config.login,
      random_bytes(login.shortest_client_nonce),
      transport.server_certificate(socket),
    )
    |> map_error(LoginRefused),
  )
  use Nil <- try(send_login_message(socket, first))
  use session <- try(login_messages(socket, state, <<>>, config))
  transport.receive_next(socket)
  |> map_error(TransportRefused)
  |> result.replace(session)
}

fn login_messages(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  config: ConnectionConfig,
) -> Result(Session, ConnectError) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      login.step(state, message)
      |> map_error(LoginRefused)
      |> try(login_step(socket, _, rest, config))
    Ok(NeedMoreBytes) -> more_login_bytes(socket, state, bytes, config)
    Error(error) -> Error(LoginUndecodable(error))
  }
}

fn login_step(
  socket: transport.Connection,
  step: login.LoginStep,
  rest: BitArray,
  config: ConnectionConfig,
) -> Result(Session, ConnectError) {
  case step {
    LoggedIn(outcome) -> Ok(Session(socket:, bytes: rest, outcome:))
    Continue(state:, reply: Some(message)) -> {
      use Nil <- try(send_login_message(socket, message))
      login_messages(socket, state, rest, config)
    }
    Continue(state:, reply: None) -> login_messages(socket, state, rest, config)
  }
}

fn more_login_bytes(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  config: ConnectionConfig,
) -> Result(Session, ConnectError) {
  use more <- try(
    transport.receive(socket, config.setup_timeout_milliseconds)
    |> map_error(TransportRefused),
  )
  login_messages(socket, state, <<bytes:bits, more:bits>>, config)
}

fn send_login_message(
  socket: transport.Connection,
  message: FrontendMessage,
) -> Result(Nil, ConnectError) {
  use bytes <- try(encode(message) |> map_error(LoginUnencodable))
  transport.send(socket, bytes) |> map_error(TransportRefused)
}
