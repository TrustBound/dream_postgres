//// Interceptors for `recorder.intercept` that make the values that
//// change in each run the same in each recording: random UUIDs and
//// timestamps of now. Two record runs of the same test then write the
//// same bytes.
////
//// They change the cells that are written already: the parameters and
//// the rows of the copy that a recorder keeps, the rows of each answer,
//// and the SQL text. Each recording gets its own state: a recorder runs
//// its interceptors in its own process, and a new recorder starts with no
//// UUID known.
////
//// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres.{type PostgresError}
//// import dream_postgres/recorder.{
////   type Mode, type Recorder, intercept, match_on, mode, new, start,
//// }
//// import dream_postgres/recorder/match.{sql_and_parameters}
//// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
////
//// /// Starts the recorder of the test that creates an API key. The test
//// /// gives the mode, which it reads from its own config.
//// pub fn start_api_key_recorder(
////   recorder_mode: Mode,
//// ) -> Result(Recorder, Error(PostgresError)) {
////   new(file: "test/recordings/api_key_create.json")
////   |> mode(recorder_mode)
////   |> match_on(sql_and_parameters)
////   |> intercept(generated_uuids(keep: []))
////   |> intercept(timestamps_near_now(window_days: 400))
////   |> start
//// }
//// ```

import dream_postgres/interceptor.{
  type Answer, type Interceptor, type Request, CopyFrom, CopyFromAnswer, CopyTo,
  CopyToAnswer, Request, Sql, SqlAnswer, Statement, StatementAnswer,
}
import dream_postgres/internal/cell.{
  type Cell, type CommandResult, type StatementDescription, type TypeDescription,
  Binary, CommandResult, Null, Text,
}
import dream_postgres/internal/copy_request
import dream_postgres/internal/query
import dream_uuid
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp

/// The first 28 characters of each UUID placeholder.
const placeholder_prefix = "deadbeef-dead-4eef-8ead-beef"

/// The microseconds from 1970-01-01 to 2000-01-01, where the timestamps
/// of PostgreSQL count from.
const postgres_epoch_microseconds = 946_684_800_000_000

/// The timestamp that replaces each timestamp near now:
/// 2024-01-01 00:00:00 UTC, in microseconds from 2000-01-01.
const fixed_timestamp_microseconds = 757_382_400_000_000

const microseconds_in_a_day = 86_400_000_000

/// The types whose binary cells hold UTF-8 text.
const text_types = ["text", "varchar", "bpchar", "name", "json", "xml"]

/// An interceptor that replaces each random UUID with a placeholder:
/// `deadbeef-dead-4eef-8ead-beef00000001` for the first UUID it sees,
/// `...00000002` for the second, and so on. The same UUID gets the same
/// placeholder each time, as 16 bytes of a `uuid` cell and as text in a
/// text cell, in JSON or in SQL. The UUIDs of `keep`, such as the UUIDs
/// of seed data, do not change. A placeholder does not change, so a
/// placeholder that playback gives the app can go back in a parameter.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn generated_uuids(keep keep: List(String)) -> Interceptor {
  let map_key = reference.new()
  let kept = list.map(keep, string.lowercase)
  let change_uuid = uuid_change(map_key, kept, _)
  let change_text = replace_uuid_texts(_, change_uuid)
  changing_cells(change_text, fn(type_description, cell) {
    uuid_cell(type_description, cell, change_uuid, change_text)
  })
}

/// An interceptor that replaces each `timestamp` and `timestamptz` cell
/// within `window_days` days of now with 2024-01-01 00:00:00 UTC.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn timestamps_near_now(window_days window_days: Int) -> Interceptor {
  let window = window_days * microseconds_in_a_day
  changing_cells(fn(text) { text }, fn(type_description, cell) {
    timestamp_cell(type_description, cell, window)
  })
}

// --- Cells --------------------------------------------------------------------------

// An interceptor that changes the SQL and the written cells of the
// request, then the cells of the answer. A cell of a `run_sql` call answer has no
// type.
fn changing_cells(
  change_text: fn(String) -> String,
  change_cell: fn(Option(TypeDescription), Cell) -> Cell,
) -> Interceptor {
  fn(request: Request, next) {
    let typed_change = fn(type_description, cell) {
      change_cell(Some(type_description), cell)
    }
    let changed =
      Request(
        ..request,
        sql: change_text(request.sql),
        parameters: list.map(request.parameters, query.change_cell(
          _,
          typed_change,
        )),
        kind: changed_kind(request, typed_change),
      )
    next(changed) |> result.map(changed_answer(_, change_cell))
  }
}

fn changed_kind(
  request: Request,
  change: fn(TypeDescription, Cell) -> Cell,
) -> interceptor.RequestKind {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      CopyFrom(
        table:,
        columns:,
        rows: copy_request.map_rows(rows, fn(_row_number, values) {
          list.map(values, query.change_cell(_, change))
        }),
      )
    Statement | Sql | CopyTo -> request.kind
  }
}

