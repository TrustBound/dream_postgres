//// The COPY scenarios of the connection tests, on the driver servers. Each
//// runs one COPY story and gives what the test checks, with the errors as
//// the short names of `fixtures/driver_error_names` where a whole server
//// report would differ between versions.

import dream_postgres/driver/connection.{
  type Connection, type CopyError, type CopySender, type DriverError,
  type Outcome, AppFailed, ConnectionLost,
}
import dream_postgres/driver/transport.{SocketClosed}
import dream_postgres/internal/cell.{type TransactionStatus}
import fixtures/driver_error_names.{
  copy_error_name, copy_error_names, driver_error_name, driver_error_names,
}
import fixtures/driver_session.{
  type Proxy, type Setup, backend_pid, close_client, first_server, inject,
  pid_of, script, tags, texts, wait_until_idle, with_connection, with_setup,
}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result.{try}
import gleam/string

/// The largest memory and mailbox of the connection process, and the
/// largest memory of the caller, over the samples of a COPY, in bytes.
pub type MemoryPeak {
  MemoryPeak(connection: Int, queue: Int, caller: Int)
}

/// The deadline of every COPY of these scenarios that does not test a
/// deadline.
const deadline = 5000

/// The deadline of the scenarios that pass it.
const short_deadline = 300

// Building blocks -------------------------------------------------------------

fn copy_from(
  connection: Connection,
  sql: String,
  produce: fn(CopySender) -> Result(Nil, reason),
) -> Result(Int, CopyError(reason)) {
  connection.copy_from(connection, sql, deadline, produce)
}

fn create_table(
  connection: Connection,
  table: String,
) -> Result(Nil, DriverError) {
  script(connection, "CREATE TEMP TABLE " <> table <> " (id int, name text)")
  |> result.replace(Nil)
}

fn count_rows(
  connection: Connection,
  table: String,
) -> Result(String, DriverError) {
  script(connection, "SELECT count(*)::text FROM " <> table)
  |> result.map(texts)
  |> result.map(string.concat)
}

fn no_answer() -> DriverError {
  ConnectionLost(SocketClosed)
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

fn send_then_fail(sender: CopySender) -> Result(Nil, String) {
  use Nil <- try(
    send_three_rows(sender) |> result.replace_error("the send failed"),
  )
  Error("stopped")
}

fn send_bad_row(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, <<"x\tbad\n":utf8>>)
}

/// Sends a row that is not valid, then valid rows until the server's
/// error comes back.
fn send_until_refused(sender: CopySender) -> Result(Nil, DriverError) {
  use Nil <- try(send_bad_row(sender))
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// Sends the chunk again and again until a send fails, and gives that
/// failure.
fn send_until_error(
  sender: CopySender,
  chunk: BitArray,
  attempts: Int,
) -> Result(Nil, DriverError) {
  case connection.send_chunk(sender, chunk), attempts {
    Ok(Nil), 0 -> Ok(Nil)
    Ok(Nil), _ -> send_until_error(sender, chunk, attempts - 1)
    Error(error), _ -> Error(error)
  }
}

fn collect_row(
  rows: List(BitArray),
  row: BitArray,
) -> Result(List(BitArray), Nil) {
  Ok([row, ..rows])
}

fn collect_size(sizes: List(Int), row: BitArray) -> Result(List(Int), Nil) {
  Ok([bit_array.byte_size(row), ..sizes])
}

fn fail_at_second_row(rows: Int, _row: BitArray) -> Result(Int, String) {
  case rows {
    0 -> Ok(1)
    _ -> Error("enough")
  }
}

fn fail_at_first_row(_rows: Int, _row: BitArray) -> Result(Int, String) {
  Error("enough")
}

/// The binary COPY data of one row with the int4 1: the header, the row
/// and the trailer (docs, "COPY", "Binary Format").
pub fn binary_copy() -> BitArray {
  <<"PGCOPY\n":utf8, 255, "\r\n":utf8, 0, 0:32, 0:32, 1:16, 4:32, 1:32, -1:16>>
}

fn send_binary(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, binary_copy())
}

