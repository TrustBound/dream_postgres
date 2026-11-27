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
import dream_postgres/driver/deadline.{type Deadline}
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
  type PrepareState, type RunState, type ScriptFailure, type SimpleQueryState,
  type Start, type StatementResult, type Step, type UnexpectedMessage,
  ConnectionEnded, CopyNotSupported, Finished, Notice, ParameterChanged,
  ScriptFailure, Send, ServerError, Wait,
}
import dream_postgres/driver/statement_cache.{
  type CachedStatement, type StatementCache, CachedStatement,
}
import dream_postgres/driver/transaction.{
  type TransactionTracker, aborting_error, new_tracker, track, track_script,
  track_step, transaction_status as tracked_status,
}
import dream_postgres/driver/transport.{
  type TransportConfig, type TransportError, BytesReceived, ConnectTimedOut,
  NotThisSocket, ReceiveTimedOut, SocketClosed, SocketEnded, SocketFailed,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type ServerReport, type StatementDescription, type TransactionStatus, Idle,
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
    /// The longest time for one setup: the TCP connect, TLS and the login
    /// together, from the start of the process and again for each
    /// reconnect. Each blocking step waits for its own timeout or for the
    /// time left in the setup, whichever is shorter: the transport's
    /// `connect_timeout_milliseconds` bounds each TCP connect, TLS answer
    /// and TLS handshake, and the up to three connects of `PreferTls` all
    /// fit inside the one setup. A setup that runs out of time fails with
    /// `SetupTimedOut`.
    setup_timeout_milliseconds: Int,
    reconnect: Backoff,
    /// Where the process tells of each loss and each reconnect, for
    /// example to its pool.
    events: Option(Subject(ConnectionEvent)),
    statements: StatementCaching,
  )
}

/// How the process prepares statements.
pub type StatementCaching {
  /// Each statement is prepared one time under a name, and runs again by
  /// that name. The cache keeps at most `limit` statements; the least
  /// recently used one is closed on the server.
  CacheStatements(limit: Int)
  /// Each statement is prepared again on the unnamed statement, for a
  /// pooler such as PgBouncer in transaction mode, where the next
  /// transaction may run on another server session.
  UnnamedStatements
}

/// What the process tells its subscriber about the connection.
///
/// | Event | When the process sends it |
/// |---|---|
/// | `Connected` | Once, after its first login. A process from `start` sends it before `start` returns. |
/// | `ConnectFailed(error)` | After each failed first attempt of a process from `supervised`, until its first login. |
/// | `Disconnected(error)` | When the connection of a process that logged in is lost. |
/// | `ReconnectFailed(error)` | After each failed attempt to connect again after a loss. |
/// | `Reconnected` | When the process logged in again after a loss. |
///
/// Each process speaks only for itself: a process that replaces another
/// starts again with `Connected`.
pub type ConnectionEvent {
  /// The process connected and logged in for the first time.
  Connected
  /// An attempt of a supervised process to connect for the first time
  /// failed. The next one follows after the reconnect backoff.
  ConnectFailed(error: ConnectError)
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
  /// The server made the driver prepare the statement again (SQLSTATE
  /// 0A000 or 26000, outside a transaction), and its description is not
  /// the cached one any more, for example after `ALTER TABLE`. The
  /// statement did not run: check it against `description` and run it
  /// again.
  StatementChanged(description: StatementDescription)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  NotConnected(error: ConnectError)
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
  /// Connects and logs in for the first time: the starter's only
  /// request. The process answers by the end of its own setup deadline.
  OpenRequest(reply: ReplyTo(Result(Nil, ConnectError)))
  /// A supervised process tries to connect and log in for the first time.
  /// A failed attempt sends it again after the reconnect backoff.
  OpenAttempt(attempt: Int)
}

/// A request that goes to the server.
type Request {
  StatementRequest(statement: StatementRequest)
  ScriptRequest(sql: String, reply: ReplyTo(Result(List(Outcome), DriverError)))
}

