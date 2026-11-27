//// Binary COPY on a driver connection: rows into a table with
//// `COPY ... FROM STDIN`, and the rows of a query out with
//// `COPY (...) TO STDOUT`. Each value goes through the same codecs, and
//// the same checks before anything is sent, as the parameters and the
//// rows of a query.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection.{type Connection, type CopySender}
import dream_postgres/error.{
  type Reason, CopyNeedsBinaryCodec, CopyQueryHasParameters, InterceptorFailed,
  MalformedCopyStream,
}
import dream_postgres/interceptor.{
  type Answer, type Interceptor, type Outcome, type Request, CopyFrom,
  CopyFromAnswer, CopyTo, CopyToAnswer, Request, Sql, SqlAnswer, Statement,
  StatementAnswer,
}
import dream_postgres/internal/cell.{
  type Cell, type StatementDescription, type TypeDescription, Binary, Null, Text,
}
import dream_postgres/internal/codec_type.{type TypeLookup}
import dream_postgres/internal/copy_request.{
  type CopyRows, type RowFeed, type RowWatcher, type Table, CopyRows,
  DatabaseRows, RecordedRows,
}
import dream_postgres/internal/copy_stream.{type StreamReader}
import dream_postgres/internal/driver_executor.{type Endpoint, Endpoint}
import dream_postgres/internal/query.{type Query, type Value}
import dream_postgres/internal/row_reader.{
  type CheckedRow, type Row, DescribedColumn,
}
import dream_postgres/internal/runner.{type Executor}
import dream_postgres/secrets.{type Secrets}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The size from which the rows of `copy_from` go to the server as one
/// chunk.
const chunk_bytes = 65_536

/// The columns of the table of a `copy_from`, with their types.
type Target {
  Target(names: List(String), types: List(TypeDescription), lookup: TypeLookup)
}

/// How each row of a `copy_to` is read and folded.
type Reading(a, accumulator) {
  Reading(
    checked: CheckedRow(a),
    lookup: TypeLookup,
    fold: fn(accumulator, a) -> accumulator,
  )
}

/// Where the fold of a `copy_to` is: the reader of the stream, the value
/// so far, and the watchers of the rows.
type CopyOut(accumulator) {
  CopyOut(
    reader: StreamReader,
    accumulator: accumulator,
    watchers: List(RowWatcher),
  )
}

/// The SQL of a `copy_from` into `table` and its `columns`, each quoted
/// as an identifier.
pub fn copy_from_sql(table: Table, columns: List(String)) -> String {
  "COPY "
  <> copy_request.table_sql(table)
  <> " ("
  <> copy_stream.quote_identifiers(columns)
  <> ") FROM STDIN (FORMAT binary)"
}

/// The SQL of a `copy_to` of the rows of the query SQL.
pub fn copy_to_sql(sql: String) -> String {
  "COPY (" <> sql <> ") TO STDOUT (FORMAT binary)"
}

/// Sends the request of a `copy_from` through the interceptors, and gives
/// the number of rows stored. `last` is the end of the chain:
/// `copy_from_database` on a connection, or the answer of a recording.
pub fn copy_from(
  interceptors: List(Interceptor),
  last: fn(Request) -> Outcome,
  table: Table,
  columns: List(String),
  rows: List(a),
  write: fn(a) -> List(Value),
) -> Result(Int, Reason) {
  let request =
    Request(
      sql: copy_from_sql(table, columns),
      name: None,
      parameters: [],
      kind: CopyFrom(table:, columns:, rows: copy_request.feed(rows, write)),
    )
  use answer <- result.try(runner.intercept(interceptors, request, last))
  case answer {
    CopyFromAnswer(count:) -> Ok(count)
    StatementAnswer(..) | SqlAnswer(..) | CopyToAnswer(..) ->
      Error(InterceptorFailed(
        reason: "an interceptor answered a COPY FROM with the answer of another kind of request",
      ))
  }
}