fn send_csv(sender: CopySender) -> Result(Nil, DriverError) {
  connection.send_chunk(sender, <<"1,a\n2,\"b,c\"\n":utf8>>)
}

// On each server --------------------------------------------------------------

/// Stores three rows, and reads them back with a query.
pub fn store_three_rows(
  port: Int,
) -> Result(#(Result(Int, String), List(String)), DriverError) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "copied"))
  let stored =
    copy_from(connection, "COPY copied FROM STDIN", send_three_rows)
    |> copy_error_names
  use outcomes <- try(script(
    connection,
    "SELECT id::text, name FROM copied ORDER BY id",
  ))
  Ok(#(stored, texts(outcomes)))
}

/// Reads three rows, each as its own bytes, newest first.
pub fn read_three_rows(
  port: Int,
) -> Result(Result(List(BitArray), CopyError(Nil)), DriverError) {
  use connection <- with_connection(port)
  Ok(connection.copy_to(
    connection,
    "COPY (SELECT n, 'r' || n FROM generate_series(1, 3) n) TO STDOUT",
    deadline,
    [],
    collect_row,
  ))
}

/// Reads one row of 4,000,001 bytes, longer than one read of the socket,
/// so the caller asks for it before it is whole.
pub fn read_long_row(
  port: Int,
) -> Result(Result(List(Int), CopyError(Nil)), DriverError) {
  use connection <- with_connection(port)
  Ok(connection.copy_to(
    connection,
    "COPY (SELECT repeat('x', 4000000)) TO STDOUT",
    deadline,
    [],
    collect_size,
  ))
}

/// Stores two csv rows, and reads them back as csv, newest first.
pub fn copy_csv_both_ways(
  port: Int,
) -> Result(
  #(Result(Int, CopyError(DriverError)), Result(List(BitArray), CopyError(Nil))),
  DriverError,
) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "csv"))
  let stored =
    copy_from(connection, "COPY csv FROM STDIN (FORMAT csv)", send_csv)
  let read =
    connection.copy_to(
      connection,
      "COPY csv TO STDOUT (FORMAT csv)",
      deadline,
      [],
      collect_row,
    )
  Ok(#(stored, read))
}

/// Stores one binary row, and reads the binary COPY data back.
pub fn copy_binary_both_ways(
  port: Int,
) -> Result(
  #(Result(Int, CopyError(DriverError)), Result(BitArray, CopyError(Nil))),
  DriverError,
) {
  use connection <- with_connection(port)
  use _created <- try(script(connection, "CREATE TEMP TABLE b (n int4)"))
  let stored =
    copy_from(connection, "COPY b FROM STDIN (FORMAT binary)", send_binary)
  let read =
    connection.copy_to(
      connection,
      "COPY b TO STDOUT (FORMAT binary)",
      deadline,
      [],
      collect_row,
    )
    |> result.map(list.reverse)
    |> result.map(bit_array.concat)
  Ok(#(stored, read))
}

/// A COPY in a transaction that rolls back, the count after it, a COPY in
/// one that commits, and the count after it.
pub fn copy_in_transactions(
  port: Int,
) -> Result(
  #(
    Result(Int, CopyError(DriverError)),
    String,
    Result(Int, CopyError(DriverError)),
    String,
  ),
  DriverError,
) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "kept"))
  use _begun <- try(script(connection, "BEGIN"))
  let rolled_back =
    copy_from(connection, "COPY kept FROM STDIN", send_three_rows)
  use _rolled_back <- try(script(connection, "ROLLBACK"))
  use after_rollback <- try(count_rows(connection, "kept"))
  use _begun <- try(script(connection, "BEGIN"))
  let committed = copy_from(connection, "COPY kept FROM STDIN", send_three_rows)
  use _committed <- try(script(connection, "COMMIT"))
  use after_commit <- try(count_rows(connection, "kept"))
  Ok(#(rolled_back, after_rollback, committed, after_commit))
}

