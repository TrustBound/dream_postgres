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
//// A COPY streams its rows between the caller's process and the socket:
//// `copy_from` sends each chunk of the caller to the socket before the
//// caller makes the next one, and `copy_to` reads the next row from the
//// socket only after the caller took the last one. The caller's process
//// makes and reads the data; the connection process keeps the socket. The
//// connection serves its COPY caller only, up to the end of the COPY.
////
//// Messages that the server sends between requests are kept, not dropped:
//// a parameter change updates `server_parameter`, and a notice or a
//// notification goes with the outcome of the next request.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/deadline.{type Deadline}
import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/login.{
  type CancelKey, type LoginConfig, type LoginError, type LoginMessage,
  type LoginOutcome, type LoginStartError, type LoginState,
  ChannelBindingRequiresTls, Continue, LoggedIn, encode_login_message,
}
import dream_postgres/driver/message.{
  type BackendMessage, type EncodeError, type FrontendMessage,
  type ProtocolError, CancelRequest, Decoded, ErrorResponse, NeedMoreBytes,
  NoticeResponse, NotificationResponse, ParameterStatus,
}
import dream_postgres/driver/query.{
  type AsynchronousMessage, type CopyDirection, type CopyResult, type CopyState,
  type CopyStep, type Failure, type HousekeepingStart, type PrepareAndRunState,
  type PrepareState, type RunState, type ScriptFailure, type SimpleQueryState,
  type Start, type StatementResult, type Step, type UnexpectedMessage,
  CopyCompleted, CopyConnectionEnded, CopyFinished, CopyFrom, CopyNotSupported,
  CopyRow, CopySend, CopyStarted, CopyTo, CopyWait, Finished, NoCopyStarted,
  Notice, ParameterChanged, ScriptFailure, Send, ServerError, Wait,
}
import dream_postgres/driver/statement_cache.{
  type CachedStatement, type StatementCache, CachedStatement,
}
import dream_postgres/driver/trace.{
  type SpanEnd, type SpanTarget, Failed, SpanQuery, SpanTarget, Worked,
}
import dream_postgres/driver/transaction.{
  type TransactionTracker, aborting_error, new_tracker, track, track_script,
  track_step, transaction_status as tracked_status,
}
import dream_postgres/driver/transport.{
  type ReceiveError, type SendError, type SocketError, type TransportConfig,
  type TransportError, BytesReceived, ConnectTimedOut, NotThisSocket,
  ReceiveFailed, ReceiveTimedOut, SendFailed, SendTimedOut, SocketClosed,
  SocketEnded,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type ServerReport, type StatementDescription, type TransactionStatus, Idle,
}
import gleam/bit_array.{concat}
import gleam/bool.{guard}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{
  type Down, type ExitMessage, type Monitor, type Pid, type Subject, type Timer,
}
import gleam/erlang/reference.{type Reference}
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
    /// The longest time that a cancel may take after a deadline passed:
    /// to open its connection, and for the server to stop the statement.
    /// After it, the connection is closed and replaced.
    cancel_timeout_milliseconds: Int,
    reconnect: Backoff,
    /// Where the process tells of each loss and each reconnect, for
    /// example to its pool.
    events: Option(Subject(ConnectionEvent)),
    /// Where the process sends each notification at once, as it arrives,
    /// also while the connection is idle, for example to the listener.
    /// With `None`, each notification goes with the next outcome.
    notifications: Option(Subject(Notification)),
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
  Disconnected(error: ConnectionEnd)
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
  /// The socket failed during the login, for example because the server
  /// closed it.
  LoginSocketFailed(error: SocketError)
  /// A login message could not be sent, for example because the server
  /// read nothing of it for the send timeout.
  LoginSendFailed(error: SendError)
  /// The login settings require channel binding, and the connection has
  /// no TLS: its transport has `NoTls`, or `PreferTls` and a server that
  /// refused TLS. No login message went to the server.
  LoginRequiresTls
  /// The login failed, for example with the server's 28P01.
  LoginRefused(error: LoginError)
  /// The server sent bytes during the login that are not a valid message.
  LoginUndecodable(error: ProtocolError)
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

/// Why a connection was lost.
pub type LossReason {
  /// The socket closed or failed.
  SocketFailed(error: SocketError)
  /// The server read nothing for the send timeout, so the socket closed.
  ServerStoppedReading
  /// The deadline of the running request passed and its cancel did not
  /// end it in time, so the process closed the connection. The request
  /// whose deadline passed gets `DeadlinePassed(cancelled: False)`. The
  /// requests that waited behind it, and the ones that come while the
  /// process connects again, get this reason.
  ClosedAfterDeadline
}

/// Why a connection ended. The process connects again.
pub type ConnectionEnd {
  /// The connection is gone. `reason` says why.
  ConnectionLost(reason: LossReason)
  /// The server ended the session with a FATAL or PANIC error, for example
  /// `57P01` when an administrator stops it.
  ServerEndedConnection(report: ServerReport)
  /// The server broke the protocol.
  ProtocolViolation(violation: Violation)
}

/// A failure that any request can meet on its connection: the process is
/// gone, the deadline passed, or the connection ended.
pub type RequestFailure {
  /// The connection process is gone, for example after `stop`.
  ConnectionProcessDown
  /// The deadline passed before the result came. `cancelled` says whether
  /// the server confirmed a cancel. A request that waited behind another
  /// one, or a caller that got no answer in time, gets `False`.
  DeadlinePassed(cancelled: Bool)
  /// The connection ended. `end` says why.
  ConnectionEnded(end: ConnectionEnd)
}

/// Why `transaction_status`, `aborted_by` or `server_parameter` failed.
/// They read the state of the process only, so only the process can fail
/// them.
pub type ConnectionStateError {
  /// The connection process is gone.
  ProcessGone
  /// The connection process did not answer in time, for example because
  /// it is suspended.
  NoAnswerInTime
}

/// Why `settled_transaction_status` failed.
pub type SettleError {
  /// The request failed on its connection.
  SettleFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  SettleNotConnected(error: ConnectError)
}

/// Why `prepare` failed.
pub type PrepareError {
  /// The request failed on its connection.
  PrepareFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  PrepareNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  PrepareUnencodable(error: EncodeError)
  /// The server refused the statement. The connection stays usable.
  PrepareRefused(report: ServerReport, transaction_status: TransactionStatus)
}

/// Why `run` failed.
pub type RunError {
  /// The request failed on its connection.
  RunFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  RunNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  RunUnencodable(error: EncodeError)
  /// The server refused the statement. The connection stays usable.
  RunRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The statement is a COPY. COPY goes through `copy_from` and `copy_to`.
  /// The driver ended it, and the connection stays usable.
  RunCopyRefused
  /// The server made the driver prepare the statement again (SQLSTATE
  /// 0A000 or 26000, outside a transaction), and its description is not
  /// the cached one any more, for example after `ALTER TABLE`. The
  /// statement did not run: check it against `description` and run it
  /// again.
  RunStatementChanged(description: StatementDescription)
}