fn changed_answer(
  answer: Answer,
  change: fn(Option(TypeDescription), Cell) -> Cell,
) -> Answer {
  case answer {
    StatementAnswer(description:, types:, result:) ->
      StatementAnswer(
        description:,
        types:,
        result: CommandResult(
          ..result,
          rows: changed_rows(
            result.rows,
            column_types(description, types),
            change,
          ),
        ),
      )
    SqlAnswer(results:) ->
      SqlAnswer(
        results: list.map(results, fn(sql_result: CommandResult) {
          CommandResult(
            ..sql_result,
            rows: changed_rows(sql_result.rows, [], change),
          )
        }),
      )
    CopyFromAnswer(..) -> answer
    CopyToAnswer(description:, types:, rows:) ->
      CopyToAnswer(
        description:,
        types:,
        rows: copy_request.change_recorded_rows(rows, changed_rows(
          _,
          column_types(description, types),
          change,
        )),
      )
  }
}

// The type of each column of the answer.
fn column_types(
  description: StatementDescription,
  types: List(TypeDescription),
) -> List(Option(TypeDescription)) {
  list.map(description.columns, fn(answer_column) {
    list.find(types, fn(type_description) {
      type_description.id == answer_column.type_id
    })
    |> option.from_result
  })
}

fn changed_rows(
  rows: List(List(Cell)),
  types: List(Option(TypeDescription)),
  change: fn(Option(TypeDescription), Cell) -> Cell,
) -> List(List(Cell)) {
  list.map(rows, fn(row) {
    list.index_map(row, fn(row_cell, position) {
      change(type_at(types, position), row_cell)
    })
  })
}

fn type_at(
  types: List(Option(TypeDescription)),
  position: Int,
) -> Option(TypeDescription) {
  types
  |> list.drop(position)
  |> list.first
  |> option.from_result
  |> option.flatten
}

// --- UUIDs --------------------------------------------------------------------------

/// The UUIDs that a `generated_uuids` interceptor knows, with the number
/// of the placeholder of each, and the number of the next placeholder.
type UuidMap {
  UuidMap(numbers: Dict(String, Int), next_number: Int)
}

/// What a `generated_uuids` interceptor does with one UUID.
type UuidChange {
  /// A UUID of `keep`: it stays as it was.
  Kept
  /// The UUID becomes the placeholder with this number.
  Placeholder(number: Int)
}

// The cell with each UUID in it replaced: the bytes of a `uuid` cell, and
// the text of a text cell.
fn uuid_cell(
  type_description: Option(TypeDescription),
  cell: Cell,
  change_uuid: fn(String) -> UuidChange,
  change_text: fn(String) -> String,
) -> Cell {
  case type_name(type_description), cell {
    "uuid", Binary(<<_:bytes-size(16)>> as bytes) ->
      Binary(changed_uuid_bytes(bytes, change_uuid(uuid_text_of(bytes))))
    "jsonb", Binary(<<1, json:bytes>>) ->
      Binary(<<1, changed_text_bytes(json, change_text):bits>>)
    name, Binary(bytes) -> text_type_cell(name, bytes, change_text)
    _, Text(bytes) -> Text(changed_text_bytes(bytes, change_text))
    _, Null -> Null
  }
}

fn text_type_cell(
  name: String,
  bytes: BitArray,
  change_text: fn(String) -> String,
) -> Cell {
  case list.contains(text_types, name) {
    True -> Binary(changed_text_bytes(bytes, change_text))
    False -> Binary(bytes)
  }
}

fn type_name(type_description: Option(TypeDescription)) -> String {
  type_description
  |> option.map(fn(described) { described.name })
  |> option.unwrap("")
}

// Bytes that are not UTF-8 hold no text, so they do not change.
fn changed_text_bytes(
  bytes: BitArray,
  change_text: fn(String) -> String,
) -> BitArray {
  bit_array.to_string(bytes)
  |> result.map(fn(text) { bit_array.from_string(change_text(text)) })
  |> result.unwrap(bytes)
}

// The text with each UUID in the canonical text form replaced.
fn replace_uuid_texts(
  text: String,
  change_uuid: fn(String) -> UuidChange,
) -> String {
  replace_uuid_texts_from(text, change_uuid, [])
}

