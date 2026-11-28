//// The COPY types that the caller and the connection process share, and the
//// pushes of the process to the caller.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/reply.{type CallFailure, type ReplyTo}
import dream_postgres/driver/connection/request_failure.{
  type ChunkError, type Refusal, type RequestFailure,
}
import dream_postgres/driver/message.{type EncodeError}
import gleam/erlang/process.{type Monitor, type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option}

/// Why a COPY that the process ran gave no row count: what its caller
/// gets with its start, its calls, or its end.
pub type CopyFault {
  CopyFaultFailed(failure: RequestFailure)
  CopyFaultRefused(report: ServerReport, transaction_status: TransactionStatus)
  CopyFaultNotStarted(completed: Option(Outcome))
}

/// Why the start of a COPY failed.
pub type CopyStartError {
  /// The process refused the request before it ran.
  StartRefused(refusal: Refusal)
  /// The statement cannot be written.
  StartUnencodable(error: EncodeError)
  /// The COPY ended before it started.
  StartEnded(fault: CopyFault)
}

/// What the caller of a COPY tells the process while its COPY runs. No
/// notice needs an answer: the caller waits only for what the process
/// pushes, and a notice for a COPY that is gone changes nothing.
pub type CopyNotice {
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
pub type CopyEnding {
  /// The app sent all its data: the server stores the rows.
  CompleteCopy
  /// The app's function failed: the server stores no row.
  AbandonCopy
}

/// What the caller of a COPY gets at its end: its value, with the last
/// warning code of the COPY for its span.
pub type CopyDone(value) {
  CopyDone(value: value, warning_code: Option(String))
}

/// What the process pushes to the caller of a COPY. The caller waits for
/// a push or for the end of the process, so each wait ends.
pub type CopyPush {
  /// A row of a `COPY ... TO STDOUT`. The process reads nothing more from
  /// the socket until the caller sends `RowTaken`.
  PushedRow(row: BitArray)
  /// The end of the COPY: its row count, or why there is none. The
  /// process pushes it once.
  PushedEnd(result: Result(Int, CopyFault), warning_code: Option(String))
}

/// The caller's side of a COPY that runs.
pub type CopySession {
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
pub type EndedCopy {
  EndedCopy(id: Reference, monitor: Monitor, result: Result(Int, CopyFault))
}

/// Makes where the connection process pushes the rows and the end of a
/// COPY: a monitor of the process that is also an alias of the caller.
@external(erlang, "dream_postgres_connection_ffi", "open_pushes")
pub fn open_pushes(pid: Pid) -> ReplyTo(CopyPush)

/// Waits for the next push, for the end of the connection process, or for
/// `timeout` milliseconds.
@external(erlang, "dream_postgres_connection_ffi", "receive_push")
pub fn receive_push(
  pushes: ReplyTo(CopyPush),
  timeout: Int,
) -> Result(CopyPush, CallFailure)

/// Waits for the end of a COPY, for the end of the connection process, or
/// for `timeout` milliseconds. A row is not an end: no row comes after
/// the caller ended its side.
@external(erlang, "dream_postgres_connection_ffi", "receive_end")
pub fn receive_end(
  pushes: ReplyTo(CopyPush),
  timeout: Int,
) -> Result(#(Result(Int, CopyFault), Option(String)), CallFailure)

/// Turns the pushes off: a push that comes later is dropped, and the
/// pushes that wait in the mailbox are taken out.
@external(erlang, "dream_postgres_connection_ffi", "close_pushes")
pub fn close_pushes(pushes: ReplyTo(CopyPush)) -> Nil