/// A request about one statement, which the statement cache serves.
type StatementRequest {
  PrepareStatement(
    sql: String,
    reply: ReplyTo(Result(StatementDescription, DriverError)),
  )
  RunStatement(details: RunDetails)
}

/// What a run needs. `previous` is the description of a statement that
/// the server made the driver prepare again: the run goes on only when
/// the new description is the same.
type RunDetails {
  RunDetails(
    sql: String,
    parameters: List(Cell),
    result_formats: List(Format),
    reply: ReplyTo(Result(Outcome, DriverError)),
    previous: Option(StatementDescription),
  )
}

/// The request that runs, with the state of its step.
type Running {
  /// A prepare of the unnamed statement, with no cache.
  RunningPrepare(
    state: PrepareState,
    reply: ReplyTo(Result(StatementDescription, DriverError)),
  )
  /// A run in one round trip on the unnamed statement, with no cache.
  RunningRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, DriverError)),
  )
  RunningScript(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), DriverError)),
  )
  /// A prepare under a new name, for the cache.
  RunningNamedPrepare(
    state: PrepareState,
    request: StatementRequest,
    name: String,
  )
  /// A run of a statement of the cache.
  RunningCachedRun(
    state: RunState,
    details: RunDetails,
    statement: CachedStatement,
  )
}

/// What finishes a step: the state, the socket for a next step of the
/// same request, and the step's outcome.
type Finisher(outcome) =
  fn(State, transport.Connection, outcome) -> State

