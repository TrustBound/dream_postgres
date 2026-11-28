//// The messages that a connection process receives, and the requests that they
//// carry.

import dream_postgres/driver/connection/copy_exchange.{
  type CopyNotice, type CopyPush, type CopyStartError,
}
import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/reply.{type ReplyTo}
import dream_postgres/driver/connection/request_failure.{
  type ChunkError, type HousekeepingError, type PrepareError, type RunError,
  type SettleError, type SimpleQueryError,
}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/message.{type EncodeError}
import dream_postgres/driver/query/step.{type CopyDirection}
import dream_postgres/driver/transport.{
  type ReceiveError, type SendError, type TransportError,
}
import dream_postgres/internal/cell.{
  type Cell, type Format, type ServerReport, type StatementDescription,
  type TransactionStatus,
}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Down, type ExitMessage, type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option}

pub type Message {
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
  ReconnectNow(attempt: Int, previous_wait_milliseconds: Int)
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
  OpenAttempt(attempt: Int, previous_wait_milliseconds: Int)
}

/// A request that goes to the server.
pub type Request {
  StatementRequest(statement: StatementRequest)
  /// The transaction status after every request before it.
  SettledStatusRequest(reply: ReplyTo(Result(TransactionStatus, SettleError)))
  SimpleQueryRequest(
    sql: String,
    reply: ReplyTo(Result(List(Outcome), SimpleQueryError)),
  )
  /// A driver housekeeping statement, prepared and run in one round trip.
  HousekeepingRunRequest(
    sql: HousekeepingSql,
    reply: ReplyTo(Result(Outcome, HousekeepingError)),
  )
  /// A driver housekeeping statement, with the simple query protocol.
  HousekeepingSimpleQueryRequest(
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
pub type StatementRequest {
  PrepareStatement(
    sql: String,
    source: DescriptionSource,
    reply: ReplyTo(Result(Prepared, PrepareError)),
  )
  RunStatement(details: RunDetails)
}

/// Where the description of a prepare comes from when the cache holds the
/// statement.
pub type DescriptionSource {
  /// The cache's description, from the statement's last prepare.
  CachedDescription
  /// The server's description now: the cached statement is closed and
  /// prepared again.
  ServerDescription
}

/// What a run needs. `previous` is the description of a statement that
/// the server made the driver prepare again: the run goes on only when
/// the new description is the same.
pub type RunDetails {
  RunDetails(
    sql: String,
    parameters: List(Cell),
    result_formats: List(Format),
    reply: ReplyTo(Result(Outcome, RunError)),
    previous: Option(StatementDescription),
  )
}

/// A prepared statement, with the last warning code of its prepare for
/// its span.
pub type Prepared {
  Prepared(description: StatementDescription, warning_code: Option(String))
}

/// What a caller can read of the connection without a request to the
/// server.
pub type Snapshot {
  Snapshot(
    transaction_status: TransactionStatus,
    aborted_by: Option(ServerReport),
    parameters: Dict(String, String),
  )
}

/// Why a cancel did not reach the server.
pub type CancelFailure {
  CancelUnreachable(error: TransportError)
  CancelNotSent(error: SendError)
  CancelNotAnswered(error: ReceiveError)
  CancelUnencodable(error: EncodeError)
}
