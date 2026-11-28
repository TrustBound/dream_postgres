//// The caller's side of a COPY: it sends or reads the rows while the connection
//// process keeps the socket.

import dream_postgres/driver/connection/call.{
  type Connection, call, call_failure, request_message,
}
import dream_postgres/driver/connection/copy_exchange.{
  type CopyDone, type CopyEnding, type CopyFault, type CopyNotice, type CopyPush,
  type CopyStartError, AbandonCopy, CallerLeft, CompleteCopy, CopyDone,
  CopyFaultFailed, CopyFaultNotStarted, CopyFaultRefused, Finish, PushedEnd,
  PushedRow, RowTaken, StartEnded, StartRefused, StartUnencodable, close_pushes,
  open_pushes, receive_end, receive_push,
}
import dream_postgres/driver/connection/process_message.{
  CopyNotice, CopyRequest, SendChunk,
}
import dream_postgres/driver/connection/reply.{type ReplyTo}
import dream_postgres/driver/connection/request_failure.{
  type ChunkError, type CopyError, type RequestFailure, AppFailed, ChunkFailed,
  CopyFailed, CopyNotConnected, CopyNotStarted, CopyRefused, CopyUnencodable,
  RefusedNotConnected, RefusedWithFailure,
}
import dream_postgres/driver/connection/statement.{type Statement, recorded_text}
import dream_postgres/driver/connection/tracing.{copy_ending, traced}
import dream_postgres/driver/query/step.{type CopyDirection, CopyFrom, CopyTo}
import gleam/erlang/process
import gleam/erlang/reference.{type Reference}
import gleam/result.{map_error, try}

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
  {
    use <-
      traced(connection, statement, recorded_text(statement), _, copy_ending)
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
  |> result.map(fn(done) { done.value })
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
  {
    use <-
      traced(connection, statement, recorded_text(statement), _, copy_ending)
    use sender <- with_sender(connection, deadline_milliseconds)
    use Nil <- try(start_copy(
      sender,
      CopyTo,
      statement.sql,
      deadline_milliseconds,
    ))
    read_rows(sender, initial, fold)
  }
  |> result.map(fn(done) { done.value })
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
) -> Result(CopyDone(value), CopyError(reason)) {
  case next_push(sender) {
    Ok(PushedRow(row:)) -> fold_row(sender, fold(accumulator, row), fold)
    Ok(PushedEnd(result:, warning_code:)) ->
      take_end(sender, result)
      |> result.replace(CopyDone(accumulator, warning_code))
    Error(error) -> Error(leave_copy(sender, error))
  }
}

/// A fold that took its row tells the process, which reads the next row
/// only then. A fold that failed ends the COPY.
fn fold_row(
  sender: CopySender,
  folded: Result(value, reason),
  fold: fn(value, BitArray) -> Result(value, reason),
) -> Result(CopyDone(value), CopyError(reason)) {
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
  ended: Result(CopyDone(Int), CopyError(reason)),
  reason: reason,
) -> Result(CopyDone(value), CopyError(reason)) {
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
) -> Result(CopyDone(Int), CopyError(reason)) {
  notify(sender, Finish(ending))
  case receive_end(sender.pushes, sender.wait_milliseconds) {
    Ok(#(ended, warning_code)) ->
      ended
      |> result.map(CopyDone(_, warning_code))
      |> map_error(copy_fault_error)
    Error(failure) ->
      Error(leave_copy(sender, CopyFailed(call_failure(failure))))
  }
}
