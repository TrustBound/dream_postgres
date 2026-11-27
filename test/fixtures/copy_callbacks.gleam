//// The functions that the COPY tests give to `copy_from` and `copy_to`:
//// the app's produce functions and folds, and the caller processes that
//// run a COPY and never end by themselves.

import dream_postgres/driver/connection.{
  type Connection, type CopyError, type CopySender, type DriverError,
  type Outcome, ConnectionLost, SocketFailed, copy_from, copy_to, run_script,
  send_chunk,
}
import dream_postgres/driver/transport.{SocketClosed}
import driver/proxy.{type Proxy, close_client, inject}
import driver/server_connection.{memory_of, wait_for_idle_backend}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/result.{try}
import gleam/string

/// The largest memory and mailbox of the connection process, and the
/// largest memory of the caller, over the samples of a COPY, in bytes.
pub type MemoryPeak {
  MemoryPeak(connection: Int, queue: Int, caller: Int)
}

/// The error of a produce function or a fold whose wait got no answer.
fn no_answer() -> DriverError {
  ConnectionLost(SocketFailed(SocketClosed))
}

// Data ------------------------------------------------------------------------

/// The binary COPY data of one row with the int4 1: the header, the row
/// and the trailer (docs, "COPY", "Binary Format").
pub fn binary_copy() -> BitArray {
  <<"PGCOPY\n":utf8, 255, "\r\n":utf8, 0, 0:32, 0:32, 1:16, 4:32, 1:32, -1:16>>
}

// Produce functions -----------------------------------------------------------

/// Three rows in two chunks. The end of the first chunk is in the middle
/// of a row.
pub fn send_three_rows(sender: CopySender) -> Result(Nil, DriverError) {
  use Nil <- try(send_chunk(sender, <<"1\tone\n2\ttw":utf8>>))
  send_chunk(sender, <<"o\n3\tthree\n":utf8>>)
}

/// Sends nothing.
pub fn send_nothing(_sender: CopySender) -> Result(Nil, DriverError) {
  Ok(Nil)
}

/// Sends three rows, then fails with `stopped`.
pub fn send_then_fail(sender: CopySender) -> Result(Nil, String) {
  use Nil <- try(
    send_three_rows(sender) |> result.replace_error("the send failed"),
  )
  Error("stopped")
}

/// Sends a row whose id is not an integer.
pub fn send_bad_row(sender: CopySender) -> Result(Nil, DriverError) {
  send_chunk(sender, <<"x\tbad\n":utf8>>)
}