/// Why `run_script` or `run_listener_script` failed.
pub type ScriptError {
  /// The request failed on its connection.
  ScriptRequestFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  ScriptNotConnected(error: ConnectError)
  /// The script cannot be written, for example SQL with a zero byte. No
  /// byte went to the server.
  ScriptUnencodable(error: EncodeError)
  /// The server refused the first statement of the script, so no
  /// statement ran. The connection stays usable.
  ScriptRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// A later statement of the script failed, after the ones in
  /// `completed` ran. `completed` is never empty: a failure of the first
  /// statement is `ScriptRefused`.
  ScriptFailed(
    completed: List(Outcome),
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// A statement of the script is a COPY. COPY goes through `copy_from`
  /// and `copy_to`. `completed` holds the statements that ran before it.
  ScriptCopyRefused(completed: List(Outcome))
}

/// Why `run_housekeeping` or `run_housekeeping_script` failed. A
/// housekeeping statement always encodes, runs on the unnamed statement
/// and is one statement that is not a COPY, so no case of an unencodable
/// statement, a changed statement or a later statement is here.
pub type HousekeepingError {
  /// The request failed on its connection.
  HousekeepingFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  HousekeepingNotConnected(error: ConnectError)
  /// The server refused the statement. The connection stays usable.
  HousekeepingRefused(
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// The server answered as no PostgreSQL server answers the statement:
  /// with a COPY, or with an error after a result. The connection stays
  /// usable.
  HousekeepingAnswerUnexpected
}

/// Why a `copy_from` or a `copy_to` failed.
pub type CopyError(reason) {
  /// The app's function failed with `reason`. The driver ended the COPY: a
  /// `COPY ... FROM STDIN` got a CopyFail, so the server stored no row of
  /// it, and the rest of a `COPY ... TO STDOUT` was read and dropped. The
  /// connection stays usable.
  AppFailed(reason: reason)
  /// The request failed on its connection.
  CopyFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  CopyNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  CopyUnencodable(error: EncodeError)
  /// The server refused the COPY or a row of it, for example a row that
  /// is not valid. The connection stays usable.
  CopyRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The SQL of `copy_from` did not start a `COPY ... FROM STDIN`, or the
  /// SQL of `copy_to` did not start a `COPY ... TO STDOUT`. `completed`
  /// says what ran:
  ///
  /// - `Some(outcome)`: the statement ran to its end. A statement that is
  ///   not a COPY gives its tag and its rows, as text cells, with no
  ///   columns, because the driver does not describe it. A
  ///   `COPY ... TO STDOUT` given to `copy_from` gives its tag, such as
  ///   `COPY 3`, and no rows: the driver read them and dropped them.
  /// - `None`: a `COPY ... FROM STDIN` given to `copy_to`. The driver ended
  ///   it with CopyFail, so the server stored no row. Inside a transaction,
  ///   the transaction failed.
  CopyNotStarted(completed: Option(Outcome))
}

/// Why `send_chunk` failed. The server takes no more data: give `Error`
/// from the function of `copy_from`.
pub type ChunkError {
  /// The request failed on its connection, or the deadline of the COPY
  /// passed.
  ChunkFailed(failure: RequestFailure)
  /// The COPY of the sender does not take data: it ended, for example
  /// because its `copy_from` returned already.
  ChunkCopyNotRunning
  /// The server refused the COPY, for example a row that is not valid.
  ChunkRefused(report: ServerReport, transaction_status: TransactionStatus)
}

/// What the function of `copy_from` sends its chunks with, while its COPY
/// runs.
pub opaque type CopySender {
  CopySender(
    connection: Connection,
    /// The COPY of this sender. The caller makes it, so it can end the
    /// COPY even before the connection process answered the start.
    id: Reference,
    /// The longest time that the caller waits for each answer or push.
    wait_milliseconds: Int,
    /// Where the connection process pushes the rows and the end of the
    /// COPY: a monitor of the connection process that is also an alias of
    /// the caller. Only the process that made the sender waits on it.
    pushes: ReplyTo(CopyPush),
  )
}

/// A connection process.
pub opaque type Connection {
  Connection(
    subject: Subject(Message),
    pid: Pid,
    /// How much longer than its deadline a caller waits for the answer:
    /// the time of a cancel, and of a reconnect that runs before the
    /// request.
    reply_margin_milliseconds: Int,
    /// The database and the server that each span of a statement names.
    span_target: SpanTarget,
  )
}

/// The text of a statement, and the caller's name of it for its span.
pub opaque type Statement {
  Statement(sql: String, name: Option(String))
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

/// Why the process refuses a request that it does not run: the link is
/// down, or the deadline of the request passed while it waited.
type Refusal {
  RefusedWithFailure(failure: RequestFailure)
  RefusedNotConnected(error: ConnectError)
}

/// Why a COPY that the process ran gave no row count: what its caller
/// gets with its start, its calls, or its end.
type CopyFault {
  CopyFaultFailed(failure: RequestFailure)
  CopyFaultRefused(report: ServerReport, transaction_status: TransactionStatus)
  CopyFaultNotStarted(completed: Option(Outcome))
}

/// Why the start of a COPY failed.
type CopyStartError {
  /// The process refused the request before it ran.
  StartRefused(refusal: Refusal)
  /// The statement cannot be written.
  StartUnencodable(error: EncodeError)
  /// The COPY ended before it started.
  StartEnded(fault: CopyFault)
}

type Message {
  Request(request: Request, deadline_milliseconds: Int)
  /// The deadline of the request `id` passed.
  DeadlineReached(id: Int)
  /// The cancel of the request `id` sent its CancelRequest, or failed.
  CancelFinished(id: Int, result: Result(Nil, CancelFailure))
  /// The cancel of the request `id` had all its time.
  CancelOver(id: Int)
  SnapshotRequest(reply: ReplyTo(Snapshot))
  StopRequest(reply: ReplyTo(Nil))
  SocketMessage(message: Dynamic)
  ReconnectNow(attempt: Int)
  ExitSignal(exit: ExitMessage)
  /// A chunk of the COPY `id` from its caller. The process answers each
  /// chunk: when it went to the socket, or with the end of the COPY.
  SendChunk(
    id: Reference,
    chunk: BitArray,
    reply: ReplyTo(Result(Nil, ChunkError)),
  )
  /// A notice of the caller of the COPY `id`. A notice needs no answer.
  CopyNotice(id: Reference, notice: CopyNotice)
  /// A process that the connection process watches ended: the caller of a
  /// COPY.
  CallerDown(down: Down)
  /// Connects and logs in for the first time: the starter's only
  /// request. The process answers by the end of its own setup deadline.
  OpenRequest(reply: ReplyTo(Result(Nil, ConnectError)))
  /// A supervised process tries to connect and log in for the first time.
  /// A failed attempt sends it again after the reconnect backoff.
  OpenAttempt(attempt: Int)
}

/// What the caller of a COPY tells the process while its COPY runs. No
/// notice needs an answer: the caller waits only for what the process
/// pushes, and a notice for a COPY that is gone changes nothing.
type CopyNotice {
  /// The caller took the row that the process pushed last. The process
  /// reads on.
  RowTaken
  /// The caller ends its side of the COPY. A COPY that runs ends with
  /// `ending`, and the process pushes the end when it has it. A COPY that
  /// ended already lets the process serve the next request.
  Finish(ending: CopyEnding)
  /// The caller stopped waiting, or its process ended: the COPY is
  /// abandoned, and its end is dropped.
  CallerLeft
}

/// How the caller ends a COPY.
type CopyEnding {
  /// The app sent all its data: the server stores the rows.
  CompleteCopy
  /// The app's function failed: the server stores no row.
  AbandonCopy
}

/// What the process pushes to the caller of a COPY. The caller waits for
/// a push or for the end of the process, so each wait ends.
type CopyPush {
  /// A row of a `COPY ... TO STDOUT`. The process reads nothing more from
  /// the socket until the caller sends `RowTaken`.
  PushedRow(row: BitArray)
  /// The end of the COPY: its row count, or why there is none. The
  /// process pushes it once.
  PushedEnd(result: Result(Int, CopyFault))
}

/// The caller's side of a COPY that runs.
type CopySession {
  CopySession(
    id: Reference,
    /// The monitor of the caller's process.
    monitor: Monitor,
    /// The caller waits for the start of the COPY.
    start: Option(ReplyTo(Result(Nil, CopyStartError))),
    /// Where the process pushes the rows and the end.
    pushes: ReplyTo(CopyPush),
    /// The chunks that wait for the end of the COPY, which is their
    /// answer.
    waiting_chunks: List(ReplyTo(Result(Nil, ChunkError))),
    /// The caller ended its side of the COPY: it needs the COPY no more
    /// after the process pushed the end.
    finished: Bool,
    /// The process pushed a row that the caller did not take yet. The
    /// process reads nothing more from the socket until it does.
    row_pushed: Bool,
  )
}

/// A COPY that ended, whose caller did not finish its side yet. The
/// process pushed the end to the caller already. The connection serves no
/// other request until the caller finishes, or until its process ends.
type EndedCopy {
  EndedCopy(id: Reference, monitor: Monitor, result: Result(Int, CopyFault))
}

/// A request that goes to the server.
type Request {
  StatementRequest(statement: StatementRequest)
  /// The transaction status after every request before it.
  SettledStatusRequest(reply: ReplyTo(Result(TransactionStatus, SettleError)))
  ScriptRequest(sql: String, reply: ReplyTo(Result(List(Outcome), ScriptError)))
  /// A driver housekeeping statement, prepared and run in one round trip.
  HousekeepingRunRequest(
    sql: HousekeepingSql,
    reply: ReplyTo(Result(Outcome, HousekeepingError)),
  )
  /// A driver housekeeping statement, with the simple query protocol.
  HousekeepingScriptRequest(
    sql: HousekeepingSql,
    reply: ReplyTo(Result(List(Outcome), HousekeepingError)),
  )
  /// A COPY. The answer comes when the server started it.
  CopyRequest(
    id: Reference,
    direction: CopyDirection,
    sql: String,
    caller: Pid,
    /// Where the process pushes the rows and the end of the COPY.
    pushes: ReplyTo(CopyPush),
    reply: ReplyTo(Result(Nil, CopyStartError)),
  )
}

/// A request about one statement, which the statement cache serves.
type StatementRequest {
  PrepareStatement(
    sql: String,
    reply: ReplyTo(Result(StatementDescription, PrepareError)),
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
    reply: ReplyTo(Result(Outcome, RunError)),
    previous: Option(StatementDescription),
  )
}

/// The request that runs, with the state of its step.
type Running {
  /// A prepare of the unnamed statement, with no cache.
  RunningPrepare(
    state: PrepareState,
    reply: ReplyTo(Result(StatementDescription, PrepareError)),
  )
  /// A run in one round trip on the unnamed statement, with no cache.
  RunningRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, RunError)),
  )
  RunningScript(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), ScriptError)),
  )
  /// A run of a driver housekeeping statement on the unnamed statement.
  RunningHousekeepingRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, HousekeepingError)),
  )
  /// A driver housekeeping statement with the simple query protocol.
  RunningHousekeepingScript(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), HousekeepingError)),
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
  RunningCopy(state: CopyState, session: CopySession)
}

/// What finishes a step: the state, the socket for a next step of the
/// same request, and the step's outcome.
type Finisher(outcome) =
  fn(State, transport.Connection, outcome) -> State

type Link {
  /// Connected and logged in. `bytes` are read but not decoded yet.
  Open(socket: transport.Connection, bytes: BitArray)
  /// Lost. Requests are refused with `refusal` until the process connects
  /// again.
  Lost(refusal: Refusal)
}

type State {
  State(
    config: ConnectionConfig,
    subject: Subject(Message),
    link: Link,
    parameters: Dict(String, String),
    tracker: TransactionTracker,
    running: Option(Running),
    /// The request that runs, with its deadline.
    current: Option(Current),
    /// The requests that wait, newest first.
    waiting: List(Ticket),
    /// The number of the next request.
    next_id: Int,
    /// The key of this session for a CancelRequest.
    cancel_key: Option(CancelKey),
    /// The notices and notifications since the last outcome, newest first.
    pending: List(AsynchronousMessage),
    /// The named statements of this session.
    cache: StatementCache,
    /// A COPY that ended, until its caller finishes its side.
    copy: Option(EndedCopy),
  )
}

/// Why a cancel did not reach the server.
type CancelFailure {
  CancelUnreachable(error: TransportError)
  CancelNotSent(error: SendError)
  CancelNotAnswered(error: ReceiveError)
  CancelUnencodable(error: EncodeError)
}

/// A request that waits, with its number and its deadline timer.
type Ticket {
  Ticket(id: Int, request: Request, timer: Timer)
}

/// The deadline of the request that runs. After the deadline, the caller
/// gets `DeadlinePassed`; `cancel_confirmed` says whether the server
/// stopped the statement with 57014. The request ends only when its step
/// ended and its cancel is done (`cancel_done`): the server handles a
/// CancelRequest on its own, and one that came late would stop the next
/// statement.
type Current {
  Current(
    id: Int,
    timer: Timer,
    deadline_passed: Bool,
    cancel_confirmed: Bool,
    cancel_done: Bool,
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

/// Makes where the connection process pushes the rows and the end of a
/// COPY: a monitor of the process that is also an alias of the caller.
@external(erlang, "dream_postgres_connection_ffi", "open_pushes")
fn open_pushes(pid: Pid) -> ReplyTo(CopyPush)

/// Waits for the next push, for the end of the connection process, or for
/// `timeout` milliseconds.
@external(erlang, "dream_postgres_connection_ffi", "receive_push")
fn receive_push(
  pushes: ReplyTo(CopyPush),
  timeout: Int,
) -> Result(CopyPush, CallFailure)

/// Waits for the end of a COPY, for the end of the connection process, or
/// for `timeout` milliseconds. A row is not an end: no row comes after
/// the caller ended its side.
@external(erlang, "dream_postgres_connection_ffi", "receive_end")
fn receive_end(
  pushes: ReplyTo(CopyPush),
  timeout: Int,
) -> Result(Result(Int, CopyFault), CallFailure)

/// Turns the pushes off: a push that comes later is dropped, and the
/// pushes that wait in the mailbox are taken out.
@external(erlang, "dream_postgres_connection_ffi", "close_pushes")
fn close_pushes(pushes: ReplyTo(CopyPush)) -> Nil

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
///
/// It is public so that its tests can give it each start error directly.
/// No portable real path gives any of them: the initialiser does no I/O
/// and always returns `Ok`, so `InitFailed` and `InitExited` cannot come
/// from it, and `InitTimeout` needs a VM too busy to run a new process
/// within the setup timeout.
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
/// as not connected, for example with `RunNotConnected`, and the
/// subscriber gets `ConnectFailed` for each failed attempt. The supervisor's shutdown makes the process send
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
    |> process.select_monitors(CallerDown)
    |> process.select_other(SocketMessage)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Connection(
    subject:,
    pid: process.self(),
    reply_margin_milliseconds: config.cancel_timeout_milliseconds
      + config.setup_timeout_milliseconds,
    span_target: span_target(config),
  ))
  |> Ok
}

/// A first open of a supervised process. A failed one leaves the process
/// up, refusing requests as not connected, and tries again after the
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
      State(..state, link: Lost(RefusedNotConnected(error)))
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
    link: Lost(
      RefusedWithFailure(
        ConnectionEnded(ConnectionLost(SocketFailed(SocketClosed))),
      ),
    ),
    parameters: dict.new(),
    tracker: new_tracker(),
    running: None,
    current: None,
    waiting: [],
    next_id: 1,
    cancel_key: None,
    pending: [],
    cache: new_cache(config),
    copy: None,
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
    cancel_key: session.outcome.cancel_key,
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

/// A statement with no name: its span is named after its operation and
/// the database, for example `SELECT app`, or after the database alone
/// when the operation is not known, as after a failure.
///
/// ## Parameters
///
/// - `sql`: the text of the statement
///
/// ## Returns
///
/// The statement.
pub fn statement(sql: String) -> Statement {
  Statement(sql:, name: None)
}

/// Names a statement for its span. The name is recorded as
/// `db.query.summary`, and it becomes the span's name (OTel semantic
/// conventions at commit 7c8eb86d04, docs/db/database-spans.md line 56:
/// "The **span name** SHOULD be
/// `{db.query.summary}` if a summary is available."). So it must be
/// low-cardinality and hold no value: one name for one kind of statement,
/// for example `post.create`. The name plays no part in the statement
/// cache, whose key is the text.
///
/// ## Parameters
///
/// - `statement`: the statement
/// - `name`: the app's name of the statement
///
/// ## Returns
///
/// The statement with the name.
pub fn named(statement: Statement, name: String) -> Statement {
  Statement(..statement, name: Some(name))
}