type Link {
  /// Connected and logged in. `bytes` are read but not decoded yet.
  Open(socket: transport.Connection, bytes: BitArray)
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
    /// The named statements of this session.
    cache: StatementCache,
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

/// Waits for the answer of the process, or for its end, with no timer.
/// Only for a request that the process answers by a deadline of its own.
@external(erlang, "dream_postgres_connection_ffi", "call_until_answer")
fn call_process_until_answer(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
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

/// Starts the process, then asks it to connect and log in. The start of
/// the process does no I/O, and the process answers the open by the end of
/// its own setup deadline, with the session or `SetupTimedOut`. So the
/// starter waits for that answer with a monitor and no timer of its own:
/// no second timer can end a start that the process completed.
fn start_process(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), ConnectError) {
  use started <- try(
    actor.new_with_initialiser(config.setup_timeout_milliseconds, initialise(
      _,
      config,
    ))
    |> actor.on_message(handle_message)
    |> actor.start
    |> map_error(start_failure),
  )
  open_process(started.data) |> result.replace(started)
}

fn open_process(connection: Connection) -> Result(Nil, ConnectError) {
  case
    call_process_until_answer(connection.pid, send_request(
      connection,
      OpenRequest,
      _,
    ))
  {
    Ok(opened) -> opened
    Error(_process_down) -> Error(SetupExited)
  }
}

/// The error of a process that did not start, before it did any I/O.
///
/// ## Parameters
///
/// - `error`: the start error of gleam_otp
///
/// ## Returns
///
/// `SetupTimedOut` when the VM did not run the new process within the
/// setup timeout, and `SetupExited` when it exited while it started.
pub fn start_failure(error: actor.StartError) -> ConnectError {
  case error {
    actor.InitTimeout -> SetupTimedOut
    actor.InitFailed(_) | actor.InitExited(_) -> SetupExited
  }
}

/// The process as a child of a gleam_otp supervisor.
///
/// ## Parameters
///
/// - `config`: the server, the login and the reconnect settings
///
/// ## Returns
///
/// A worker child that starts the process with `config`. The start does
/// not wait for the server: the process connects after it, and a failed
/// attempt is tried again after the reconnect backoff, so a server that is
/// down never fails the supervisor. Until the first login, requests fail
/// with `NotConnected` and the subscriber gets `ConnectFailed` for each
/// failed attempt. The supervisor's shutdown makes the process send
/// Terminate before it stops.
///
/// db_connection does the same: its `init` returns at once and connects
/// in the next event, and a failed connect is logged and tried again after
/// its backoff (db_connection 2.8.1, `DBConnection.Connection`).
pub fn supervised(config: ConnectionConfig) -> ChildSpecification(Connection) {
  supervision.worker(fn() { start_child(config) })
}

fn start_child(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), actor.StartError) {
  actor.new_with_initialiser(config.setup_timeout_milliseconds, fn(subject) {
    process.send(subject, OpenAttempt(0))
    initialise(subject, config)
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Sets up the process with no I/O: the open comes as its first request.
fn initialise(
  subject: Subject(Message),
  config: ConnectionConfig,
) -> Result(actor.Initialised(State, Message, Connection), String) {
  process.trap_exits(True)
  let state = new_state(config, subject)
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_trapped_exits(ExitSignal)
    |> process.select_other(SocketMessage)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Connection(subject:, pid: process.self()))
  |> Ok
}

/// A first open of a supervised process. A failed one leaves the process
/// up, refusing requests with `NotConnected`, and tries again after the
/// reconnect backoff.
fn attempt_first_open(state: State, attempt: Int) -> State {
  case open_session(state.config) {
    Ok(session) -> {
      let state = connected_state(state, session)
      tell(state, Connected)
      state
    }
    Error(error) -> {
      tell(state, ConnectFailed(error))
      let delay = backoff_delay(state.config.reconnect, attempt)
      process.send_after(state.subject, delay, OpenAttempt(attempt + 1))
      State(..state, link: Lost(NotConnected(error)))
    }
  }
}

/// The first open of the process. A process that cannot connect answers
/// with the error and stops.
fn open_first(
  state: State,
  reply_to: ReplyTo(Result(Nil, ConnectError)),
) -> actor.Next(State, Message) {
  case open_session(state.config) {
    Ok(session) -> {
      let state = connected_state(state, session)
      tell(state, Connected)
      reply(reply_to, Ok(Nil))
      actor.continue(state)
    }
    Error(error) -> {
      reply(reply_to, Error(error))
      actor.stop()
    }
  }
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
    cache: new_cache(config),
  )
}

fn new_cache(config: ConnectionConfig) -> StatementCache {
  case config.statements {
    CacheStatements(limit:) -> statement_cache.new(limit)
    UnnamedStatements -> statement_cache.new(1)
  }
}

fn connected_state(state: State, session: Session) -> State {
  let notices = reverse(session.outcome.notices) |> list.map(Notice)
  State(
    ..state,
    link: Open(session.socket, session.bytes),
    parameters: session.outcome.parameters,
    tracker: track(new_tracker(), session.outcome.transaction_status, None),
    cache: new_cache(state.config),
    pending: append(notices, state.pending),
  )
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
  request(connection, prepare_request(sql, _), deadline_milliseconds)
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
    run_request(sql, parameters, result_formats, _),
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

fn prepare_request(
  sql: String,
  reply_to: ReplyTo(Result(StatementDescription, DriverError)),
) -> Request {
  StatementRequest(PrepareStatement(sql, reply_to))
}

fn run_request(
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  reply_to: ReplyTo(Result(Outcome, DriverError)),
) -> Request {
  StatementRequest(
    RunStatement(RunDetails(sql, parameters, result_formats, reply_to, None)),
  )
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
    OpenRequest(reply_to) -> open_first(state, reply_to)
    OpenAttempt(attempt:) -> actor.continue(attempt_first_open(state, attempt))
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
    Open(socket:, ..) -> terminate(socket)
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
    None, Open(socket:, ..) -> begin(state, socket, request)
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
    ScriptRequest(sql:, reply: reply_to) ->
      start_step(
        state,
        socket,
        query.start_simple_query(sql),
        RunningScript(_, reply_to),
        refuse(request, _),
      )
    StatementRequest(statement) -> begin_statement(state, socket, statement)
  }
}

fn begin_statement(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  case state.config.statements {
    UnnamedStatements -> begin_unnamed(state, socket, statement)
    CacheStatements(_) -> look_up(state, socket, statement)
  }
}

fn begin_unnamed(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  case statement {
    PrepareStatement(sql:, reply: reply_to) ->
      start_step(
        state,
        socket,
        query.start_prepare("", sql, []),
        RunningPrepare(_, reply_to),
        refuse_statement(statement, _),
      )
    RunStatement(details) ->
      start_step(
        state,
        socket,
        query.start_prepare_and_run(
          details.sql,
          [],
          details.parameters,
          details.result_formats,
        ),
        RunningRun(_, details.reply),
        refuse_statement(statement, _),
      )
  }
}

fn look_up(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  let sql = statement_sql(statement)
  let #(cache, found) = statement_cache.lookup(state.cache, sql)
  let state = State(..state, cache:)
  case found {
    Some(cached) -> serve_cached(state, socket, statement, cached)
    None -> prepare_named(state, socket, statement)
  }
}

fn statement_sql(statement: StatementRequest) -> String {
  case statement {
    PrepareStatement(sql:, ..) -> sql
    RunStatement(details) -> details.sql
  }
}

fn serve_cached(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
  cached: CachedStatement,
) -> State {
  case statement {
    PrepareStatement(reply: reply_to, ..) -> {
      reply(reply_to, Ok(cached.description))
      next_request(state)
    }
    RunStatement(details) -> run_cached(state, socket, details, cached)
  }
}

fn run_cached(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  start_step(
    state,
    socket,
    query.start_run(cached.name, details.parameters, details.result_formats),
    RunningCachedRun(_, details, cached),
    refuse_statement(RunStatement(details), _),
  )
}

/// Prepares the statement under a new name. On a full cache, the least
/// recently used statement leaves it first, and each statement that left
/// the cache is closed on the server in the same round trip.
fn prepare_named(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  let cache = statement_cache.make_room(state.cache)
  let #(cache, name) = statement_cache.new_name(cache)
  let #(cache, closing) = statement_cache.take_stale(cache)
  start_step(
    State(..state, cache:),
    socket,
    query.start_prepare_closing(closing, name, statement_sql(statement), []),
    RunningNamedPrepare(_, statement, name),
    refuse_statement(statement, _),
  )
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
    StatementRequest(statement) -> refuse_statement(statement, error)
    ScriptRequest(reply: reply_to, ..) -> reply(reply_to, Error(error))
  }
}