/// Sends a row that is not valid, then valid rows until the server's
/// error comes back.
pub fn send_until_refused(sender: CopySender) -> Result(Nil, DriverError) {
  use Nil <- try(send_bad_row(sender))
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// Sends the chunk again and again until a send fails, and gives that
/// failure.
pub fn send_until_error(
  sender: CopySender,
  chunk: BitArray,
  attempts: Int,
) -> Result(Nil, DriverError) {
  case send_chunk(sender, chunk), attempts {
    Ok(Nil), 0 -> Ok(Nil)
    Ok(Nil), _ -> send_until_error(sender, chunk, attempts - 1)
    Error(error), _ -> Error(error)
  }
}

/// Sends the binary COPY data of `binary_copy`.
pub fn send_binary(sender: CopySender) -> Result(Nil, DriverError) {
  send_chunk(sender, binary_copy())
}

/// Sends two csv rows.
pub fn send_csv(sender: CopySender) -> Result(Nil, DriverError) {
  send_chunk(sender, <<"1,a\n2,\"b,c\"\n":utf8>>)
}

/// Sends a row, ends the backend `pid` from the control connection and
/// waits until it is gone, then sends a second row.
pub fn send_after_end(
  sender: CopySender,
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(send_chunk(sender, <<"1\tone\n":utf8>>))
  let sql = "SELECT pg_terminate_backend(" <> pid <> ", 5000)"
  use _terminated <- try(run_script(control, sql, 5000))
  send_chunk(sender, <<"2\ttwo\n":utf8>>)
}

/// Sends nothing until the backend `pid` is idle, then sends a row.
pub fn send_after_idle(
  sender: CopySender,
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(watch_until_idle(control, pid) |> await_idle)
  send_chunk(sender, <<"1\tone\n":utf8>>)
}

/// Sends a row, has the proxy close the client's socket, then sends rows
/// until a send fails.
pub fn send_across_close(
  sender: CopySender,
  proxy: Proxy,
) -> Result(Nil, DriverError) {
  use Nil <- try(send_chunk(sender, <<"1\tone\n":utf8>>))
  close_client(proxy)
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// Sends a row, has the proxy send a BindComplete, then sends rows until
/// a send fails.
pub fn send_across_violation(
  sender: CopySender,
  proxy: Proxy,
) -> Result(Nil, DriverError) {
  use Nil <- try(send_chunk(sender, <<"1\tone\n":utf8>>))
  inject(proxy, <<"2", 4:32>>)
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// Sends a row that a CHECK constraint keeps, then rows that it refuses
/// until a send fails, then one more chunk. Fails with the error of the
/// refusal and the answer to that chunk.
pub fn send_twice_after_error(
  sender: CopySender,
) -> Result(Nil, #(DriverError, Result(Nil, DriverError))) {
  use Nil <- try(
    send_chunk(sender, <<"1\tone\n":utf8>>)
    |> result.map_error(with_no_next),
  )
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
  |> result.map_error(with_next_send(_, sender))
}

fn with_no_next(
  error: DriverError,
) -> #(DriverError, Result(Nil, DriverError)) {
  #(error, Ok(Nil))
}

fn with_next_send(
  error: DriverError,
  sender: CopySender,
) -> #(DriverError, Result(Nil, DriverError)) {
  #(error, send_chunk(sender, <<"3\tthree\n":utf8>>))
}

/// Runs a script and a second COPY on the connection of the COPY, each
/// with a deadline of 50 milliseconds, and fails with their answers.
pub fn copy_inside(
  _sender: CopySender,
  connection: Connection,
) -> Result(
  Nil,
  #(Result(List(Outcome), DriverError), Result(Int, CopyError(DriverError))),
) {
  let inner_script = run_script(connection, "SELECT 1", 50)
  let inner_copy =
    copy_from(connection, "COPY waiting FROM STDIN", 50, send_nothing)
  Error(#(inner_script, inner_copy))
}

/// Sends `sender` to `senders`, and sends nothing.
pub fn keep_sender(
  sender: CopySender,
  senders: Subject(CopySender),
) -> Result(Nil, DriverError) {
  process.send(senders, sender)
  Ok(Nil)
}

/// The sender that `keep_sender` sent. It panics when there is none: that
/// is a setup failure.
pub fn kept_sender(senders: Subject(CopySender)) -> CopySender {
  case process.receive(senders, 0) {
    Ok(sender) -> sender
    Error(Nil) -> panic as "no sender was kept"
  }
}

/// Sends a row, tells `started` where to say go, waits for go, and sends
/// a second row.
pub fn send_after_go(
  sender: CopySender,
  started: Subject(Subject(Nil)),
) -> Result(Nil, DriverError) {
  use Nil <- try(send_chunk(sender, <<"1\tone\n":utf8>>))
  let go = process.new_subject()
  process.send(started, go)
  use Nil <- try(process.receive(go, 5000) |> result.replace_error(no_answer()))
  send_chunk(sender, <<"2\ttwo\n":utf8>>)
}

/// Where `send_after_go` waits for go. It panics when it does not come in
/// 5 seconds: that is a setup failure.
pub fn await_go(started: Subject(Subject(Nil))) -> Subject(Nil) {
  case process.receive(started, 5000) {
    Ok(go) -> go
    Error(Nil) -> panic as "the COPY did not start"
  }
}

// Folds -----------------------------------------------------------------------

/// Collects each row, newest first.
pub fn collect_row(
  rows: List(BitArray),
  row: BitArray,
) -> Result(List(BitArray), Nil) {
  Ok([row, ..rows])
}

/// Appends each row to the data before it, so the rows give the COPY
/// data in order.
pub fn append_row(data: BitArray, row: BitArray) -> Result(BitArray, Nil) {
  Ok(bit_array.append(data, row))
}

/// Collects the size of each row, newest first.
pub fn collect_size(sizes: List(Int), row: BitArray) -> Result(List(Int), Nil) {
  Ok([bit_array.byte_size(row), ..sizes])
}

/// Fails with `enough` at the second row.
pub fn fail_at_second_row(rows: Int, _row: BitArray) -> Result(Int, String) {
  case rows {
    0 -> Ok(1)
    _ -> Error("enough")
  }
}

/// Fails with `enough` at the first row.
pub fn fail_at_first_row(_rows: Int, _row: BitArray) -> Result(Int, String) {
  Error("enough")
}

/// Holds the first row until the backend `pid` is idle.
pub fn read_until_idle(
  waited: Bool,
  _row: BitArray,
  control: Connection,
  pid: String,
) -> Result(Bool, DriverError) {
  use <- bool.guard(waited, Ok(True))
  watch_until_idle(control, pid) |> await_idle |> result.replace(True)
}

/// Has the proxy close the client's socket at the first row.
pub fn close_at_first_row(
  closed: Bool,
  _row: BitArray,
  proxy: Proxy,
) -> Result(Bool, DriverError) {
  use <- bool.guard(closed, Ok(True))
  close_client(proxy)
  Ok(True)
}

fn watch_until_idle(
  control: Connection,
  pid: String,
) -> Subject(Result(Nil, Nil)) {
  let idle = process.new_subject()
  process.spawn(fn() { tell_when_idle(control, pid, idle) })
  idle
}

fn tell_when_idle(
  control: Connection,
  pid: String,
  idle: Subject(Result(Nil, Nil)),
) -> Nil {
  process.send(idle, wait_for_idle_backend(control, pid))
}

fn await_idle(idle: Subject(Result(Nil, Nil))) -> Result(Nil, DriverError) {
  process.receive(idle, 10_000)
  |> result.flatten
  |> result.replace_error(no_answer())
}

// Memory ----------------------------------------------------------------------

/// Sends 1,000 chunks of 1,000 rows, about 16,000,000 bytes, samples the
/// memory after every 10 chunks, and sends the peak to `peaks`.
pub fn load_chunks_sampling(
  sender: CopySender,
  connection_pid: Pid,
  peaks: Subject(MemoryPeak),
) -> Result(Nil, DriverError) {
  let chunk = bit_array.from_string(string.repeat("12345\tsome text\n", 1000))
  let start = MemoryPeak(0, 0, 0)
  use peak <- try(load_chunks(sender, chunk, 1000, connection_pid, start))
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
  use Nil <- try(send_chunk(sender, chunk))
  let sampled = sample_every(peak, left, 10, connection_pid)
  load_chunks(sender, chunk, left - 1, connection_pid, sampled)
}

/// Counts the rows, and samples the memory after every 10,000 rows.
pub fn count_and_sample(
  counted: #(Int, MemoryPeak),
  _row: BitArray,
  connection_pid: Pid,
) -> Result(#(Int, MemoryPeak), Nil) {
  let #(count, peak) = counted
  Ok(#(count + 1, sample_every(peak, count, 10_000, connection_pid)))
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

fn sample_memory(peak: MemoryPeak, connection_pid: Pid) -> MemoryPeak {
  let #(connection_bytes, queue) = memory_of(connection_pid)
  let #(caller_bytes, _caller_queue) = memory_of(process.self())
  MemoryPeak(
    connection: int.max(peak.connection, connection_bytes),
    queue: int.max(peak.queue, queue),
    caller: int.max(peak.caller, caller_bytes),
  )
}

// Callers that never end by themselves ----------------------------------------

/// A caller process, not linked to the test, that runs `copy` and tells
/// `started` what its function did.
pub type CopyCaller(told) {
  CopyCaller(pid: Pid, told: Subject(told))
}

/// Starts a caller process that runs `copy`, with the subject where its
/// function tells what it did.
pub fn start_copy_caller(copy: fn(Subject(told)) -> value) -> CopyCaller(told) {
  let told = process.new_subject()
  let pid = process.spawn_unlinked(fn() { copy(told) })
  CopyCaller(pid:, told:)
}

/// What the function of the caller told, or `Error(Nil)` after 5 seconds.
pub fn caller_told(caller: CopyCaller(told)) -> Result(told, Nil) {
  process.receive(caller.told, 5000)
}

/// A COPY FROM STDIN into `hung` that sends three rows, tells `sent`, and
/// waits forever.
pub fn hang_after_rows(
  connection: Connection,
  started: Subject(String),
) -> Result(Int, CopyError(DriverError)) {
  copy_from(connection, "COPY hung FROM STDIN", 5000, send_and_hang(_, started))
}

fn send_and_hang(
  sender: CopySender,
  started: Subject(String),
) -> Result(Nil, DriverError) {
  use Nil <- try(send_three_rows(sender))
  process.send(started, "sent")
  process.receive_forever(process.new_subject())
}

/// A COPY FROM STDIN into `hung` that sends rows until the server refuses
/// one, tells the answer of that send, and waits forever.
pub fn hang_after_refusal(
  connection: Connection,
  started: Subject(Result(Nil, DriverError)),
) -> Result(Int, CopyError(DriverError)) {
  copy_from(connection, "COPY hung FROM STDIN", 5000, refuse_and_hang(
    _,
    started,
  ))
}

fn refuse_and_hang(
  sender: CopySender,
  started: Subject(Result(Nil, DriverError)),
) -> Result(Nil, DriverError) {
  process.send(started, send_until_refused(sender))
  process.receive_forever(process.new_subject())
}

/// A COPY TO STDOUT of 1,000,000 rows whose fold tells `row` at the first
/// row and waits forever.
pub fn hang_at_first_row(
  connection: Connection,
  started: Subject(String),
) -> Result(Nil, CopyError(Nil)) {
  copy_to(
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