fn span_target(config: ConnectionConfig) -> SpanTarget {
  let address = config.transport.address
  SpanTarget(
    database: login.database(config.login),
    host: transport.host(address),
    port: transport.port(address),
  )
}

/// Runs the request of a statement inside its span. The span starts and
/// ends in the caller's process, on every answer. A caller that is killed
/// during the call leaves its span unended: the span is not exported, as
/// for any span of a process that ends before it ends its span.
fn traced(
  connection: Connection,
  statement: Statement,
  text: Option(String),
  work: fn() -> Result(value, error),
  ending: fn(Result(value, error)) -> SpanEnd,
) -> Result(value, error) {
  let span =
    trace.start(
      connection.span_target,
      SpanQuery(summary: statement.name, text:),
    )
  let result = work()
  trace.end(span, ending(result))
  result
}

fn prepare_ending(result: Result(value, PrepareError)) -> SpanEnd {
  case result {
    Ok(_value) -> Worked(operation: None, warning_code: None)
    Error(error) ->
      failed_ending(prepare_error_name(error), prepare_report(error))
  }
}

fn outcome_ending(result: Result(Outcome, RunError)) -> SpanEnd {
  case result {
    Ok(outcome) -> worked_ending(outcome)
    Error(error) -> failed_ending(run_error_name(error), run_report(error))
  }
}

fn worked_ending(outcome: Outcome) -> SpanEnd {
  Worked(
    operation: Some(trace.operation_of_tag(outcome.result.tag)),
    warning_code: warning_code([outcome]),
  )
}

/// The last warning code of the notices of the outcomes, in order.
fn warning_code(outcomes: List(Outcome)) -> Option(String) {
  outcomes
  |> list.flat_map(fn(outcome) { outcome.notices })
  |> list.map(fn(notice) { notice.code })
  |> trace.last_warning_code
}

/// A script names its operation only when it ran exactly one statement.
fn script_ending(result: Result(List(Outcome), ScriptError)) -> SpanEnd {
  case result {
    Ok([outcome]) -> worked_ending(outcome)
    Ok(several_or_none) ->
      Worked(operation: None, warning_code: warning_code(several_or_none))
    Error(error) ->
      failed_ending(script_error_name(error), script_report(error))
  }
}

/// The server confirmed the COPY with its CopyInResponse or
/// CopyOutResponse, and ends it with the tag `COPY`.
fn copy_ending(result: Result(value, CopyError(reason))) -> SpanEnd {
  case result {
    Ok(_value) -> Worked(operation: Some("COPY"), warning_code: None)
    Error(error) -> failed_ending(copy_error_name(error), copy_report(error))
  }
}

/// `error.type` is the server's SQLSTATE when there is one, else the
/// error's name (OTel semantic conventions at commit 7c8eb86d04,
/// docs/db/database-spans.md note 9: `error.type` "SHOULD match the
/// `db.response.status_code` returned by the database or the client
/// library, or the canonical name of exception that occurred").
fn failed_ending(name: String, report: Option(ServerReport)) -> SpanEnd {
  case report {
    Some(report) ->
      Failed(error_type: report.code, status_code: Some(report.code))
    None -> Failed(error_type: name, status_code: None)
  }
}

/// The name of a request failure: its constructor's name.
/// A failure of an ended connection is named by the case of its end.
fn failure_name(failure: RequestFailure) -> String {
  case failure {
    ConnectionProcessDown -> "ConnectionProcessDown"
    DeadlinePassed(..) -> "DeadlinePassed"
    ConnectionEnded(ConnectionLost(..)) -> "ConnectionLost"
    ConnectionEnded(ServerEndedConnection(..)) -> "ServerEndedConnection"
    ConnectionEnded(ProtocolViolation(..)) -> "ProtocolViolation"
  }
}

fn failure_report(failure: RequestFailure) -> Option(ServerReport) {
  case failure {
    ConnectionEnded(ServerEndedConnection(report:)) -> Some(report)
    ConnectionProcessDown
    | DeadlinePassed(..)
    | ConnectionEnded(ConnectionLost(..))
    | ConnectionEnded(ProtocolViolation(..)) -> None
  }
}

/// The name of a prepare error: its constructor's name, or the name of the
/// request failure that it holds.
fn prepare_error_name(error: PrepareError) -> String {
  case error {
    PrepareFailed(failure) -> failure_name(failure)
    PrepareNotConnected(..) -> "PrepareNotConnected"
    PrepareUnencodable(..) -> "PrepareUnencodable"
    PrepareRefused(..) -> "PrepareRefused"
  }
}

fn prepare_report(error: PrepareError) -> Option(ServerReport) {
  case error {
    PrepareFailed(failure) -> failure_report(failure)
    PrepareRefused(report:, ..) -> Some(report)
    PrepareNotConnected(..) | PrepareUnencodable(..) -> None
  }
}

/// The name of a run error: its constructor's name, or the name of the
/// request failure that it holds.
fn run_error_name(error: RunError) -> String {
  case error {
    RunFailed(failure) -> failure_name(failure)
    RunNotConnected(..) -> "RunNotConnected"
    RunUnencodable(..) -> "RunUnencodable"
    RunRefused(..) -> "RunRefused"
    RunCopyRefused -> "RunCopyRefused"
    RunStatementChanged(..) -> "RunStatementChanged"
  }
}

fn run_report(error: RunError) -> Option(ServerReport) {
  case error {
    RunFailed(failure) -> failure_report(failure)
    RunRefused(report:, ..) -> Some(report)
    RunNotConnected(..)
    | RunUnencodable(..)
    | RunCopyRefused
    | RunStatementChanged(..) -> None
  }
}

/// The name of a script error: its constructor's name, or the name of the
/// request failure that it holds.
fn script_error_name(error: ScriptError) -> String {
  case error {
    ScriptRequestFailed(failure) -> failure_name(failure)
    ScriptNotConnected(..) -> "ScriptNotConnected"
    ScriptUnencodable(..) -> "ScriptUnencodable"
    ScriptRefused(..) -> "ScriptRefused"
    ScriptFailed(..) -> "ScriptFailed"
    ScriptCopyRefused(..) -> "ScriptCopyRefused"
  }
}

fn script_report(error: ScriptError) -> Option(ServerReport) {
  case error {
    ScriptRequestFailed(failure) -> failure_report(failure)
    ScriptRefused(report:, ..) | ScriptFailed(report:, ..) -> Some(report)
    ScriptNotConnected(..) | ScriptUnencodable(..) | ScriptCopyRefused(..) ->
      None
  }
}

/// The name of a COPY error: its constructor's name, or the name of the
/// request failure that it holds.
fn copy_error_name(error: CopyError(reason)) -> String {
  case error {
    AppFailed(..) -> "AppFailed"
    CopyFailed(failure) -> failure_name(failure)
    CopyNotConnected(..) -> "CopyNotConnected"
    CopyUnencodable(..) -> "CopyUnencodable"
    CopyRefused(..) -> "CopyRefused"
    CopyNotStarted(..) -> "CopyNotStarted"
  }
}

