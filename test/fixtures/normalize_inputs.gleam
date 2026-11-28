//// Requests and answers for the tests of the normalizers, the keys and
//// the secrets, with cells written already as a recorder sees them.

import dream_postgres/codecs
import dream_postgres/codecs/composite
import dream_postgres/copy/request.{CopyRows, RecordedRows}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Base, Binary, CommandResult,
  StatementDescription, TypeDescription,
}
import dream_postgres/error.{InterceptorFailed}
import dream_postgres/interceptor.{
  type Outcome, type Request, CopyFrom, CopyToAnswer, Request, SqlAnswer,
  Statement, StatementAnswer,
}
import dream_postgres/query/definition.{type Value}
import dream_postgres/recorder/match
import fixtures/column_description
import gleam/list
import gleam/option.{None}
import gleam/time/timestamp

/// A UUID that a database could make.
pub const uuid_text = "0b8f5c2e-6a1d-4f3b-9c7e-2d4a6b8c0e1f"

/// The text of the first placeholder.
pub const first_placeholder = "deadbeef-dead-4eef-8ead-beef00000001"

/// The 16 bytes of `uuid_text`.
///
/// ## Example
///
/// ```gleam
/// Binary(normalize_inputs.uuid_bytes())
/// ```
pub fn uuid_bytes() -> BitArray {
  <<0x0b8f5c2e:32, 0x6a1d:16, 0x4f3b:16, 0x9c7e:16, 0x2d4a6b8c0e1f:48>>
}

/// The 16 bytes of the placeholder with this number, below 100.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.placeholder_bytes(1)
/// ```
pub fn placeholder_bytes(number: Int) -> BitArray {
  <<
    0xdeadbeef:32,
    0xdead:16,
    0x4eef:16,
    0x8ead:16,
    0xbeef:16,
    0:24,
    { number / 10 }:4,
    { number % 10 }:4,
  >>
}

/// The type of this name in `pg_catalog`, with the id 1.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.type_named("uuid")
/// ```
pub fn type_named(name: String) -> TypeDescription {
  TypeDescription(id: 1, schema: "pg_catalog", name:, kind: Base)
}

/// The answer of a statement with one column of the type, and the rows.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.rows_of("uuid", [[Binary(normalize_inputs.uuid_bytes())]])
/// ```
pub fn rows_of(type_name: String, rows: List(List(Cell))) -> Outcome {
  Ok(StatementAnswer(
    description: StatementDescription(parameters: [], columns: [
      column_description.new("value", 1),
    ]),
    types: [type_named(type_name)],
    result: CommandResult(rows:, tag: "SELECT", count: list.length(rows)),
  ))
}

/// The answer of a `run_sql` call with the rows, whose cells have no type.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.sql_rows([[Text(<<"1":utf8>>)]])
/// ```
pub fn sql_rows(rows: List(List(Cell))) -> Outcome {
  Ok(
    SqlAnswer(results: [
      CommandResult(rows:, tag: "SELECT", count: list.length(rows)),
    ]),
  )
}

/// The recorded answer of a COPY TO with one column of the type.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.copied_rows_of("uuid", [[Binary(normalize_inputs.uuid_bytes())]])
/// ```
pub fn copied_rows_of(type_name: String, rows: List(List(Cell))) -> Outcome {
  Ok(CopyToAnswer(
    description: StatementDescription(parameters: [], columns: [
      column_description.new("value", 1),
    ]),
    types: [type_named(type_name)],
    rows: CopyRows(source: RecordedRows(rows:, ending: Ok(Nil)), watchers: []),
  ))
}

/// A value of the codec `bytea` that was written as the cell, with the
/// type of this name.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.written("uuid", Binary(normalize_inputs.uuid_bytes()))
/// ```
pub fn written(type_name: String, cell: Cell) -> Value {
  definition.written_as(
    composite.field(codecs.bytea, <<>>),
    type_named(type_name),
    cell,
  )
}

/// The parameters of a query with one secret value of the codec `text`,
/// written with the type `text`.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.statement("SELECT $1", normalize_inputs.written_secret())
/// ```
pub fn written_secret() -> List(Value) {
  definition.query("SELECT $1")
  |> definition.secret_parameter(codecs.text, "hunter2")
  |> definition.values
  |> list.map(definition.written_as(
    _,
    type_named("text"),
    Binary(<<"hunter2":utf8>>),
  ))
}

/// A value of the codec `int` that was not written.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.not_written()
/// ```
pub fn not_written() -> Value {
  composite.field(codecs.int, 1)
}

/// A statement with the SQL and the parameters.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.statement("SELECT $1", [normalize_inputs.not_written()])
/// ```
pub fn statement(sql: String, parameters: List(Value)) -> Request {
  Request(sql:, name: None, parameters:, kind: Statement)
}

/// A `copy_from` of the rows into the table `items`.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.copy_from([[normalize_inputs.not_written()]])
/// ```
pub fn copy_from(rows: List(List(Value))) -> Request {
  Request(
    sql: "COPY items FROM STDIN",
    name: None,
    parameters: [],
    kind: CopyFrom(
      table: request.table("items"),
      columns: ["value"],
      rows: request.feed(rows, fn(row) { row }),
    ),
  )
}

/// The end of a chain that gives the outcome.
///
/// ## Example
///
/// ```gleam
/// interceptor(request, normalize_inputs.answering(outcome))
/// ```
pub fn answering(outcome: Outcome) -> fn(Request) -> Outcome {
  fn(_request) { outcome }
}

/// The end of a chain that refuses with the key of the request that
/// reached it, so a test sees what the interceptor passed on.
///
/// ## Example
///
/// ```gleam
/// interceptor(request, normalize_inputs.refusing_with_key)
/// ```
pub fn refusing_with_key(request: Request) -> Outcome {
  Error(InterceptorFailed(reason: match.sql_and_parameters(request)))
}

/// A binary `timestamptz` cell of now.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.now_cell()
/// ```
pub fn now_cell() -> Cell {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  let microseconds = { seconds - 946_684_800 } * 1_000_000 + nanoseconds / 1000
  Binary(<<microseconds:64>>)
}

/// The cell of 2024-01-01 00:00:00 UTC that replaces a timestamp near now.
///
/// ## Example
///
/// ```gleam
/// normalize_inputs.fixed_timestamp_cell()
/// ```
pub fn fixed_timestamp_cell() -> Cell {
  Binary(<<757_382_400_000_000:64>>)
}