fn refuse_statement(statement: StatementRequest, error: DriverError) -> Nil {
  case statement {
    PrepareStatement(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunStatement(details) -> reply(details.reply, Error(error))
  }
}

fn refuse_running(running: Running, error: DriverError) -> Nil {
  case running {
    RunningPrepare(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunningRun(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunningScript(reply: reply_to, ..) -> reply(reply_to, Error(error))
    RunningNamedPrepare(request:, ..) -> refuse_statement(request, error)
    RunningCachedRun(details:, ..) -> reply(details.reply, Error(error))
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

/// Starts the oldest waiting request, if no request runs and one waits.
fn next_request(state: State) -> State {
  case state.running, reverse(state.waiting) {
    None, [oldest, ..others] ->
      accept_request(State(..state, waiting: reverse(others)), oldest)
    _, _ -> state
  }
}

// Socket messages -------------------------------------------------------------

fn socket_message_received(state: State, socket_message: Dynamic) -> State {
  case state.link {
    Open(socket:, bytes:) ->
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
      State(..state, link: Open(socket, <<bytes:bits, more:bits>>))
      |> read_messages
      |> receive_next
    SocketEnded -> lose(state, socket, ConnectionLost(SocketClosed))
    SocketFailed(error) -> lose(state, socket, ConnectionLost(error))
    NotThisSocket -> state
  }
}

fn receive_next(state: State) -> State {
  case state.link {
    Open(socket:, ..) -> sent(state, socket, transport.receive_next(socket))
    Lost(..) -> state
  }
}

/// Decodes and handles each whole message of the buffer.
fn read_messages(state: State) -> State {
  case state.link {
    Open(socket:, bytes:) -> read_message(state, socket, bytes)
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
      State(..state, link: Open(socket, rest))
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
    RunningNamedPrepare(state: step_state, request:, name:) ->
      follow(
        state,
        socket,
        query.step_prepare(step_state, message),
        RunningNamedPrepare(_, request, name),
        named_prepare_finisher(request, name),
        running,
      )
    RunningCachedRun(state: step_state, details:, statement:) ->
      follow(
        state,
        socket,
        query.step_run(step_state, message),
        RunningCachedRun(_, details, statement),
        cached_run_finisher(details, statement),
        running,
      )
  }
}

fn prepare_finisher(
  reply_to: ReplyTo(Result(StatementDescription, DriverError)),
) -> Finisher(query.Outcome(StatementDescription, Failure)) {
  fn(state, _socket, outcome) { finish_prepare(state, outcome, reply_to) }
}

fn run_finisher(
  reply_to: ReplyTo(Result(Outcome, DriverError)),
) -> Finisher(query.Outcome(StatementResult, Failure)) {
  fn(state, _socket, outcome) { finish_run(state, outcome, reply_to) }
}

fn script_finisher(
  reply_to: ReplyTo(Result(List(Outcome), DriverError)),
) -> Finisher(query.Outcome(List(StatementResult), ScriptFailure)) {
  fn(state, _socket, outcome) { finish_script(state, outcome, reply_to) }
}

fn named_prepare_finisher(
  request: StatementRequest,
  name: String,
) -> Finisher(query.Outcome(StatementDescription, Failure)) {
  fn(state, socket, outcome) {
    finish_named_prepare(state, socket, outcome, request, name)
  }
}

fn cached_run_finisher(
  details: RunDetails,
  statement: CachedStatement,
) -> Finisher(query.Outcome(CommandResult, Failure)) {
  fn(state, socket, outcome) {
    finish_cached_run(state, socket, outcome, details, statement)
  }
}

/// Goes on with a step: sends what it asks, waits, or finishes it.
fn follow(
  state: State,
  socket: transport.Connection,
  step: Result(Step(step_state, outcome), UnexpectedMessage),
  running: fn(step_state) -> Running,
  finish: Finisher(outcome),
  current: Running,
) -> State {
  case step {
    Ok(Wait(step_state)) -> State(..state, running: Some(running(step_state)))
    Ok(Send(bytes, step_state)) ->
      State(..state, running: Some(running(step_state)))
      |> sent(socket, transport.send(socket, bytes))
    Ok(Finished(outcome)) -> finish(state, socket, outcome) |> next_request
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

fn finish_named_prepare(
  state: State,
  socket: transport.Connection,
  outcome: query.Outcome(StatementDescription, Failure),
  request: StatementRequest,
  name: String,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let state = State(..state, tracker: track_step(state.tracker, outcome))
  case outcome.result {
    Ok(description) -> {
      let sql = statement_sql(request)
      let cache = statement_cache.insert(state.cache, sql, name, description)
      prepared(
        State(..state, cache:),
        socket,
        request,
        CachedStatement(name, description),
      )
    }
    Error(failure) -> {
      refuse_statement(request, step_failure(failure, outcome.status, []))
      state
    }
  }
}

fn prepared(
  state: State,
  socket: transport.Connection,
  request: StatementRequest,
  cached: CachedStatement,
) -> State {
  case request {
    PrepareStatement(reply: reply_to, ..) -> {
      reply(reply_to, Ok(cached.description))
      state
    }
    RunStatement(details) -> run_prepared(state, socket, details, cached)
  }
}

/// A run after a prepare goes on, unless the server made the driver
/// prepare again and the description changed.
fn run_prepared(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  case details.previous {
    Some(previous) if previous != cached.description -> {
      reply(details.reply, Error(StatementChanged(cached.description)))
      state
    }
    _ -> run_cached(state, socket, details, cached)
  }
}

fn finish_cached_run(
  state: State,
  socket: transport.Connection,
  outcome: query.Outcome(CommandResult, Failure),
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let state = State(..state, tracker: track_step(state.tracker, outcome))
  case outcome.result {
    Ok(command) -> {
      let outcome =
        Outcome(cached.description.columns, command, [], [], outcome.status)
      let #(state, single) = take_pending(state, outcome)
      reply(details.reply, Ok(single))
      state
    }
    Error(ServerError(report)) ->
      cached_run_refused(state, socket, details, cached, report, outcome.status)
    Error(failure) -> {
      reply(details.reply, Error(step_failure(failure, outcome.status, [])))
      state
    }
  }
}

/// SQLSTATE 0A000 (the cached plan must not change its result type) and
/// 26000 (no such prepared statement) mean that the cached statement is
/// stale: it leaves the cache. Outside a transaction, the run prepares the
/// statement again and runs one more time. Inside one, the error goes to
/// the caller, because the transaction failed.
fn cached_run_refused(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
  report: ServerReport,
  status: TransactionStatus,
) -> State {
  let stale = report.code == "0A000" || report.code == "26000"
  let state = case stale {
    True ->
      State(..state, cache: statement_cache.forget(state.cache, details.sql))
    False -> state
  }
  case stale, details.previous, status {
    True, None, Idle ->
      look_up(
        state,
        socket,
        RunStatement(RunDetails(..details, previous: Some(cached.description))),
      )
    _, _, _ -> {
      reply(details.reply, Error(ServerRefused(report, status)))
      state
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
  let setup_deadline = deadline.from_now(config.setup_timeout_milliseconds)
  use socket <- try(
    transport.connect(config.transport, setup_deadline)
    |> map_error(setup_transport_error(_, setup_deadline)),
  )
  case log_in(socket, config, setup_deadline) {
    Ok(session) -> Ok(session)
    Error(error) -> {
      transport.close(socket)
      Error(error)
    }
  }
}

/// A step that timed out once the setup deadline had passed ran out of the
/// setup time. Any other failure is the transport's own, for example the
/// connect timeout of one TCP connect while setup time was left.
fn setup_transport_error(
  error: TransportError,
  setup_deadline: Deadline,
) -> ConnectError {
  case error, deadline.has_passed(setup_deadline) {
    ConnectTimedOut, True | ReceiveTimedOut, True -> SetupTimedOut
    _, _ -> TransportRefused(error)
  }
}

fn log_in(
  socket: transport.Connection,
  config: ConnectionConfig,
  setup_deadline: Deadline,
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
  use session <- try(login_messages(socket, state, <<>>, setup_deadline))
  transport.receive_next(socket)
  |> map_error(TransportRefused)
  |> result.replace(session)
}

fn login_messages(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      login.step(state, message)
      |> map_error(LoginRefused)
      |> try(login_step(socket, _, rest, setup_deadline))
    Ok(NeedMoreBytes) -> more_login_bytes(socket, state, bytes, setup_deadline)
    Error(error) -> Error(LoginUndecodable(error))
  }
}

fn login_step(
  socket: transport.Connection,
  step: login.LoginStep,
  rest: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  case step {
    LoggedIn(outcome) -> Ok(Session(socket:, bytes: rest, outcome:))
    Continue(state:, reply: Some(message)) -> {
      use Nil <- try(send_login_message(socket, message))
      login_messages(socket, state, rest, setup_deadline)
    }
    Continue(state:, reply: None) ->
      login_messages(socket, state, rest, setup_deadline)
  }
}

fn more_login_bytes(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  use more <- try(
    transport.receive(socket, deadline.time_left(setup_deadline))
    |> map_error(setup_transport_error(_, setup_deadline)),
  )
  login_messages(socket, state, <<bytes:bits, more:bits>>, setup_deadline)
}

fn send_login_message(
  socket: transport.Connection,
  message: FrontendMessage,
) -> Result(Nil, ConnectError) {
  use bytes <- try(encode(message) |> map_error(LoginUnencodable))
  transport.send(socket, bytes) |> map_error(TransportRefused)
}