fn copy_report(error: CopyError(reason)) -> Option(ServerReport) {
  case error {
    CopyFailed(failure) -> failure_report(failure)
    CopyRefused(report:, ..) -> Some(report)
    AppFailed(..)
    | CopyNotConnected(..)
    | CopyUnencodable(..)
    | CopyNotStarted(..) -> None
  }
}

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
/// - `Error(PrepareRefused(report, status))`: the server refused it
/// - `Error(PrepareUnencodable(error))`: the SQL cannot be written
/// - `Error(PrepareNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(PrepareFailed(failure))`: the request failed on its connection
pub fn prepare(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
) -> Result(StatementDescription, PrepareError) {
  use <- traced(connection, statement, Some(statement.sql), _, prepare_ending)
  request(
    connection,
    prepare_request(statement.sql, _),
    deadline_milliseconds,
    PrepareFailed,
  )
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
/// - `Error(RunRefused(report, status))`: the server refused it
/// - `Error(RunCopyRefused)`: the statement is a COPY
/// - `Error(RunStatementChanged(description))`: the statement changed on
///   the server since the driver cached it, and did not run
/// - `Error(RunUnencodable(error))`: the SQL or a parameter cannot be
///   written
/// - `Error(RunNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(RunFailed(failure))`: the request failed on its connection
pub fn run(
  connection: Connection,
  statement: Statement,
  parameters: List(Cell),
  result_formats: List(Format),
  deadline_milliseconds: Int,
) -> Result(Outcome, RunError) {
  use <- traced(connection, statement, Some(statement.sql), _, outcome_ending)
  run_without_span(
    connection,
    statement.sql,
    parameters,
    result_formats,
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
/// - `Error(ScriptRefused(report, status))`: the server refused the first
///   statement, so none ran
/// - `Error(ScriptFailed(completed, report, status))`: a later statement
///   failed, after the ones in `completed` ran
/// - `Error(ScriptCopyRefused(completed))`: a statement is a COPY
/// - `Error(ScriptUnencodable(error))`: the script cannot be written
/// - `Error(ScriptNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(ScriptRequestFailed(failure))`: the request failed on its
///   connection
pub fn run_script(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), ScriptError) {
  // A script is not parameterized, so its text may hold values: it is not
  // recorded (OTel semantic conventions at commit 7c8eb86d04,
  // docs/db/database-spans.md note 15: "Non-parameterized query text SHOULD NOT
  // be collected by default unless there is sanitization").
  use <- traced(connection, statement, None, _, script_ending)
  run_script_without_span(connection, statement.sql, deadline_milliseconds)
}

/// Runs a statement that the driver sends for its own housekeeping, from
/// its own processes, with no span: the catalog load. A span records a
/// call that the app made; a statement of the driver's own has no caller
/// span to nest under. It runs on the unnamed statement in one round
/// trip, with no parameter and text results, and never enters the
/// statement cache.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the housekeeping statement
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(Outcome)`: the columns, the rows of cells, the tag and the count
/// - `Error(HousekeepingRefused(report, status))`: the server refused it
/// - `Error(HousekeepingAnswerUnexpected)`: the server answered with a
///   COPY
/// - `Error(HousekeepingNotConnected(error))`: a supervised process has
///   not connected yet
/// - `Error(HousekeepingFailed(failure))`: the request failed on its
///   connection
pub fn run_housekeeping(
  connection: Connection,
  sql: HousekeepingSql,
  deadline_milliseconds: Int,
) -> Result(Outcome, HousekeepingError) {
  request(
    connection,
    HousekeepingRunRequest(sql, _),
    deadline_milliseconds,
    HousekeepingFailed,
  )
}

/// Runs a statement that the driver sends for its own housekeeping, from
/// its own processes, with the simple query protocol and no span: a pool
/// member's ROLLBACK and health check.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the housekeeping statement
/// - `deadline_milliseconds`: the longest time to wait for the result
///
/// ## Returns
///
/// - `Ok(outcomes)`: the one outcome of the statement
/// - `Error(HousekeepingRefused(report, status))`: the server refused it
/// - `Error(HousekeepingAnswerUnexpected)`: the server answered with a
///   COPY, or with an error after a result
/// - `Error(HousekeepingNotConnected(error))`: a supervised process has
///   not connected yet
/// - `Error(HousekeepingFailed(failure))`: the request failed on its
///   connection
pub fn run_housekeeping_script(
  connection: Connection,
  sql: HousekeepingSql,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), HousekeepingError) {
  request(
    connection,
    HousekeepingScriptRequest(sql, _),
    deadline_milliseconds,
    HousekeepingFailed,
  )
}

/// Runs a listener's LISTEN or UNLISTEN, from the listener's own process,
/// with no span. The statement holds the caller's channel, so it is not a
/// housekeeping statement of the closed set, and its encoding stays
/// checked.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: the LISTEN or UNLISTEN
/// - `deadline_milliseconds`: the longest time to wait for all results
///
/// ## Returns
///
/// The result of `run_script`, with the same errors.
pub fn run_listener_script(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), ScriptError) {
  run_script_without_span(connection, sql, deadline_milliseconds)
}

fn run_without_span(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  deadline_milliseconds: Int,
) -> Result(Outcome, RunError) {
  request(
    connection,
    run_request(sql, parameters, result_formats, _),
    deadline_milliseconds,
    RunFailed,
  )
}

fn run_script_without_span(
  connection: Connection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(List(Outcome), ScriptError) {
  request(
    connection,
    ScriptRequest(sql, _),
    deadline_milliseconds,
    ScriptRequestFailed,
  )
}

/// The transaction status after the last request.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
///
/// ## Parameters
///
/// - `connection`: the connection
///
/// ## Returns
///
/// - `Ok(TransactionStatus)`: idle, in a transaction, or in a failed one
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn transaction_status(
  connection: Connection,
) -> Result(TransactionStatus, ConnectionStateError) {
  snapshot(connection) |> result.map(snapshot_status)
}

/// The transaction status after the running request and every request
/// that waits before this one finished, for example the requests of a
/// caller that stopped waiting. A pool reads it before it hands the
/// connection to the next holder.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `deadline_milliseconds`: the longest time to wait
///
/// ## Returns
///
/// - `Ok(TransactionStatus)`: idle, in a transaction, or in a failed one
/// - `Error(SettleNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(SettleFailed(failure))`: the connection is lost, the process
///   is gone, or the deadline passed
pub fn settled_transaction_status(
  connection: Connection,
  deadline_milliseconds: Int,
) -> Result(TransactionStatus, SettleError) {
  request(connection, SettledStatusRequest, deadline_milliseconds, SettleFailed)
}

fn snapshot_status(snapshot: Snapshot) -> TransactionStatus {
  snapshot.transaction_status
}

/// The report of the statement that failed the transaction.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
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
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn aborted_by(
  connection: Connection,
) -> Result(Option(ServerReport), ConnectionStateError) {
  snapshot(connection) |> result.map(snapshot_aborted_by)
}

fn snapshot_aborted_by(snapshot: Snapshot) -> Option(ServerReport) {
  snapshot.aborted_by
}

/// A run-time parameter that the server reported, for example
/// `server_version` or `TimeZone`, with its latest value.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
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
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn server_parameter(
  connection: Connection,
  name: String,
) -> Result(Option(String), ConnectionStateError) {
  snapshot(connection) |> result.map(parameter_of(_, name))
}

fn parameter_of(snapshot: Snapshot, name: String) -> Option(String) {
  dict.get(snapshot.parameters, name) |> option.from_result
}

// COPY ------------------------------------------------------------------------

/// Streams rows from the app into a table with a `COPY ... FROM STDIN`.
/// `produce` runs in the caller's process and sends the data with
/// `send_chunk`, which returns only when the chunk went to the socket, so
/// the app never makes data faster than the socket takes it. The driver
/// ends the COPY: with CopyDone when `produce` gives `Ok`, and with
/// CopyFail when it gives `Error`, so the server stores no row. The
/// connection serves no other request until `copy_from` returns.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: one `COPY ... FROM STDIN` statement, with the format of the
///   data (text, csv or binary)
/// - `deadline_milliseconds`: the longest time for the whole COPY, from
///   the moment the connection process takes the request, with the time
///   of `produce`. When it passes, the driver ends the COPY on the server,
///   and each `send_chunk` after it gives `ChunkFailed(DeadlinePassed)`. The driver
///   cannot stop `produce` itself, which runs in the caller's process:
///   `copy_from` returns when `produce` returns.
/// - `produce`: makes the data and sends it in chunks
///
/// ## Returns
///
/// - `Ok(count)`: the number of rows that the server stored
/// - `Error(AppFailed(reason))`: `produce` failed; no row is stored
/// - `Error(CopyNotStarted(completed))`: the SQL was not a
///   `COPY ... FROM STDIN`; `completed` holds what ran instead
/// - `Error(CopyRefused(report, status))`: the server refused the COPY or
///   a row
/// - `Error(CopyUnencodable(error))`: the SQL cannot be written
/// - `Error(CopyNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(CopyFailed(failure))`: the deadline passed, or the request
///   failed on its connection
pub fn copy_from(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
  produce: fn(CopySender) -> Result(Nil, reason),
) -> Result(Int, CopyError(reason)) {
  use <- traced(connection, statement, Some(statement.sql), _, copy_ending)
  use sender <- with_sender(connection, deadline_milliseconds)
  use Nil <- try(start_copy(
    sender,
    CopyFrom,
    statement.sql,
    deadline_milliseconds,
  ))
  case produce(sender) {
    Ok(Nil) -> end_copy(sender, CompleteCopy)
    Error(reason) -> end_copy(sender, AbandonCopy) |> abandoned(reason)
  }
}

/// Sends one chunk of the data of a `copy_from`, and returns when the
/// chunk went to the socket. A chunk is any part of the COPY data stream:
/// its end need not be the end of a row.
///
/// ## Parameters
///
/// - `sender`: the sender that `copy_from` gave
/// - `chunk`: the bytes, in the format of the COPY
///
/// ## Returns
///
/// - `Ok(Nil)`: the chunk went to the socket
/// - `Error(ChunkRefused(report, status))`: the server refused the COPY,
///   for example a row that is not valid
/// - `Error(ChunkCopyNotRunning)`: the COPY ended, for example because
///   its `copy_from` returned already
/// - `Error(ChunkFailed(failure))`: the deadline of the COPY passed, or the
///   request failed on its connection
///
/// After an error the server takes no more data: give `Error` from
/// `produce`.
pub fn send_chunk(
  sender: CopySender,
  chunk: BitArray,
) -> Result(Nil, ChunkError) {
  call(
    sender.connection,
    SendChunk(sender.id, chunk, _),
    sender.wait_milliseconds,
  )
  |> map_error(ChunkFailed)
  |> result.flatten
}

/// Streams rows out of a table with a `COPY ... TO STDOUT`, and folds over
/// them one at a time in the caller's process. The connection process
/// reads the next row from the socket only after `fold` took the last one,
/// so neither process holds the whole result. When `fold` fails, the
/// driver reads the rest of the COPY and drops it, so the session and a
/// transaction that it is in stay usable. The time that this takes grows
/// with the rows that are left, and the deadline bounds it. The
/// connection serves no other request until `copy_to` returns.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `sql`: one `COPY ... TO STDOUT` statement, with the format of the
///   rows (text, csv or binary)
/// - `deadline_milliseconds`: the longest time for the whole COPY, from
///   the moment the connection process takes the request, with the time
///   of `fold` and of reading the rest after `fold` failed. When it
///   passes, the driver cancels the COPY on the server, and the next row
///   gives `CopyFailed(DeadlinePassed)`. The driver cannot stop `fold` itself, which
///   runs in the caller's process.
/// - `initial`: the first value of the fold
/// - `fold`: takes the value and the bytes of one row, in the format of
///   the COPY, and gives the next value
///
/// ## Returns
///
/// - `Ok(value)`: the value after the last row
/// - `Error(AppFailed(reason))`: `fold` failed
/// - `Error(CopyNotStarted(completed))`: the SQL was not a
///   `COPY ... TO STDOUT`; `completed` holds what ran instead
/// - `Error(CopyRefused(report, status))`: the server refused the COPY
/// - `Error(CopyUnencodable(error))`: the SQL cannot be written
/// - `Error(CopyNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(CopyFailed(failure))`: the deadline passed, or the request
///   failed on its connection
pub fn copy_to(
  connection: Connection,
  statement: Statement,
  deadline_milliseconds: Int,
  initial: value,
  fold: fn(value, BitArray) -> Result(value, reason),
) -> Result(value, CopyError(reason)) {
  use <- traced(connection, statement, Some(statement.sql), _, copy_ending)
  use sender <- with_sender(connection, deadline_milliseconds)
  use Nil <- try(start_copy(
    sender,
    CopyTo,
    statement.sql,
    deadline_milliseconds,
  ))
  read_rows(sender, initial, fold)
}

/// Runs `copy` with a new sender, and turns the sender's pushes off after
/// it, on every path, so no push stays in the caller's mailbox.
fn with_sender(
  connection: Connection,
  deadline_milliseconds: Int,
  copy: fn(CopySender) -> Result(value, CopyError(reason)),
) -> Result(value, CopyError(reason)) {
  let sender =
    CopySender(
      connection:,
      id: reference.new(),
      wait_milliseconds: deadline_milliseconds
        + connection.reply_margin_milliseconds,
      pushes: open_pushes(connection.pid),
    )
  let copied = copy(sender)
  close_pushes(sender.pushes)
  copied
}

fn start_copy(
  sender: CopySender,
  direction: CopyDirection,
  sql: String,
  deadline_milliseconds: Int,
) -> Result(Nil, CopyError(reason)) {
  let caller = process.self()
  call(
    sender.connection,
    request_message(
      CopyRequest(sender.id, direction, sql, caller, sender.pushes, _),
      deadline_milliseconds,
      _,
    ),
    deadline_milliseconds + sender.connection.reply_margin_milliseconds,
  )
  |> copy_started
  |> map_error(leave_copy(sender, _))
}

fn copy_started(
  called: Result(Result(Nil, CopyStartError), RequestFailure),
) -> Result(Nil, CopyError(reason)) {
  case called {
    Ok(started) -> map_error(started, copy_start_error)
    Error(failure) -> Error(CopyFailed(failure))
  }
}

fn copy_start_error(error: CopyStartError) -> CopyError(reason) {
  case error {
    StartRefused(RefusedWithFailure(failure)) -> CopyFailed(failure)
    StartRefused(RefusedNotConnected(error)) -> CopyNotConnected(error)
    StartUnencodable(error) -> CopyUnencodable(error)
    StartEnded(fault) -> copy_fault_error(fault)
  }
}

fn copy_fault_error(fault: CopyFault) -> CopyError(reason) {
  case fault {
    CopyFaultFailed(failure) -> CopyFailed(failure)
    CopyFaultRefused(report, status) -> CopyRefused(report, status)
    CopyFaultNotStarted(completed) -> CopyNotStarted(completed)
  }
}

/// Tells the connection process of the COPY of `sender`. A notice needs
/// no answer.
fn notify(sender: CopySender, notice: CopyNotice) -> Nil {
  process.send(sender.connection.subject, CopyNotice(sender.id, notice))
}

/// Waits for the next push of the COPY of `sender`. The wait ends with a
/// push, with the end of the connection process, or after the wait of the
/// sender.
fn next_push(sender: CopySender) -> Result(CopyPush, CopyError(reason)) {
  receive_push(sender.pushes, sender.wait_milliseconds)
  |> map_error(call_failure)
  |> map_error(CopyFailed)
}

/// The caller stops: the connection process ends the COPY, if it still
/// runs, and drops its end.
fn leave_copy(
  sender: CopySender,
  error: CopyError(reason),
) -> CopyError(reason) {
  notify(sender, CallerLeft)
  error
}

/// Folds each row that the process pushes, up to the end of the COPY.
fn read_rows(
  sender: CopySender,
  accumulator: value,
  fold: fn(value, BitArray) -> Result(value, reason),
) -> Result(value, CopyError(reason)) {
  case next_push(sender) {
    Ok(PushedRow(row:)) -> fold_row(sender, fold(accumulator, row), fold)
    Ok(PushedEnd(result:)) ->
      take_end(sender, result) |> result.replace(accumulator)
    Error(error) -> Error(leave_copy(sender, error))
  }
}

/// A fold that took its row tells the process, which reads the next row
/// only then. A fold that failed ends the COPY.
fn fold_row(
  sender: CopySender,
  folded: Result(value, reason),
  fold: fn(value, BitArray) -> Result(value, reason),
) -> Result(value, CopyError(reason)) {
  case folded {
    Ok(accumulator) -> {
      notify(sender, RowTaken)
      read_rows(sender, accumulator, fold)
    }
    Error(reason) -> end_copy(sender, AbandonCopy) |> abandoned(reason)
  }
}

/// The caller of a `COPY ... TO STDOUT` has the end: it finishes its side,
/// so the connection serves the next request.
fn take_end(
  sender: CopySender,
  ended: Result(Int, CopyFault),
) -> Result(Int, CopyError(reason)) {
  notify(sender, Finish(CompleteCopy))
  map_error(ended, copy_fault_error)
}

/// The app's function failed, and the driver ended the COPY. A server
/// refusal is the server's answer to the CopyFail, or the error that made
/// the function fail; any other error is a failure of the connection.
fn abandoned(
  ended: Result(Int, CopyError(reason)),
  reason: reason,
) -> Result(value, CopyError(reason)) {
  case ended {
    Ok(_count) | Error(CopyRefused(..)) -> Error(AppFailed(reason))
    Error(AppFailed(..) as error)
    | Error(CopyFailed(..) as error)
    | Error(CopyNotConnected(..) as error)
    | Error(CopyUnencodable(..) as error)
    | Error(CopyNotStarted(..) as error) -> Error(error)
  }
}

/// Ends the caller's side of the COPY, and waits for the end that the
/// process pushes. The wait ends with the end, with the end of the
/// connection process, or after the wait of the sender.
fn end_copy(
  sender: CopySender,
  ending: CopyEnding,
) -> Result(Int, CopyError(reason)) {
  notify(sender, Finish(ending))
  case receive_end(sender.pushes, sender.wait_milliseconds) {
    Ok(ended) -> map_error(ended, copy_fault_error)
    Error(failure) ->
      Error(leave_copy(sender, CopyFailed(call_failure(failure))))
  }
}

fn prepare_request(
  sql: String,
  reply_to: ReplyTo(Result(StatementDescription, PrepareError)),
) -> Request {
  StatementRequest(PrepareStatement(sql, reply_to))
}

fn run_request(
  sql: String,
  parameters: List(Cell),
  result_formats: List(Format),
  reply_to: ReplyTo(Result(Outcome, RunError)),
) -> Request {
  StatementRequest(
    RunStatement(RunDetails(sql, parameters, result_formats, reply_to, None)),
  )
}

/// Reads the state of the process. Only the process can fail it: it is
/// gone, or it did not answer in time. The process answers at once, unless
/// it connects again, which takes up to the setup timeout: the caller waits
/// the reply margin, which is longer.
fn snapshot(connection: Connection) -> Result(Snapshot, ConnectionStateError) {
  call_process(
    connection.pid,
    send_request(connection, SnapshotRequest, _),
    connection.reply_margin_milliseconds,
  )
  |> map_error(state_error)
}

fn state_error(failure: CallFailure) -> ConnectionStateError {
  case failure {
    CallProcessDown -> ProcessGone
    CallDeadlinePassed -> NoAnswerInTime
  }
}

/// Sends a request and waits for its answer. A call that fails gives its
/// failure to `failed`, which makes the request's own error of it.
fn request(
  connection: Connection,
  make: fn(ReplyTo(Result(value, error))) -> Request,
  deadline_milliseconds: Int,
  failed: fn(RequestFailure) -> error,
) -> Result(value, error) {
  let wait = deadline_milliseconds + connection.reply_margin_milliseconds
  call(connection, request_message(make, deadline_milliseconds, _), wait)
  |> map_error(failed)
  |> result.flatten
}

fn request_message(
  make: fn(ReplyTo(reply)) -> Request,
  deadline_milliseconds: Int,
  reply_to: ReplyTo(reply),
) -> Message {
  Request(make(reply_to), deadline_milliseconds)
}

fn call(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  timeout: Int,
) -> Result(reply, RequestFailure) {
  call_process(connection.pid, send_request(connection, make, _), timeout)
  |> map_error(call_failure)
}

fn send_request(
  connection: Connection,
  make: fn(ReplyTo(reply)) -> Message,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(connection.subject, make(reply_to))
}

fn call_failure(failure: CallFailure) -> RequestFailure {
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
    Request(request:, deadline_milliseconds:) ->
      actor.continue(new_request(state, request, deadline_milliseconds))
    DeadlineReached(id:) -> actor.continue(deadline_reached(state, id))
    CancelFinished(id:, result: cancel_result) ->
      actor.continue(cancel_finished(state, id, cancel_result))
    CancelOver(id:) -> actor.continue(cancel_over(state, id))
    SnapshotRequest(reply_to) -> {
      reply(reply_to, snapshot_of(state))
      actor.continue(state)
    }
    StopRequest(reply_to) -> stop_process(state, Some(reply_to))
    ExitSignal(_exit) -> stop_process(state, None)
    SocketMessage(socket_message) ->
      actor.continue(socket_message_received(state, socket_message))
    ReconnectNow(attempt:) -> actor.continue(reconnect(state, attempt))
    SendChunk(id:, chunk:, reply: reply_to) ->
      actor.continue(chunk_received(state, id, chunk, reply_to))
    CopyNotice(id:, notice:) -> actor.continue(copy_notice(state, id, notice))
    CallerDown(down:) -> actor.continue(caller_down(state, down))
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

/// Gives the request its number and starts its deadline timer.
fn new_request(state: State, request: Request, deadline: Int) -> State {
  let id = state.next_id
  let timer = process.send_after(state.subject, deadline, DeadlineReached(id))
  accept_request(State(..state, next_id: id + 1), Ticket(id:, request:, timer:))
}

/// A request runs at once when no request is in progress and no ended
/// COPY waits for its caller. A request is in progress from its start
/// until `next_request` ends it: while a step runs, and also after its
/// step ended while the cancel of its deadline is not done yet, so that
/// cancel can never reach the next request.
///
/// Why the close of the cancel socket is enough (PostgreSQL 16 source):
/// the child that takes a CancelRequest sends SIGINT two times, to the
/// backend and to its process group (postmaster.c signal_child,
/// kill(pid) then kill(-pid)), and exits only after that, which closes
/// the socket (postmaster.c processCancelRequest, ProcessStartupPacket).
/// So when the driver sees the close, both signals are pending on the
/// backend. A pending signal is handled before the backend runs more of
/// its own code, so before it can read the next request. Handled during
/// the statement, it ends that statement with 57014; handled in error
/// recovery, the recovery clears it (postgres.c PostgresMain, the
/// sigsetjmp block); handled while the backend waits for a command, it is
/// dropped, because ProcessInterrupts ignores a cancel while
/// DoingCommandRead and PostgresMain checks for interrupts before it sets
/// DoingCommandRead to false (postgres.c ProcessInterrupts and step 5 of
/// the main loop). The next request therefore never meets an old cancel.
fn accept_request(state: State, ticket: Ticket) -> State {
  case state.current, state.copy, state.link {
    None, None, Open(socket:, ..) -> {
      let current = Current(ticket.id, ticket.timer, False, False, False)
      begin(State(..state, current: Some(current)), socket, ticket.request)
    }
    Some(_in_progress), _, _ | _, Some(_copy), _ ->
      State(..state, waiting: [ticket, ..state.waiting])
    None, None, Lost(refusal:) -> {
      refuse_ticket(ticket, refusal)
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
        script_unencodable(reply_to, _),
      )
    HousekeepingRunRequest(sql:, reply: reply_to) ->
      start_housekeeping_step(
        state,
        socket,
        query.start_housekeeping_run(sql),
        RunningHousekeepingRun(_, reply_to),
      )
    HousekeepingScriptRequest(sql:, reply: reply_to) ->
      start_housekeeping_step(
        state,
        socket,
        query.start_housekeeping_script(sql),
        RunningHousekeepingScript(_, reply_to),
      )
    StatementRequest(statement) -> begin_statement(state, socket, statement)
    SettledStatusRequest(reply: reply_to) -> {
      reply(reply_to, Ok(tracked_status(state.tracker)))
      next_request(state)
    }
    CopyRequest(id:, direction:, sql:, caller:, pushes:, reply: reply_to) -> {
      let session =
        CopySession(
          id:,
          monitor: process.monitor(caller),
          start: Some(reply_to),
          pushes:,
          waiting_chunks: [],
          finished: False,
          row_pushed: False,
        )
      begin_copy(state, socket, query.start_copy(sql, direction), session)
    }
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
        statement_unencodable(statement, _),
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
        statement_unencodable(statement, _),
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
    statement_unencodable(RunStatement(details), _),
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
    statement_unencodable(statement, _),
  )
}

/// Sends the first messages of a step. A message that cannot be written
/// fails the request before any byte goes out.
fn start_step(
  state: State,
  socket: transport.Connection,
  start: Start(step_state),
  running: fn(step_state) -> Running,
  fail: fn(EncodeError) -> Nil,
) -> State {
  case encode_all(start.messages) {
    Ok(bytes) ->
      State(..state, running: Some(running(start.state)))
      |> sent(socket, transport.send(socket, bytes))
    Error(error) -> {
      fail(error)
      next_request(state)
    }
  }
}

/// Sends the first messages of a step of a housekeeping statement, whose
/// bytes cannot fail to encode.
fn start_housekeeping_step(
  state: State,
  socket: transport.Connection,
  start: HousekeepingStart(step_state),
  running: fn(step_state) -> Running,
) -> State {
  State(..state, running: Some(running(start.state)))
  |> sent(socket, transport.send(socket, start.bytes))
}

fn script_unencodable(
  reply_to: ReplyTo(Result(List(Outcome), ScriptError)),
  error: EncodeError,
) -> Nil {
  reply(reply_to, Error(ScriptUnencodable(error)))
}

fn statement_unencodable(
  statement: StatementRequest,
  error: EncodeError,
) -> Nil {
  case statement {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareUnencodable(error)))
    RunStatement(details) -> reply(details.reply, Error(RunUnencodable(error)))
  }
}

/// Refuses a request that the process does not run, with the request's
/// own error.
fn refuse(request: Request, refusal: Refusal) -> Nil {
  case request {
    StatementRequest(statement) -> refuse_statement(statement, refusal)
    SettledStatusRequest(reply: reply_to) ->
      reply(reply_to, Error(settle_refusal(refusal)))
    ScriptRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(script_refusal(refusal)))
    HousekeepingRunRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(housekeeping_refusal(refusal)))
    HousekeepingScriptRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(housekeeping_refusal(refusal)))
    CopyRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(StartRefused(refusal)))
  }
}

fn refuse_statement(statement: StatementRequest, refusal: Refusal) -> Nil {
  case statement {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(prepare_refusal(refusal)))
    RunStatement(details) -> reply(details.reply, Error(run_refusal(refusal)))
  }
}

fn settle_refusal(refusal: Refusal) -> SettleError {
  case refusal {
    RefusedWithFailure(failure) -> SettleFailed(failure)
    RefusedNotConnected(error) -> SettleNotConnected(error)
  }
}

fn script_refusal(refusal: Refusal) -> ScriptError {
  case refusal {
    RefusedWithFailure(failure) -> ScriptRequestFailed(failure)
    RefusedNotConnected(error) -> ScriptNotConnected(error)
  }
}

fn housekeeping_refusal(refusal: Refusal) -> HousekeepingError {
  case refusal {
    RefusedWithFailure(failure) -> HousekeepingFailed(failure)
    RefusedNotConnected(error) -> HousekeepingNotConnected(error)
  }
}

fn prepare_refusal(refusal: Refusal) -> PrepareError {
  case refusal {
    RefusedWithFailure(failure) -> PrepareFailed(failure)
    RefusedNotConnected(error) -> PrepareNotConnected(error)
  }
}

fn run_refusal(refusal: Refusal) -> RunError {
  case refusal {
    RefusedWithFailure(failure) -> RunFailed(failure)
    RefusedNotConnected(error) -> RunNotConnected(error)
  }
}

/// Fails the request that runs: the connection broke, or its deadline
/// passed.
fn refuse_running(running: Running, failure: RequestFailure) -> Nil {
  case running {
    RunningPrepare(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareFailed(failure)))
    RunningRun(reply: reply_to, ..) ->
      reply(reply_to, Error(RunFailed(failure)))
    RunningScript(reply: reply_to, ..) ->
      reply(reply_to, Error(ScriptRequestFailed(failure)))
    RunningHousekeepingRun(reply: reply_to, ..) ->
      reply(reply_to, Error(HousekeepingFailed(failure)))
    RunningHousekeepingScript(reply: reply_to, ..) ->
      reply(reply_to, Error(HousekeepingFailed(failure)))
    RunningNamedPrepare(request:, ..) ->
      refuse_statement(request, RefusedWithFailure(failure))
    RunningCachedRun(details:, ..) ->
      reply(details.reply, Error(RunFailed(failure)))
    RunningCopy(session:, ..) ->
      answer_session(session, Error(CopyFaultFailed(failure)))
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
  sent: Result(Nil, SendError),
) -> State {
  lose_on_error(state, socket, sent |> map_error(send_loss))
}

/// A socket call that failed loses the connection.
fn lose_on_error(
  state: State,
  socket: transport.Connection,
  called: Result(Nil, LossReason),
) -> State {
  case called {
    Ok(Nil) -> state
    Error(reason) -> write_failed(state, socket, reason)
  }
}

fn send_loss(error: SendError) -> LossReason {
  case error {
    SendTimedOut -> ServerStoppedReading
    SendFailed(error) -> SocketFailed(error)
  }
}

/// A write failed. The server may have sent its last messages before the
/// failure, for example the FATAL error of a session that it ends, and
/// then closed: the process reads them first, so that error wins. If
/// they do not end the connection, the failure of the write does.
fn write_failed(
  state: State,
  socket: transport.Connection,
  reason: LossReason,
) -> State {
  read_messages_with(state, transport.received_bytes(socket))
  |> lose_if_connected(socket, ConnectionLost(reason))
}

fn lose_if_connected(
  state: State,
  socket: transport.Connection,
  end: ConnectionEnd,
) -> State {
  case state.link {
    Open(..) -> lose(state, socket, end)
    Lost(..) -> state
  }
}

/// When no step runs, and no cancel of it is under way, the current
/// request is done: its timer stops, and the oldest waiting request
/// starts, if one waits.
fn next_request(state: State) -> State {
  use <- guard(option.is_some(state.copy), state)
  case state.running, state.current {
    Some(_running), _ -> state
    None, Some(Current(deadline_passed: True, cancel_done: False, ..)) -> state
    None, _ -> start_waiting(end_current(state))
  }
}

fn end_current(state: State) -> State {
  option.map(state.current, stop_timer)
  State(..state, current: None)
}

fn stop_timer(current: Current) -> Nil {
  process.cancel_timer(current.timer)
  Nil
}

fn start_waiting(state: State) -> State {
  case reverse(state.waiting) {
    [oldest, ..others] ->
      accept_request(State(..state, waiting: reverse(others)), oldest)
    [] -> state
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
    SocketEnded ->
      lose(state, socket, ConnectionLost(SocketFailed(SocketClosed)))
    transport.SocketFailed(error) ->
      lose(state, socket, ConnectionLost(SocketFailed(error)))
    NotThisSocket -> state
  }
}

fn receive_next(state: State) -> State {
  use <- guard(paused(state), state)
  case state.link {
    Open(socket:, ..) ->
      transport.receive_next(socket)
      |> map_error(SocketFailed)
      |> lose_on_error(state, socket, _)
    Lost(..) -> state
  }
}

/// Decodes and handles each whole message of the buffer.
fn read_messages(state: State) -> State {
  read_messages_with(state, <<>>)
}

/// Decodes and handles each whole message of the buffer, followed by
/// `received`.
fn read_messages_with(state: State, received: BitArray) -> State {
  use <- guard(paused(state), state)
  case state.link {
    Open(socket:, bytes:) ->
      read_message(state, socket, <<bytes:bits, received:bits>>)
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
    Ok(NeedMoreBytes) -> State(..state, link: Open(socket, bytes))
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
      advance(
        State(..confirm_cancel(state, message), running: None),
        socket,
        running,
        message,
      )
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
      keep_asynchronous(state, query.Notification(process_id, channel, payload))
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
    RunningHousekeepingRun(state: step_state, reply: reply_to) ->
      follow(
        state,
        socket,
        query.step_prepare_and_run(step_state, message),
        RunningHousekeepingRun(_, reply_to),
        housekeeping_run_finisher(reply_to),
        running,
      )
    RunningHousekeepingScript(state: step_state, reply: reply_to) ->
      follow(
        state,
        socket,
        query.step_simple_query(step_state, message),
        RunningHousekeepingScript(_, reply_to),
        housekeeping_script_finisher(reply_to),
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
    RunningCopy(state: step_state, session:) ->
      follow_copy(
        state,
        socket,
        query.step_copy(step_state, message),
        session,
        running,
      )
  }
}

fn prepare_finisher(
  reply_to: ReplyTo(Result(StatementDescription, PrepareError)),
) -> Finisher(query.Outcome(StatementDescription, ServerReport)) {
  fn(state, _socket, outcome) { finish_prepare(state, outcome, reply_to) }
}

fn run_finisher(
  reply_to: ReplyTo(Result(Outcome, RunError)),
) -> Finisher(query.Outcome(StatementResult, Failure)) {
  fn(state, _socket, outcome) {
    finish_run(state, outcome, reply_to, run_failure)
  }
}

fn housekeeping_run_finisher(
  reply_to: ReplyTo(Result(Outcome, HousekeepingError)),
) -> Finisher(query.Outcome(StatementResult, Failure)) {
  fn(state, _socket, outcome) {
    finish_run(state, outcome, reply_to, housekeeping_run_failure)
  }
}

fn script_finisher(
  reply_to: ReplyTo(Result(List(Outcome), ScriptError)),
) -> Finisher(query.Outcome(List(StatementResult), ScriptFailure)) {
  fn(state, _socket, outcome) {
    finish_script(state, outcome, reply_to, script_failure)
  }
}

fn housekeeping_script_finisher(
  reply_to: ReplyTo(Result(List(Outcome), HousekeepingError)),
) -> Finisher(query.Outcome(List(StatementResult), ScriptFailure)) {
  fn(state, _socket, outcome) {
    finish_script(state, outcome, reply_to, housekeeping_script_failure)
  }
}

fn named_prepare_finisher(
  request: StatementRequest,
  name: String,
) -> Finisher(query.Outcome(StatementDescription, ServerReport)) {
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
    Ok(Finished(outcome)) ->
      answer_deadline(state, current)
      |> finish(socket, outcome)
      |> next_request
    Ok(query.ConnectionEnded(report, messages)) ->
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
  let state = fold(messages, state, keep_asynchronous)
  failed(state, socket, current, ServerEndedConnection(report))
}

/// The request failed in a way that leaves the connection in an unknown
/// state: the caller gets the end, and the process connects again.
fn failed(
  state: State,
  socket: transport.Connection,
  current: Running,
  end: ConnectionEnd,
) -> State {
  lose(State(..state, running: Some(current)), socket, end)
}

fn finish_prepare(
  state: State,
  outcome: query.Outcome(StatementDescription, ServerReport),
  reply_to: ReplyTo(Result(StatementDescription, PrepareError)),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_prepare(state.tracker, outcome)
  let result = outcome.result |> map_error(PrepareRefused(_, outcome.status))
  reply(reply_to, result)
  State(..state, tracker:)
}

/// A prepare fails only with the server's error.
fn track_prepare(
  tracker: TransactionTracker,
  outcome: query.Outcome(StatementDescription, ServerReport),
) -> TransactionTracker {
  track(
    tracker,
    outcome.status,
    option.from_result(result_error(outcome.result)),
  )
}

fn result_error(result: Result(value, error)) -> Result(error, Nil) {
  case result {
    Ok(_value) -> Error(Nil)
    Error(error) -> Ok(error)
  }
}

fn finish_run(
  state: State,
  outcome: query.Outcome(StatementResult, Failure),
  reply_to: ReplyTo(Result(Outcome, error)),
  failing: fn(Failure, TransactionStatus) -> error,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let #(state, result) = case outcome.result {
    Ok(statement) -> {
      let #(state, single) =
        take_pending(state, plain_outcome(statement, outcome.status))
      #(state, Ok(single))
    }
    Error(failure) -> #(state, Error(failing(failure, outcome.status)))
  }
  reply(reply_to, result)
  State(..state, tracker:)
}

fn finish_script(
  state: State,
  outcome: query.Outcome(List(StatementResult), ScriptFailure),
  reply_to: ReplyTo(Result(List(Outcome), error)),
  failing: fn(Failure, TransactionStatus, List(Outcome)) -> error,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_script(state.tracker, outcome)
  let #(state, result) = script_result(state, outcome, failing)
  reply(reply_to, result)
  State(..state, tracker:)
}

fn script_result(
  state: State,
  outcome: query.Outcome(List(StatementResult), ScriptFailure),
  failing: fn(Failure, TransactionStatus, List(Outcome)) -> error,
) -> #(State, Result(List(Outcome), error)) {
  case outcome.result {
    Ok(statements) -> {
      let #(state, outcomes) = outcomes_of(state, statements, outcome.status)
      #(state, Ok(outcomes))
    }
    Error(ScriptFailure(completed:, failure:)) -> {
      let #(state, outcomes) = outcomes_of(state, completed, outcome.status)
      #(state, Error(failing(failure, outcome.status, outcomes)))
    }
  }
}

fn finish_named_prepare(
  state: State,
  socket: transport.Connection,
  outcome: query.Outcome(StatementDescription, ServerReport),
  request: StatementRequest,
  name: String,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let state = State(..state, tracker: track_prepare(state.tracker, outcome))
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
    Error(report) -> {
      prepare_refused(request, report, outcome.status)
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
  use <- guard(deadline_passed(state), state)
  case details.previous {
    Some(previous) if previous != cached.description -> {
      reply(details.reply, Error(RunStatementChanged(cached.description)))
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
    Error(CopyNotSupported(..) as failure) -> {
      reply(details.reply, Error(run_failure(failure, outcome.status)))
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
      reply(details.reply, Error(RunRefused(report, status)))
      state
    }
  }
}

/// The server refused the prepare of a statement: a `prepare` or the first
/// run of a statement.
fn prepare_refused(
  request: StatementRequest,
  report: ServerReport,
  status: TransactionStatus,
) -> Nil {
  case request {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareRefused(report, status)))
    RunStatement(details) ->
      reply(details.reply, Error(RunRefused(report, status)))
  }
}

fn run_failure(failure: Failure, status: TransactionStatus) -> RunError {
  case failure {
    ServerError(report) -> RunRefused(report, status)
    CopyNotSupported(_report) -> RunCopyRefused
  }
}

/// A housekeeping statement is not a COPY, so a COPY answer breaks the
/// protocol.
fn housekeeping_run_failure(
  failure: Failure,
  status: TransactionStatus,
) -> HousekeepingError {
  case failure {
    ServerError(report) -> HousekeepingRefused(report, status)
    CopyNotSupported(_report) -> HousekeepingAnswerUnexpected
  }
}

/// A housekeeping statement is one statement that is not a COPY, so an
/// error after a result and a COPY answer break the protocol.
fn housekeeping_script_failure(
  failure: Failure,
  status: TransactionStatus,
  completed: List(Outcome),
) -> HousekeepingError {
  case failure, completed {
    ServerError(report), [] -> HousekeepingRefused(report, status)
    ServerError(_report), [_ran, ..] | CopyNotSupported(_report), _ran ->
      HousekeepingAnswerUnexpected
  }
}

/// The first statement of a script that fails is refused; a later one
/// fails the script after the ones that ran.
fn script_failure(
  failure: Failure,
  status: TransactionStatus,
  completed: List(Outcome),
) -> ScriptError {
  case failure, completed {
    ServerError(report), [] -> ScriptRefused(report, status)
    ServerError(report), _ran -> ScriptFailed(completed, report, status)
    CopyNotSupported(_report), _ran -> ScriptCopyRefused(completed)
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
    _notice_or_notification -> keep_asynchronous(state, message)
  }
}

/// Keeps a notice for the next outcome. A notification goes at once to the
/// notifications subscriber when there is one, in the order the server
/// sent it, and is kept for the next outcome otherwise.
fn keep_asynchronous(state: State, message: AsynchronousMessage) -> State {
  case message, state.config.notifications {
    query.Notification(process_id:, channel:, payload:), Some(subscriber) -> {
      process.send(subscriber, Notification(process_id:, channel:, payload:))
      state
    }
    _other, _subscriber -> State(..state, pending: [message, ..state.pending])
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

// The COPY in the process -----------------------------------------------------

/// Sends the first messages of a COPY. A message that cannot be written
/// fails the request before any byte goes out.
fn begin_copy(
  state: State,
  socket: transport.Connection,
  start: Start(CopyState),
  session: CopySession,
) -> State {
  case encode_all(start.messages) {
    Ok(bytes) ->
      running_copy(state, start.state, session)
      |> sent(socket, transport.send(socket, bytes))
    Error(error) -> {
      option.map(session.start, reply(_, Error(StartUnencodable(error))))
      process.demonitor_process(session.monitor)
      next_request(state)
    }
  }
}

fn running_copy(
  state: State,
  copy_state: CopyState,
  session: CopySession,
) -> State {
  State(..state, running: Some(RunningCopy(copy_state, session)))
}

/// Goes on with a COPY: tells its caller of the start and of each row,
/// sends what the step asks, waits, or ends it.
fn follow_copy(
  state: State,
  socket: transport.Connection,
  step: Result(CopyStep, UnexpectedMessage),
  session: CopySession,
  current: Running,
) -> State {
  case step {
    Ok(CopyWait(copy_state)) -> running_copy(state, copy_state, session)
    Ok(CopySend(bytes, copy_state)) ->
      running_copy(state, copy_state, session)
      |> sent(socket, transport.send(socket, bytes))
    Ok(CopyStarted(copy_state)) -> {
      option.map(session.start, reply(_, Ok(Nil)))
      running_copy(state, copy_state, CopySession(..session, start: None))
    }
    Ok(CopyRow(row, copy_state)) -> copy_row(state, copy_state, session, row)
    Ok(CopyFinished(outcome)) -> copy_finished(state, session, outcome)
    Ok(CopyConnectionEnded(report, messages)) ->
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

/// A row goes to the caller. The process reads nothing more from the
/// socket until the caller took it.
fn copy_row(
  state: State,
  copy_state: CopyState,
  session: CopySession,
  row: BitArray,
) -> State {
  reply(session.pushes, PushedRow(row))
  running_copy(state, copy_state, CopySession(..session, row_pushed: True))
}

/// The server ended the COPY. Its caller gets the result now: with its
/// start, or as a push. After a deadline the result is `DeadlinePassed`.
fn copy_finished(
  state: State,
  session: CopySession,
  outcome: query.Outcome(CopyResult, Failure),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let #(state, ended) = copy_result(state, outcome)
  let ended = deadline_result(state, ended)
  State(..state, tracker:, copy: settle_copy(session, ended))
  |> next_request
}

/// The row count of the COPY, or why there is none. A statement that ran
/// in place of the COPY gives its outcome, with the pending notices and
/// notifications.
fn copy_result(
  state: State,
  outcome: query.Outcome(CopyResult, Failure),
) -> #(State, Result(Int, CopyFault)) {
  case outcome.result {
    Ok(CopyCompleted(count:)) -> #(state, Ok(count))
    Ok(NoCopyStarted(result:)) -> {
      let #(state, completed) =
        take_pending(state, Outcome([], result, [], [], outcome.status))
      #(state, Error(CopyFaultNotStarted(Some(completed))))
    }
    Error(CopyNotSupported(..)) -> #(state, Error(CopyFaultNotStarted(None)))
    Error(ServerError(report)) -> #(
      state,
      Error(CopyFaultRefused(report, outcome.status)),
    )
  }
}

fn deadline_result(
  state: State,
  ended: Result(Int, CopyFault),
) -> Result(Int, CopyFault) {
  case state.current {
    Some(Current(deadline_passed: True, cancel_confirmed:, ..)) ->
      Error(CopyFaultFailed(DeadlinePassed(cancelled: cancel_confirmed)))
    _ -> ended
  }
}

/// Gives the end of the COPY to its caller, and keeps the end while the
/// caller did not finish its side yet.
fn settle_copy(
  session: CopySession,
  ended: Result(Int, CopyFault),
) -> Option(EndedCopy) {
  answer_session(session, ended)
  close_session(session, ended)
}

/// Gives the end of the COPY to each chunk that waits for it, and to the
/// caller: to its start, when it still waits for the start, else as a
/// push.
fn answer_session(session: CopySession, ended: Result(Int, CopyFault)) -> Nil {
  list.each(session.waiting_chunks, reply(_, chunk_answer(ended)))
  case session.start {
    Some(start) ->
      reply(start, result.replace(ended, Nil) |> map_error(StartEnded))
    None -> reply(session.pushes, PushedEnd(ended))
  }
}

/// A caller that got the end with its start, or that finished its side
/// already, needs the COPY no more, and the process watches it no more.
/// Else the end waits until the caller finishes its side.
fn close_session(
  session: CopySession,
  ended: Result(Int, CopyFault),
) -> Option(EndedCopy) {
  case session.start, session.finished {
    None, False -> Some(EndedCopy(session.id, session.monitor, ended))
    Some(_start), _ | None, True -> {
      process.demonitor_process(session.monitor)
      None
    }
  }
}

/// A chunk that met the end of its COPY: the failure or the refusal that
/// ended it. A COPY that ended with no failure takes no more data.
fn chunk_answer(ended: Result(Int, CopyFault)) -> Result(Nil, ChunkError) {
  case ended {
    Error(CopyFaultFailed(failure)) -> Error(ChunkFailed(failure))
    Error(CopyFaultRefused(report, status)) ->
      Error(ChunkRefused(report, status))
    Ok(_count) | Error(CopyFaultNotStarted(..)) -> Error(ChunkCopyNotRunning)
  }
}

/// A chunk for a COPY that does not run, and that did not end with a
/// failure that the process keeps: it gets `ChunkCopyNotRunning`.
fn refuse_chunk(reply_to: ReplyTo(Result(Nil, ChunkError))) -> Nil {
  reply(reply_to, Error(ChunkCopyNotRunning))
}

/// A chunk of the caller of a COPY: of the COPY that runs, of the one
/// whose caller did not finish its side yet, or of one that is over. Each
/// chunk gets an answer.
fn chunk_received(
  state: State,
  id: Reference,
  chunk: BitArray,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.id == id
    -> send_copy_chunk(state, socket, copy_state, session, chunk, reply_to)
    _, Some(ended), _ if ended.id == id -> {
      reply(reply_to, chunk_answer(ended.result))
      state
    }
    _, _, _ -> {
      refuse_chunk(reply_to)
      state
    }
  }
}

/// A notice of the caller of the COPY `id`.
fn copy_notice(state: State, id: Reference, notice: CopyNotice) -> State {
  case notice {
    RowTaken -> take_row(state, id)
    Finish(ending: CompleteCopy) -> finish_side(state, id, query.finish_copy)
    Finish(ending: AbandonCopy) | CallerLeft ->
      finish_side(state, id, query.abandon_copy)
  }
}

/// The caller took the row that the process pushed: the process reads on.
/// A row taken after the process stopped the COPY, or after its end,
/// changes nothing.
fn take_row(state: State, id: Reference) -> State {
  case state.running {
    Some(RunningCopy(state: copy_state, session:))
      if session.id == id && session.row_pushed
    ->
      running_copy(state, copy_state, CopySession(..session, row_pushed: False))
      |> read_on
    _ -> state
  }
}

/// The caller ends its side of the COPY `id`. A COPY that runs ends with
/// the bytes that `ending` gives, and its end goes to the caller when the
/// server ended it. The end of a COPY that ended already is dropped, and
/// the process serves the next request. A COPY that is over changes
/// nothing.
fn finish_side(
  state: State,
  id: Reference,
  ending: fn(CopyState) -> #(CopyState, BitArray),
) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.id == id
    ->
      CopySession(..session, finished: True)
      |> stop_copy(state, socket, ending(copy_state), _)
    _, Some(ended), _ if ended.id == id -> drop_ended_copy(state, ended)
    _, _, _ -> state
  }
}

/// The caller of an ended COPY needs it no more: the process watches the
/// caller no more, and serves the next request.
fn drop_ended_copy(state: State, ended: EndedCopy) -> State {
  process.demonitor_process(ended.monitor)
  next_request(State(..state, copy: None))
}

/// Sends a chunk while the server reads data and the deadline did not
/// pass, and answers when it went to the socket. Else the chunk waits for
/// the end of the COPY, which is its answer.
fn send_copy_chunk(
  state: State,
  socket: transport.Connection,
  copy_state: CopyState,
  session: CopySession,
  chunk: BitArray,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
) -> State {
  let waiting =
    running_copy(
      state,
      copy_state,
      CopySession(..session, waiting_chunks: [
        reply_to,
        ..session.waiting_chunks
      ]),
    )
  case query.accepts_copy_data(copy_state) && !deadline_passed(state) {
    True ->
      transport.send(socket, query.copy_data(chunk))
      |> chunk_sent(state, waiting, socket, reply_to, _)
    False -> waiting
  }
}

/// Answers a chunk that went to the socket. A send that failed loses the
/// connection, and the waiting chunk gets the loss.
fn chunk_sent(
  state: State,
  waiting: State,
  socket: transport.Connection,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
  sent: Result(Nil, SendError),
) -> State {
  case sent {
    Ok(Nil) -> {
      reply(reply_to, Ok(Nil))
      state
    }
    Error(error) -> write_failed(waiting, socket, send_loss(error))
  }
}

/// Sends the bytes that end the COPY, stops waiting for the caller to take
/// a row, and reads on to the end of the COPY. The step drops the rows
/// after it.
fn stop_copy(
  state: State,
  socket: transport.Connection,
  stopped: #(CopyState, BitArray),
  session: CopySession,
) -> State {
  let #(copy_state, bytes) = stopped
  running_copy(state, copy_state, CopySession(..session, row_pushed: False))
  |> sent(socket, transport.send(socket, bytes))
  |> read_on
}

/// Reads the messages that came while the process waited for the caller
/// to take a row, and asks the socket for more.
fn read_on(state: State) -> State {
  state |> read_messages |> receive_next
}

/// The process pushed a row that the caller did not take yet, so it reads
/// nothing more from the socket.
fn paused(state: State) -> Bool {
  case state.running {
    Some(RunningCopy(session: CopySession(row_pushed: True, ..), ..)) -> True
    _ -> False
  }
}

/// Ends the COPY that runs, if one runs, with the bytes that `ending`
/// gives.
fn end_running_copy(
  state: State,
  ending: fn(CopyState) -> #(CopyState, BitArray),
) -> State {
  case state.running, state.link {
    Some(RunningCopy(state: copy_state, session:)), Open(socket:, ..) ->
      stop_copy(state, socket, ending(copy_state), session)
    _, _ -> state
  }
}

/// The caller of a COPY ended: the COPY is abandoned, or its end is
/// dropped.
fn caller_down(state: State, down: Down) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.monitor == down.monitor
    ->
      CopySession(..session, finished: True)
      |> stop_copy(state, socket, query.abandon_copy(copy_state), _)
    _, Some(ended), _ if ended.monitor == down.monitor ->
      drop_ended_copy(state, ended)
    _, _, _ -> state
  }
}

/// A COPY that runs when the connection is lost ends with the loss. One
/// that ended before keeps its own result.
fn lost_copy(state: State, failure: RequestFailure) -> Option(EndedCopy) {
  case state.running {
    Some(RunningCopy(session:, ..)) ->
      close_session(session, Error(CopyFaultFailed(failure)))
    _ -> state.copy
  }
}

// Losing and connecting again -------------------------------------------------

/// The connection is lost: the socket closes, the running request and
/// every waiting one fail with the error, the subscriber hears of it, and
/// a reconnect follows after the first delay of the backoff.
fn lose(
  state: State,
  socket: transport.Connection,
  end: ConnectionEnd,
) -> State {
  end_link(state, socket, running_error: ConnectionEnded(end), end:)
}

/// Ends the link. The running request, and a COPY that runs, fail with
/// `running_error`. The waiting requests and the requests that come while
/// the link is lost get `ConnectionEnded(end)`, and the subscriber gets
/// `Disconnected(end)`.
fn end_link(
  state: State,
  socket: transport.Connection,
  running_error running_error: RequestFailure,
  end end: ConnectionEnd,
) -> State {
  let refusal = RefusedWithFailure(ConnectionEnded(end))
  transport.close(socket)
  option.map(state.running, refuse_running(_, running_error))
  list.each(reverse(state.waiting), refuse_ticket(_, refusal))
  tell(state, Disconnected(end))
  schedule_reconnect(state, 0)
  State(
    ..end_current(state),
    link: Lost(refusal),
    running: None,
    waiting: [],
    tracker: new_tracker(),
    copy: lost_copy(state, running_error),
  )
}

fn refuse_ticket(ticket: Ticket, refusal: Refusal) -> Nil {
  process.cancel_timer(ticket.timer)
  refuse(ticket.request, refusal)
}

fn tell(state: State, event: ConnectionEvent) -> Nil {
  option.map(state.config.events, process.send(_, event))
  Nil
}

fn schedule_reconnect(state: State, attempt: Int) -> Nil {
  let delay = backoff_delay(state.config.reconnect, attempt)
  process.send_after(state.subject, delay, ReconnectNow(attempt))
  Nil
}

/// The delay before a reconnect: the first delay, doubled for each failed
/// attempt, up to the longest.
///
/// ## Parameters
///
/// - `backoff`: the backoff settings
/// - `attempt`: the number of failed attempts so far, 0 for the first
///
/// ## Returns
///
/// The delay in milliseconds.
pub fn backoff_delay(backoff: Backoff, attempt: Int) -> Int {
  let doubled =
    int.bitwise_shift_left(backoff.first_delay_milliseconds, min(attempt, 30))
  min(doubled, backoff.longest_delay_milliseconds)
}

/// Each `ReconnectNow` comes from one loss or one failed attempt, while
/// the link is lost, so the process connects only when it has no socket.
fn reconnect(state: State, attempt: Int) -> State {
  case open_session(state.config) {
    Ok(session) -> {
      tell(state, Reconnected)
      connected_state(state, session)
    }
    Error(connect_error) -> {
      tell(state, ReconnectFailed(connect_error))
      schedule_reconnect(state, attempt + 1)
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
    ConnectTimedOut, True -> SetupTimedOut
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
      login.random_client_nonce(),
      transport.server_certificate(socket),
    )
    |> map_error(login_start_error),
  )
  use Nil <- try(send_login_message(socket, first))
  use session <- try(login_messages(socket, state, <<>>, setup_deadline))
  transport.receive_next(socket)
  |> map_error(LoginSocketFailed)
  |> result.replace(session)
}

fn login_start_error(error: LoginStartError) -> ConnectError {
  case error {
    ChannelBindingRequiresTls -> LoginRequiresTls
  }
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
    |> map_error(login_receive_error),
  )
  login_messages(socket, state, <<bytes:bits, more:bits>>, setup_deadline)
}

/// A login message cannot fail to encode: the login checks each value
/// that it holds (see `login.encode_login_message`).
fn send_login_message(
  socket: transport.Connection,
  message: LoginMessage,
) -> Result(Nil, ConnectError) {
  transport.send(socket, encode_login_message(message))
  |> map_error(LoginSendFailed)
}

/// The receive waits for the time left of the setup, so its timeout is
/// the end of the setup.
fn login_receive_error(error: ReceiveError) -> ConnectError {
  case error {
    ReceiveTimedOut -> SetupTimedOut
    ReceiveFailed(error) -> LoginSocketFailed(error)
  }
}

// Deadlines and cancel -------------------------------------------------------

fn deadline_passed(state: State) -> Bool {
  state.current |> option.map(current_deadline_passed) |> option.unwrap(False)
}

fn current_deadline_passed(current: Current) -> Bool {
  current.deadline_passed
}

/// After its deadline, a request's caller gets `DeadlinePassed` when its
/// step ends, before the step's own answer, which the caller's alias then
/// drops. A request that the deadline stopped goes no further.
fn answer_deadline(state: State, running: Running) -> State {
  case state.current {
    Some(Current(deadline_passed: True, cancel_confirmed:, ..)) -> {
      refuse_running(running, DeadlinePassed(cancelled: cancel_confirmed))
      state
    }
    _ -> state
  }
}

/// The server confirms a cancel with the error 57014.
fn confirm_cancel(state: State, message: BackendMessage) -> State {
  case message, state.current {
    ErrorResponse(report), Some(current) if current.deadline_passed ->
      State(
        ..state,
        current: Some(
          Current(..current, cancel_confirmed: report.code == "57014"),
        ),
      )
    _, _ -> state
  }
}

/// The deadline of a waiting request ends it at once. The deadline of the
/// running request sends a cancel on a new socket, with the TLS settings
/// of the connection. A session with no cancel key cannot cancel, so its
/// connection is closed and replaced.
///
/// A COPY that runs takes no more chunks. A `COPY ... FROM STDIN` gets
/// both the cancel and, once the cancel is done, a CopyFail, because each
/// covers a case that the other does not: the cancel stops a server that
/// is busy with rows it received already (triggers, indexes, constraint
/// checks), and the CopyFail ends a COPY whose server waits for data,
/// where it does not act on a cancel. The rest of a
/// `COPY ... TO STDOUT` is read and dropped at once, because the server
/// acts on a cancel only between rows, never while it waits to write a row
/// that the caller did not take. A COPY that the server ended already
/// waits for its caller, with its own result.
fn deadline_reached(state: State, id: Int) -> State {
  case state.current, state.running, state.link {
    Some(current), Some(_running), Open(socket:, ..) if current.id == id ->
      start_cancel(state, socket, current)
      |> end_running_copy(query.stop_at_deadline)
    _, _, _ -> end_waiting(state, id)
  }
}

fn start_cancel(
  state: State,
  socket: transport.Connection,
  current: Current,
) -> State {
  let state =
    State(..state, current: Some(Current(..current, deadline_passed: True)))
  case state.cancel_key {
    Some(key) -> {
      process.spawn_unlinked(fn() {
        cancel(state.config, key, state.subject, current.id)
      })
      let delay = state.config.cancel_timeout_milliseconds
      process.send_after(state.subject, delay, CancelOver(current.id))
      state
    }
    None -> lose_at_deadline(state, socket, current)
  }
}

fn end_waiting(state: State, id: Int) -> State {
  let #(ended, waiting) = list.partition(state.waiting, has_id(_, id))
  list.each(ended, refuse_ticket(
    _,
    RefusedWithFailure(DeadlinePassed(cancelled: False)),
  ))
  State(..state, waiting:)
}

fn has_id(ticket: Ticket, id: Int) -> Bool {
  ticket.id == id
}

/// A cancel that the server took lets the request end. A cancel that could
/// not reach the server leaves the statement running, so the connection
/// is closed and replaced.
fn cancel_finished(
  state: State,
  id: Int,
  cancel_result: Result(Nil, CancelFailure),
) -> State {
  case cancel_result {
    Ok(Nil) -> for_current(state, id, mark_cancel_done)
    Error(_unreached) -> for_current(state, id, lose_at_deadline)
  }
}

/// A cancel that did not end in time leaves the connection in an unknown
/// state, so it is closed and replaced.
fn cancel_over(state: State, id: Int) -> State {
  for_current(state, id, lose_at_deadline)
}

/// Acts on the request `id` while it is the current one of a connected
/// session. A message about a request that ended already changes nothing.
fn for_current(
  state: State,
  id: Int,
  action: fn(State, transport.Connection, Current) -> State,
) -> State {
  case state.current, state.link {
    Some(current), Open(socket:, ..) if current.id == id ->
      action(state, socket, current)
    _, _ -> state
  }
}

/// A `COPY ... FROM STDIN` that still runs gets its CopyFail only now.
/// The server ignores a cancel while it waits for CopyData, and it drops
/// a pending cancel when a statement fails. A CopyFail sent before the
/// server took the cancel could end the COPY first, and leave the cancel
/// to stop the next statement.
fn mark_cancel_done(
  state: State,
  _socket: transport.Connection,
  current: Current,
) -> State {
  State(..state, current: Some(Current(..current, cancel_done: True)))
  |> end_running_copy(query.abandon_copy)
  |> next_request
}

/// The request whose deadline passed fails with `DeadlinePassed`. The
/// others fail because the process closed the connection after it.
fn lose_at_deadline(
  state: State,
  socket: transport.Connection,
  _current: Current,
) -> State {
  end_link(
    state,
    socket,
    running_error: DeadlinePassed(cancelled: False),
    end: ConnectionLost(ClosedAfterDeadline),
  )
}

/// Opens a new connection with the same settings, sends the CancelRequest,
/// and waits until the server closes it, which it does after the cancel.
/// It runs in its own process, so the connection process goes on reading.
fn cancel(
  config: ConnectionConfig,
  key: CancelKey,
  owner: Subject(Message),
  id: Int,
) -> Nil {
  process.send(owner, CancelFinished(id, send_cancel(config, key)))
}

fn send_cancel(
  config: ConnectionConfig,
  key: CancelKey,
) -> Result(Nil, CancelFailure) {
  use request <- try(
    encode(CancelRequest(key.process_id, key.secret_key))
    |> map_error(CancelUnencodable),
  )
  // The cancel process ends within half the cancel timeout: its connect
  // and its wait for the server to close the cancel connection, which the
  // server does once it took the cancel, share that one deadline. So a
  // cancel that never gets an answer fails before the timeout of the
  // request.
  let cancel_deadline =
    deadline.from_now(config.cancel_timeout_milliseconds / 2)
  use socket <- try(
    transport.connect(config.transport, cancel_deadline)
    |> map_error(CancelUnreachable),
  )
  let sent = transport.send(socket, request)
  let closed = transport.receive(socket, deadline.time_left(cancel_deadline))
  transport.close(socket)
  use Nil <- try(sent |> map_error(CancelNotSent))
  case closed {
    Ok(_bytes) | Error(ReceiveFailed(SocketClosed)) -> Ok(Nil)
    Error(error) -> Error(CancelNotAnswered(error))
  }
}