/// The end of the chain of a `copy_from` on a driver connection. It stores
/// the rows of the request in the columns of its table, and gives the
/// number of rows stored. The types of the columns come from a prepared
/// `SELECT` of them, and the first row is written and checked before the
/// COPY starts. A later row that cannot be written ends the COPY with no
/// row stored.
pub fn copy_from_database(
  connection: Connection,
  catalog: Catalog,
  endpoint: Endpoint,
  secrets: Secrets,
  deadline_milliseconds: Int,
) -> fn(Request) -> Outcome {
  fn(request: Request) {
    case request.kind {
      CopyFrom(table:, columns:, rows:) ->
        store_rows(
          connection,
          catalog,
          endpoint,
          secrets,
          deadline_milliseconds,
          request.sql,
          table,
          columns,
          rows,
        )
        |> result.map(CopyFromAnswer)
      Statement | Sql | CopyTo ->
        Error(InterceptorFailed(
          reason: "an interceptor changed a COPY FROM into another kind of request",
        ))
    }
  }
}

fn store_rows(
  connection: Connection,
  catalog: Catalog,
  endpoint: Endpoint,
  secrets: Secrets,
  deadline_milliseconds: Int,
  sql: String,
  table: Table,
  columns: List(String),
  rows: RowFeed,
) -> Result(Int, Reason) {
  let deadline_at =
    driver_executor.monotonic_milliseconds() + deadline_milliseconds
  let executor =
    driver_executor.executor(
      connection,
      catalog,
      endpoint,
      secrets,
      deadline_milliseconds,
    )
  use target <- result.try(target(executor, table, columns))
  use #(first_chunk, rest) <- result.try(start_stream(rows, target))
  use remaining <- result.try(driver_executor.remaining_milliseconds(
    deadline_at,
  ))
  connection.copy_from(
    connection,
    driver_executor.statement(sql, None, secrets),
    remaining,
    send_rows(_, rest, target, first_chunk),
  )
  |> result.map_error(driver_executor.copy_error_reason(_, endpoint))
}

fn target(
  executor: Executor,
  table: Table,
  columns: List(String),
) -> Result(Target, Reason) {
  use description <- result.try(executor.prepare(
    "SELECT "
      <> copy_stream.quote_identifiers(columns)
      <> " FROM "
      <> copy_request.table_sql(table),
    None,
  ))
  use #(types, lookup) <- result.try(runner.describe_types(
    executor,
    list.map(description.columns, fn(column) { column.type_id }),
  ))
  Ok(Target(
    names: list.map(description.columns, fn(column) { column.name }),
    types:,
    lookup:,
  ))
}