/// A COPY that the app abandons inside a transaction, and the status
/// after it.
pub fn abandon_in_transaction(
  port: Int,
) -> Result(#(Result(Int, CopyError(String)), TransactionStatus), DriverError) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "failing"))
  use _begun <- try(script(connection, "BEGIN"))
  let failed = copy_from(connection, "COPY failing FROM STDIN", send_then_fail)
  use status <- try(connection.transaction_status(connection))
  use _rolled_back <- try(script(connection, "ROLLBACK"))
  Ok(#(failed, status))
}

/// A row that the server refuses in the middle, while the app sends, and
/// the count after it.
pub fn refuse_in_the_middle(
  port: Int,
) -> Result(#(Result(Int, String), String), DriverError) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "refused"))
  let refused =
    copy_from(connection, "COPY refused FROM STDIN", send_until_refused)
    |> copy_error_names
  use count <- try(count_rows(connection, "refused"))
  Ok(#(refused, count))
}

/// A row that the server refuses after the app sent all its data, and the
/// status after it.
pub fn refuse_after_the_data(
  port: Int,
) -> Result(#(Result(Int, String), TransactionStatus), DriverError) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "bad"))
  let refused =
    copy_from(connection, "COPY bad FROM STDIN", send_bad_row)
    |> copy_error_names
  use status <- try(connection.transaction_status(connection))
  Ok(#(refused, status))
}

/// A COPY that the app abandons, and the count after it.
pub fn abandon_on_app_failure(
  port: Int,
) -> Result(#(Result(Int, CopyError(String)), String), DriverError) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "abandoned"))
  let failed =
    copy_from(connection, "COPY abandoned FROM STDIN", send_then_fail)
  use count <- try(count_rows(connection, "abandoned"))
  Ok(#(failed, count))
}

/// A fold that fails at the second of 100,000 rows, and the tags of the
/// next script.
pub fn fail_the_fold(
  port: Int,
) -> Result(#(Result(Int, CopyError(String)), List(String)), DriverError) {
  use connection <- with_connection(port)
  let failed =
    connection.copy_to(
      connection,
      "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
      deadline,
      0,
      fail_at_second_row,
    )
  use next <- try(script(connection, "SELECT 7"))
  Ok(#(failed, tags(next)))
}

/// A statement that is not a COPY given to `copy_from`, a
/// `COPY ... TO STDOUT` given to `copy_from`, a `COPY ... FROM STDIN`
/// given to `copy_to`, and the count of the table after them.
pub fn start_no_copy(
  port: Int,
) -> Result(
  #(
    Result(Int, CopyError(DriverError)),
    Result(Int, CopyError(DriverError)),
    Result(List(BitArray), CopyError(Nil)),
    String,
  ),
  DriverError,
) {
  use connection <- with_connection(port)
  use Nil <- try(create_table(connection, "other"))
  let select = copy_from(connection, "SELECT 1", send_three_rows)
  let out = copy_from(connection, "COPY other TO STDOUT", send_three_rows)
  let into =
    connection.copy_to(
      connection,
      "COPY other FROM STDIN",
      deadline,
      [],
      collect_row,
    )
  use count <- try(count_rows(connection, "other"))
  Ok(#(select, out, into, count))
}

/// A COPY of a table that does not exist.
pub fn copy_missing_table(
  port: Int,
) -> Result(Result(Int, String), DriverError) {
  use connection <- with_connection(port)
  copy_from(connection, "COPY no_such_table FROM STDIN", send_three_rows)
  |> copy_error_names
  |> Ok
}

/// The session ends while the app sends nothing; then the app sends.
pub fn end_the_session_in_the_middle(
  port: Int,
) -> Result(Result(Int, String), DriverError) {
  use connection <- with_connection(port)
  use control <- with_connection(port)
  use Nil <- try(create_table(connection, "ended"))
  use pid <- try(backend_pid(connection))
  copy_from(connection, "COPY ended FROM STDIN", send_after_end(_, control, pid))
  |> copy_error_names
  |> Ok
}

fn send_after_end(
  sender: CopySender,
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"1\tone\n":utf8>>))
  use Nil <- try(driver_session.terminate_backend(control, pid))
  connection.send_chunk(sender, <<"2\ttwo\n":utf8>>)
}

// Memory ----------------------------------------------------------------------

fn sample_memory(peak: MemoryPeak, connection_pid: Pid) -> MemoryPeak {
  let #(connection_bytes, queue) = driver_session.memory_of(connection_pid)
  let #(caller_bytes, _caller_queue) = driver_session.memory_of(process.self())
  MemoryPeak(
    connection: int.max(peak.connection, connection_bytes),
    queue: int.max(peak.queue, queue),
    caller: int.max(peak.caller, caller_bytes),
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

/// Loads 1,000,000 rows, about 16,000,000 bytes, in 1,000 chunks, and
/// samples the memory after every 10 chunks. Gives the count and the peak.
pub fn load_million_rows() -> Result(#(Int, MemoryPeak), String) {
  with_connection(first_server().port, load_rows_on)
  |> driver_error_names
  |> result.flatten
}

fn load_rows_on(
  connection: Connection,
) -> Result(Result(#(Int, MemoryPeak), String), DriverError) {
  use _created <- try(script(
    connection,
    "CREATE TEMP TABLE loaded (n int, name text)",
  ))
  let peaks = process.new_subject()
  let connection_pid = pid_of(connection)
  let stored =
    copy_from(connection, "COPY loaded FROM STDIN", load_chunks_from(
      _,
      connection_pid,
      peaks,
    ))
    |> copy_error_names
  Ok(result.try(stored, with_peak(_, peaks)))
}

fn with_peak(
  count: Int,
  peaks: Subject(MemoryPeak),
) -> Result(#(Int, MemoryPeak), String) {
  process.receive(peaks, 0)
  |> result.replace_error("no peak")
  |> result.map(pair_with(count, _))
}

fn pair_with(count: Int, peak: MemoryPeak) -> #(Int, MemoryPeak) {
  #(count, peak)
}

fn load_chunks_from(
  sender: CopySender,
  connection_pid: Pid,
  peaks: Subject(MemoryPeak),
) -> Result(Nil, DriverError) {
  let chunk = bit_array.from_string(string.repeat("12345\tsome text\n", 1000))
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

/// Reads 1,000,000 rows, about 17,000,000 bytes, and samples the memory
/// after every 10,000 rows. Gives the count and the peak.
pub fn read_million_rows() -> Result(#(Int, MemoryPeak), String) {
  with_connection(first_server().port, read_rows_on)
  |> driver_error_names
  |> result.flatten
}

fn read_rows_on(
  connection: Connection,
) -> Result(Result(#(Int, MemoryPeak), String), DriverError) {
  let connection_pid = pid_of(connection)
  connection.copy_to(
    connection,
    "COPY (SELECT n, 'some text' FROM generate_series(1, 1000000) n) TO STDOUT",
    60_000,
    #(0, MemoryPeak(0, 0, 0)),
    fn(counted, row) { count_and_sample(counted, row, connection_pid) },
  )
  |> result.replace_error("the COPY failed")
  |> Ok
}

fn count_and_sample(
  counted: #(Int, MemoryPeak),
  _row: BitArray,
  connection_pid: Pid,
) -> Result(#(Int, MemoryPeak), Nil) {
  let #(count, peak) = counted
  Ok(#(count + 1, sample_every(peak, count, 10_000, connection_pid)))
}

// Deadlines -------------------------------------------------------------------

/// A COPY FROM STDIN whose deadline passes while the app sends at full
/// speed, and the count after it.
pub fn pass_the_deadline_while_sending() -> Result(
  #(Result(Int, String), String),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  use Nil <- try(create_table(connection, "late"))
  let chunk = bit_array.from_string(string.repeat("1\tone\n", 1000))
  let late =
    connection.copy_from(
      connection,
      "COPY late FROM STDIN",
      short_deadline,
      send_until_error(_, chunk, 1_000_000),
    )
    |> copy_error_names
  use count <- try(count_rows(connection, "late"))
  Ok(#(late, count))
}

/// A produce function that is slow: it sends nothing until its deadline
/// passed and the backend is idle, then sends a row. Gives the result and
/// the count after it.
pub fn cut_off_a_slow_producer() -> Result(
  #(Result(Int, String), String),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  use control <- with_connection(first_server().port)
  use Nil <- try(create_table(connection, "idle"))
  use pid <- try(backend_pid(connection))
  let late =
    connection.copy_from(
      connection,
      "COPY idle FROM STDIN",
      short_deadline,
      send_after_idle(_, control, pid),
    )
    |> copy_error_names
  use count <- try(count_rows(connection, "idle"))
  Ok(#(late, count))
}

fn send_after_idle(
  sender: CopySender,
  control: Connection,
  pid: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(watch_until_idle(control, pid) |> await_idle)
  connection.send_chunk(sender, <<"1\tone\n":utf8>>)
}

/// A fold that is slow: it holds the first row until the deadline passed
/// and the backend is idle. Gives the result and the tags of the next
/// script.
pub fn cut_off_a_slow_fold() -> Result(
  #(Result(Bool, String), List(String)),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  use control <- with_connection(first_server().port)
  use pid <- try(backend_pid(connection))
  let late =
    connection.copy_to(
      connection,
      "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
      short_deadline,
      False,
      fn(waited, row) { read_until_idle(waited, row, control, pid) },
    )
    |> copy_error_names
  use next <- try(script(connection, "SELECT 8"))
  Ok(#(late, tags(next)))
}

fn read_until_idle(
  waited: Bool,
  _row: BitArray,
  control: Connection,
  pid: String,
) -> Result(Bool, DriverError) {
  use <- bool.guard(waited, Ok(True))
  watch_until_idle(control, pid) |> await_idle |> result.replace(True)
}

/// A fold that fails at the first of 10,000,000 rows, so the driver reads
/// the rest, which its deadline cuts off. Gives the result and the tags of
/// the next script.
pub fn cut_off_the_rest_after_a_failed_fold() -> Result(
  #(Result(Int, String), List(String)),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  let failed =
    connection.copy_to(
      connection,
      "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
      short_deadline,
      0,
      fail_at_first_row,
    )
    |> result.map_error(app_reason_name)
  use next <- try(script(connection, "SELECT 9"))
  Ok(#(failed, tags(next)))
}

fn app_reason_name(error: CopyError(String)) -> String {
  case error {
    AppFailed(reason) -> "app " <> reason
    connection.DriverFailed(error) -> "driver " <> driver_error_name(error)
  }
}

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
  |> result.replace_error(no_answer())
  |> result.flatten
}

// Callers ---------------------------------------------------------------------

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

/// The caller of a COPY FROM STDIN ends after it sent three rows. Gives
/// what the caller told, and the count after it.
pub fn end_the_caller_while_it_sends() -> Result(#(String, String), DriverError) {
  use connection <- with_connection(first_server().port)
  use Nil <- try(create_table(connection, "hung"))
  let #(caller, started) = start_copy_caller(hang_after_rows(connection, _))
  let told = started_text(started)
  process.kill(caller)
  use count <- try(count_rows(connection, "hung"))
  Ok(#(told, count))
}

/// The caller of a COPY FROM STDIN ends after the server refused a row,
/// before it took the end. Gives what the caller told, and the count
/// after it.
pub fn end_the_caller_after_the_refusal() -> Result(
  #(String, String),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  use Nil <- try(create_table(connection, "hung"))
  let #(caller, started) = start_copy_caller(hang_after_refusal(connection, _))
  let told = started_text(started)
  process.kill(caller)
  use count <- try(count_rows(connection, "hung"))
  Ok(#(told, count))
}

/// The caller of a COPY TO STDOUT ends while it holds the first row.
/// Gives what the caller told, and the tags of the next script.
pub fn end_the_caller_while_it_reads() -> Result(
  #(String, List(String)),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  let #(caller, started) = start_copy_caller(hang_at_first_row(connection, _))
  let told = started_text(started)
  process.kill(caller)
  use next <- try(script(connection, "SELECT 9"))
  Ok(#(told, tags(next)))
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
  let told = case send_until_refused(sender) {
    Ok(Nil) -> "not refused"
    Error(error) -> driver_error_name(error)
  }
  process.send(started, told)
  process.receive_forever(process.new_subject())
}

fn hang_at_first_row(
  connection: Connection,
  started: Subject(String),
) -> Result(Nil, CopyError(Nil)) {
  connection.copy_to(
    connection,
    "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
    deadline,
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

/// A DOWN message of a monitor that the connection never made, then a
/// script. Gives its tags.
pub fn send_a_stray_down() -> Result(List(String), DriverError) {
  use connection <- with_connection(first_server().port)
  driver_session.send_stray_down(pid_of(connection))
  script(connection, "SELECT 10") |> result.map(tags)
}

// Calls after the end ---------------------------------------------------------

/// A chunk sent with the sender of a COPY that ended. Gives the count of
/// the COPY and the answer to the chunk.
pub fn send_after_the_end() -> Result(
  #(Result(Int, CopyError(DriverError)), Result(Result(Nil, DriverError), Nil)),
  DriverError,
) {
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

fn keep_sender(
  sender: CopySender,
  senders: Subject(CopySender),
) -> Result(Nil, DriverError) {
  process.send(senders, sender)
  Ok(Nil)
}

/// A row that breaks a CHECK constraint, then one more chunk after the
/// refusal. Gives the names of the refusal and of the answer to that
/// chunk.
pub fn send_after_the_refusal() -> Result(Result(Int, String), DriverError) {
  use connection <- with_connection(first_server().port)
  use _created <- try(script(
    connection,
    "CREATE TEMP TABLE again (id int CHECK (id < 2), name text)",
  ))
  copy_from(connection, "COPY again FROM STDIN", send_twice_after_error)
  |> result.map_error(twice_name)
  |> Ok
}

fn send_twice_after_error(
  sender: CopySender,
) -> Result(Nil, #(DriverError, Result(Nil, DriverError))) {
  use Nil <- try(
    connection.send_chunk(sender, <<"1\tone\n":utf8>>)
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
  #(error, connection.send_chunk(sender, <<"3\tthree\n":utf8>>))
}

fn twice_name(
  error: CopyError(#(DriverError, Result(Nil, DriverError))),
) -> String {
  case error {
    AppFailed(#(first, next)) -> {
      let next_name =
        result.unwrap_error(next, ConnectionLost(SocketClosed))
        |> driver_error_name
      "app " <> driver_error_name(first) <> ", then " <> next_name
    }
    connection.DriverFailed(error) -> "driver " <> driver_error_name(error)
  }
}

/// A COPY whose SQL has a zero byte.
pub fn copy_with_a_zero_byte() -> Result(
  Result(Int, CopyError(DriverError)),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  Ok(copy_from(connection, "COPY t FROM STDIN\u{0000}", send_three_rows))
}

/// A script and a second COPY that the caller runs inside its COPY, each
/// with a deadline of 50 ms. Gives the names of their answers.
pub fn request_inside_a_copy() -> Result(
  Result(Int, CopyError(#(String, String))),
  DriverError,
) {
  use connection <- with_connection(first_server().port)
  use Nil <- try(create_table(connection, "waiting"))
  Ok(
    copy_from(connection, "COPY waiting FROM STDIN", copy_inside(_, connection)),
  )
}

fn copy_inside(
  _sender: CopySender,
  connection: Connection,
) -> Result(Nil, #(String, String)) {
  let inner_script = case connection.run_script(connection, "SELECT 1", 50) {
    Ok(_outcomes) -> "ran"
    Error(error) -> driver_error_name(error)
  }
  let inner_copy = case
    connection.copy_from(
      connection,
      "COPY waiting FROM STDIN",
      50,
      send_nothing,
    )
  {
    Ok(_count) -> "ran"
    Error(error) -> copy_error_name(error)
  }
  Error(#(inner_script, inner_copy))
}

// Losses ----------------------------------------------------------------------

/// The proxy closes the connection while the app sends.
pub fn close_in_the_middle() -> Result(Result(Int, String), DriverError) {
  use setup <- with_setup
  use Nil <- try(create_table(setup.connection, "lost"))
  copy_from(setup.connection, "COPY lost FROM STDIN", send_across_close(
    _,
    setup.proxy,
  ))
  |> copy_error_names
  |> result.map_error(loss_name)
  |> Ok
}

fn send_across_close(
  sender: CopySender,
  proxy: Proxy,
) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"1\tone\n":utf8>>))
  close_client(proxy)
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// A loss is `driver lost`, whatever the socket said: a close or a reset.
fn loss_name(name: String) -> String {
  case string.starts_with(name, "driver lost") {
    True -> "driver lost"
    False -> name
  }
}

/// The proxy sends a BindComplete in the middle of the data.
pub fn break_the_protocol_in_the_middle() -> Result(
  Result(Int, String),
  DriverError,
) {
  use setup <- with_setup
  use Nil <- try(create_table(setup.connection, "broken"))
  copy_from(setup.connection, "COPY broken FROM STDIN", send_across_violation(
    _,
    setup.proxy,
  ))
  |> copy_error_names
  |> Ok
}

fn send_across_violation(
  sender: CopySender,
  proxy: Proxy,
) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"1\tone\n":utf8>>))
  inject(proxy, <<"2", 4:32>>)
  send_until_error(sender, <<"2\ttwo\n":utf8>>, 1_000_000)
}

/// The proxy starts a COPY FROM STDIN as the server would, and then reads
/// nothing more, so a chunk cannot be sent in time.
pub fn fill_the_socket() -> Result(Result(Int, String), DriverError) {
  use setup <- with_setup
  driver_session.answer_next_request(setup.proxy, <<
    "1", 4:32, "2", 4:32, "G", 7:32, 0, 0:16,
  >>)
  let chunk = bit_array.from_string(string.repeat("x", 65_536))
  copy_from(setup.connection, "COPY t FROM STDIN", send_until_error(
    _,
    chunk,
    1_000_000,
  ))
  |> copy_error_names
  |> Ok
}

/// The proxy closes the connection while the app holds the first row of a
/// COPY TO STDOUT.
pub fn close_while_reading() -> Result(Result(Bool, String), DriverError) {
  use setup <- with_setup
  connection.copy_to(
    setup.connection,
    "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
    deadline,
    False,
    fn(closed, row) { close_at_first_row(closed, row, setup.proxy) },
  )
  |> copy_error_names
  |> Ok
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

// A write that fails after the server's last error ----------------------------

/// The server's FATAL error is in the connection process's mailbox, and
/// the socket was reset, when a request comes: its write fails. Gives the
/// name of the answer to the request.
pub fn fail_a_write_after_the_error() -> Result(
  Result(List(Outcome), String),
  DriverError,
) {
  use setup <- with_setup
  let pid = pid_of(setup.connection)
  let answers = process.new_subject()
  driver_session.suspend(pid)
  process.spawn(fn() { answer_script(setup.connection, answers) })
  let gated = break_while_suspended(setup, pid, "request")
  driver_session.resume(pid)
  use Nil <- try(gated)
  process.receive(answers, 5000)
  |> result.replace_error(no_answer())
}

fn answer_script(
  connection: Connection,
  answers: Subject(Result(List(Outcome), String)),
) -> Nil {
  process.send(answers, script(connection, "SELECT 1") |> driver_error_names)
}

/// The same inside a COPY: the write of a chunk fails.
pub fn fail_a_chunk_after_the_error() -> Result(
  Result(Int, String),
  DriverError,
) {
  use setup <- with_setup
  use Nil <- try(create_table(setup.connection, "gated"))
  let pid = pid_of(setup.connection)
  let started = process.new_subject()
  let answers = process.new_subject()
  process.spawn(fn() { copy_after_go(setup.connection, started, answers) })
  use go <- try(
    process.receive(started, 5000) |> result.replace_error(no_answer()),
  )
  driver_session.suspend(pid)
  process.send(go, Nil)
  let gated = break_while_suspended(setup, pid, "copy_call")
  driver_session.resume(pid)
  use Nil <- try(gated)
  process.receive(answers, 5000)
  |> result.replace_error(no_answer())
}

fn copy_after_go(
  connection: Connection,
  started: Subject(Subject(Nil)),
  answers: Subject(Result(Int, String)),
) -> Nil {
  copy_from(connection, "COPY gated FROM STDIN", send_after_go(_, started))
  |> copy_error_names
  |> process.send(answers, _)
}

/// Sends a row, tells `started` where to say go, waits for go, and sends
/// a second row.
fn send_after_go(
  sender: CopySender,
  started: Subject(Subject(Nil)),
) -> Result(Nil, DriverError) {
  use Nil <- try(connection.send_chunk(sender, <<"1\tone\n":utf8>>))
  let go = process.new_subject()
  process.send(started, go)
  use Nil <- try(process.receive(go, 5000) |> result.replace_error(no_answer()))
  connection.send_chunk(sender, <<"2\ttwo\n":utf8>>)
}

/// A TLS session through the proxy: the socket was reset, and the reset
/// reached the connection process, when a request comes: its write fails.
/// Gives the name of the answer to the request.
pub fn fail_a_tls_write_after_a_reset() -> Result(
  Result(List(Outcome), String),
  DriverError,
) {
  use setup <- driver_session.with_tls_setup
  let pid = pid_of(setup.connection)
  let answers = process.new_subject()
  driver_session.suspend(pid)
  process.spawn(fn() { answer_script(setup.connection, answers) })
  let gated = reset_while_suspended(setup, pid)
  driver_session.resume(pid)
  use Nil <- try(gated)
  process.receive(answers, 5000)
  |> result.replace_error(no_answer())
}

fn reset_while_suspended(setup: Setup, pid: Pid) -> Result(Nil, DriverError) {
  use Nil <- try(
    gate(driver_session.wait_for_message(pid, ["request"], 1_000_000)),
  )
  driver_session.reset_client(setup.proxy)
  gate(driver_session.wait_for_message(
    pid,
    ["ssl_closed", "ssl_error"],
    1_000_000,
  ))
}

/// While the connection process is suspended: waits until the message
/// `tag` of the caller waits in its mailbox, has the proxy send the FATAL
/// error, waits until the socket delivered it to the mailbox, has the
/// proxy reset the socket, and waits until the reset reached the socket.
fn break_while_suspended(
  setup: Setup,
  pid: Pid,
  tag: String,
) -> Result(Nil, DriverError) {
  use Nil <- try(gate(driver_session.wait_for_message(pid, [tag], 1_000_000)))
  inject(setup.proxy, driver_session.fatal_error_bytes())
  use Nil <- try(gate(driver_session.wait_for_message(pid, ["tcp"], 1_000_000)))
  driver_session.reset_client(setup.proxy)
  gate(driver_session.wait_for_reset(pid, 1_000_000))
}

fn gate(passed: Bool) -> Result(Nil, DriverError) {
  case passed {
    True -> Ok(Nil)
    False -> Error(no_answer())
  }
}