fn replace_uuid_texts_from(
  text: String,
  change_uuid: fn(String) -> UuidChange,
  done: List(String),
) -> String {
  let candidate = string.slice(text, 0, 36)
  case dream_uuid.from_string(candidate), string.pop_grapheme(text) {
    Ok(_uuid), _ ->
      replace_uuid_texts_from(string.drop_start(text, 36), change_uuid, [
        changed_uuid_text(candidate, change_uuid(candidate)),
        ..done
      ])
    Error(_not_uuid), Ok(#(first, rest)) ->
      replace_uuid_texts_from(rest, change_uuid, [first, ..done])
    Error(_not_uuid), Error(Nil) -> string.concat(list.reverse(done))
  }
}

fn changed_uuid_text(uuid_text: String, change: UuidChange) -> String {
  case change {
    Kept -> uuid_text
    Placeholder(number:) ->
      placeholder_prefix <> string.pad_start(int.to_string(number), 8, "0")
  }
}

// The 16 bytes of the placeholder are the bytes of its text: the digits
// of the number are its last eight hex digits.
fn changed_uuid_bytes(bytes: BitArray, change: UuidChange) -> BitArray {
  case change {
    Kept -> bytes
    Placeholder(number:) -> <<
      0xdeadbeef:32,
      0xdead:16,
      0x4eef:16,
      0x8ead:16,
      0xbeef:16,
      decimal_digits(number, 8, <<>>):bits,
    >>
  }
}

// The last `count` decimal digits of the number, 4 bits each.
fn decimal_digits(number: Int, count: Int, done: BitArray) -> BitArray {
  case count > 0 {
    True ->
      decimal_digits(number / 10, count - 1, <<{ number % 10 }:4, done:bits>>)
    False -> done
  }
}

// What the interceptor does with a UUID, from its text. The map of the
// UUIDs is kept in the process that runs the interceptor.
fn uuid_change(
  map_key: Reference,
  kept: List(String),
  uuid_text: String,
) -> UuidChange {
  let canonical = string.lowercase(uuid_text)
  case list.contains(kept, canonical) {
    True -> Kept
    False -> {
      let #(number, uuid_map) =
        placeholder_number(stored_map(map_key), canonical)
      store_map(map_key, uuid_map)
      Placeholder(number:)
    }
  }
}

fn stored_map(map_key: Reference) -> UuidMap {
  stored(map_key) |> option.unwrap(UuidMap(numbers: dict.new(), next_number: 1))
}

// The number of the placeholder of the UUID. A placeholder keeps its own
// number, and the next new UUID gets a number after it.
fn placeholder_number(uuid_map: UuidMap, canonical: String) -> #(Int, UuidMap) {
  case dict.get(uuid_map.numbers, canonical), own_number(canonical) {
    Ok(number), _ -> #(number, uuid_map)
    Error(Nil), Ok(number) -> #(
      number,
      UuidMap(
        numbers: dict.insert(uuid_map.numbers, canonical, number),
        next_number: int.max(uuid_map.next_number, number + 1),
      ),
    )
    Error(Nil), Error(Nil) -> #(
      uuid_map.next_number,
      UuidMap(
        numbers: dict.insert(uuid_map.numbers, canonical, uuid_map.next_number),
        next_number: uuid_map.next_number + 1,
      ),
    )
  }
}

// The number of a placeholder, or an error for any other UUID.
fn own_number(canonical: String) -> Result(Int, Nil) {
  case string.starts_with(canonical, placeholder_prefix) {
    True -> int.parse(string.drop_start(canonical, 28))
    False -> Error(Nil)
  }
}

// The canonical text of the 16 bytes of a UUID.
fn uuid_text_of(bytes: BitArray) -> String {
  let hex = string.lowercase(bit_array.base16_encode(bytes))
  string.slice(hex, 0, 8)
  <> "-"
  <> string.slice(hex, 8, 4)
  <> "-"
  <> string.slice(hex, 12, 4)
  <> "-"
  <> string.slice(hex, 16, 4)
  <> "-"
  <> string.slice(hex, 20, 12)
}

@external(erlang, "dream_postgres_normalize_ffi", "stored")
fn stored(map_key: Reference) -> Option(UuidMap)

@external(erlang, "dream_postgres_normalize_ffi", "store")
fn store_map(map_key: Reference, uuid_map: UuidMap) -> Nil

// --- Timestamps ---------------------------------------------------------------------

fn timestamp_cell(
  type_description: Option(TypeDescription),
  cell: Cell,
  window: Int,
) -> Cell {
  case type_name(type_description), cell {
    "timestamp", Binary(<<microseconds:signed-size(64)>>)
    | "timestamptz", Binary(<<microseconds:signed-size(64)>>)
    -> near_now_cell(microseconds, window)
    _, Binary(..) | _, Text(..) | _, Null -> cell
  }
}

fn near_now_cell(microseconds: Int, window: Int) -> Cell {
  case int.absolute_value(microseconds - now_microseconds()) <= window {
    True -> Binary(<<fixed_timestamp_microseconds:size(64)>>)
    False -> Binary(<<microseconds:size(64)>>)
  }
}

// Now, in microseconds from 2000-01-01.
fn now_microseconds() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  seconds * 1_000_000 + nanoseconds / 1000 - postgres_epoch_microseconds
}