// The header, with the first row when there is one, and the rows after it.
fn start_stream(
  rows: RowFeed,
  target: Target,
) -> Result(#(BitArray, RowFeed), Reason) {
  case copy_request.next_row(rows) {
    None -> Ok(#(copy_stream.header(), rows))
    Some(#(first, rest)) ->
      encode_row(first, target)
      |> result.map(fn(tuple) {
        #(<<copy_stream.header():bits, tuple:bits>>, rest)
      })
  }
}

fn send_rows(
  sender: CopySender,
  rows: RowFeed,
  target: Target,
  pending: BitArray,
) -> Result(Nil, Reason) {
  case copy_request.next_row(rows) {
    None -> send(sender, <<pending:bits, copy_stream.trailer():bits>>)
    Some(#(row, rest)) -> {
      use tuple <- result.try(encode_row(row, target))
      use pending <- result.try(send_full(sender, <<pending:bits, tuple:bits>>))
      send_rows(sender, rest, target, pending)
    }
  }
}

// Sends the pending bytes once they fill a chunk, and gives what is still
// pending.
fn send_full(
  sender: CopySender,
  pending: BitArray,
) -> Result(BitArray, Reason) {
  case bit_array.byte_size(pending) >= chunk_bytes {
    True -> send(sender, pending) |> result.replace(<<>>)
    False -> Ok(pending)
  }
}

fn send(sender: CopySender, chunk: BitArray) -> Result(Nil, Reason) {
  connection.send_chunk(sender, chunk)
  |> result.map_error(driver_executor.chunk_error_reason)
}

fn encode_row(values: List(Value), target: Target) -> Result(BitArray, Reason) {
  write_row(values, target.types, target.lookup, target.names)
  |> result.map(copy_stream.encode_tuple)
}

/// Checks and writes the fields of a row of a binary COPY against the
/// types of the columns, as the parameters of a query, and gives the bytes
/// of each field, or `None` for a NULL. A codec that writes text is
/// `CopyNeedsBinaryCodec`, with the column's name from `names`.
pub fn write_row(
  values: List(Value),
  types: List(TypeDescription),
  lookup: TypeLookup,
  names: List(String),
) -> Result(List(Option(BitArray)), Reason) {
  use written <- result.try(query.write_values(values, types, lookup))
  list.zip(list.zip(values, names), written.values)
  |> list.index_map(fn(field, index) { #(index + 1, field) })
  |> list.try_map(binary_field)
}

fn binary_field(
  numbered: #(Int, #(#(Value, String), Cell)),
) -> Result(Option(BitArray), Reason) {
  let #(position, #(#(value, name), written)) = numbered
  case written {
    Binary(bytes:) -> Ok(Some(bytes))
    Null -> Ok(None)
    Text(..) ->
      Error(CopyNeedsBinaryCodec(
        position:,
        name:,
        codec: query.codec_name(value),
      ))
  }
}

/// The cell of a field of a binary COPY.
pub fn field_cell(field: Option(BitArray)) -> Cell {
  case field {
    Some(bytes) -> Binary(bytes:)
    None -> Null
  }
}

/// Sends the request of a `copy_to` through the interceptors, checks the
/// reader against the columns of the answer, and folds over its rows, each
/// read with the reader. A query with parameters is refused before
/// anything is sent. `last` is the end of the chain: `copy_to_database` on
/// a connection, or the answer of a recording.
pub fn copy_to(
  interceptors: List(Interceptor),
  last: fn(Request) -> Outcome,
  query: Query,
  reader: Row(a),
  initial: accumulator,
  fold: fn(accumulator, a) -> accumulator,
) -> Result(accumulator, Reason) {
  use Nil <- result.try(no_parameters(query.parameter_count(query)))
  let request =
    Request(
      sql: query.sql(query),
      name: query.name(query),
      parameters: [],
      kind: CopyTo,
    )
  use answer <- result.try(runner.intercept(interceptors, request, last))
  use #(description, types, rows) <- result.try(copy_to_answer(answer))
  use Nil <- result.try(no_parameters(list.length(description.parameters)))
  use #(column_types, lookup) <- result.try(runner.answer_types(
    types,
    list.map(description.columns, fn(column) { column.type_id }),
  ))
  use checked <- result.try(row_reader.check(
    reader,
    list.map2(description.columns, column_types, DescribedColumn),
    lookup,
  ))
  use Nil <- result.try(row_reader.require_binary_reads(checked))
  let reading = Reading(checked:, lookup:, fold:)
  let start = CopyOut(copy_stream.new_reader(), initial, rows.watchers)
  let streamed = case rows.source {
    DatabaseRows(connection:, sql:, name:, deadline_at:, host:, port:, secrets:) ->
      stream_database_rows(
        connection,
        driver_executor.statement(copy_to_sql(sql), name, secrets),
        deadline_at,
        Endpoint(host:, port:),
        start,
        reading,
      )
    RecordedRows(rows: recorded, ending:) ->
      list.try_fold(recorded, start, fn(copy_out, cells) {
        read_row(copy_out, cells, reading)
      })
      |> result.try(fn(copy_out) { result.replace(ending, copy_out) })
  }
  finish_watchers(streamed, rows.watchers)
}

fn copy_to_answer(
  answer: Answer,
) -> Result(#(StatementDescription, List(TypeDescription), CopyRows), Reason) {
  case answer {
    CopyToAnswer(description:, types:, rows:) -> Ok(#(description, types, rows))
    StatementAnswer(..) | SqlAnswer(..) | CopyFromAnswer(..) ->
      Error(InterceptorFailed(
        reason: "an interceptor answered a COPY TO with the answer of another kind of request",
      ))
  }
}

// Each watcher gets how the stream ended: the watchers after the last
// row, or the first watchers when the stream failed. The error of the
// stream comes first, then the first error of a watcher.
fn finish_watchers(
  streamed: Result(CopyOut(accumulator), Reason),
  first_watchers: List(RowWatcher),
) -> Result(accumulator, Reason) {
  let watchers =
    streamed
    |> result.map(fn(copy_out) { copy_out.watchers })
    |> result.unwrap(first_watchers)
  let ending = result.replace(streamed, Nil)
  let finished = list.try_each(watchers, fn(watcher) { watcher.finish(ending) })
  use copy_out <- result.try(streamed)
  result.replace(finished, copy_out.accumulator)
}

/// The end of the chain of a `copy_to` on a driver connection. It prepares
/// the query of the request and describes the types of its columns. The
/// COPY itself starts when the reader is checked, and must end before the
/// deadline that starts here.
pub fn copy_to_database(
  connection: Connection,
  catalog: Catalog,
  endpoint: Endpoint,
  secrets: Secrets,
  deadline_milliseconds: Int,
) -> fn(Request) -> Outcome {
  fn(request: Request) {
    let deadline_at =
      driver_executor.monotonic_milliseconds() + deadline_milliseconds
    let executor =
      driver_executor.executor(
        connection,
        catalog,
        endpoint,
        secrets,
        deadline_milliseconds,
      )
    use description <- result.try(executor.prepare(request.sql, request.name))
    use types <- result.try(runner.describe_every_type(
      executor,
      list.map(description.columns, fn(column) { column.type_id }),
    ))
    Ok(CopyToAnswer(
      description:,
      types:,
      rows: CopyRows(
        source: DatabaseRows(
          connection:,
          sql: request.sql,
          name: request.name,
          deadline_at:,
          host: endpoint.host,
          port: endpoint.port,
          secrets:,
        ),
        watchers: [],
      ),
    ))
  }
}

fn no_parameters(count: Int) -> Result(Nil, Reason) {
  case count {
    0 -> Ok(Nil)
    _ -> Error(CopyQueryHasParameters(count:))
  }
}

fn stream_database_rows(
  connection: Connection,
  statement: connection.Statement,
  deadline_at: Int,
  endpoint: Endpoint,
  start: CopyOut(accumulator),
  reading: Reading(a, accumulator),
) -> Result(CopyOut(accumulator), Reason) {
  use remaining <- result.try(driver_executor.remaining_milliseconds(
    deadline_at,
  ))
  use copied <- result.try(
    connection.copy_to(
      connection,
      statement,
      remaining,
      start,
      fn(copy_out, chunk) { read_chunk(copy_out, chunk, reading) },
    )
    |> result.map_error(driver_executor.copy_error_reason(_, endpoint)),
  )
  copy_stream.finish(copied.reader)
  |> result.map_error(MalformedCopyStream)
  |> result.replace(copied)
}

fn read_chunk(
  copy_out: CopyOut(accumulator),
  chunk: BitArray,
  reading: Reading(a, accumulator),
) -> Result(CopyOut(accumulator), Reason) {
  use #(reader, tuples) <- result.try(
    copy_stream.read_chunk(copy_out.reader, chunk)
    |> result.map_error(MalformedCopyStream),
  )
  list.try_fold(tuples, CopyOut(..copy_out, reader:), fn(next, cells) {
    read_row(next, cells, reading)
  })
}

// Each watcher sees the row before it is read.
fn read_row(
  copy_out: CopyOut(accumulator),
  cells: List(Cell),
  reading: Reading(a, accumulator),
) -> Result(CopyOut(accumulator), Reason) {
  let watchers =
    list.map(copy_out.watchers, fn(watcher) { watcher.take(cells) })
  use value <- result.try(row_reader.read(
    reading.checked,
    cells,
    reading.lookup,
  ))
  Ok(
    CopyOut(
      ..copy_out,
      accumulator: reading.fold(copy_out.accumulator, value),
      watchers:,
    ),
  )
}
