//// The recorded queries of `dream_postgres/recorder`, and their file format.
////
//// A recording file holds the queries of one test, in the order they ran.
//// Each query has its SQL, its parameters and its result: the count and the
//// rows, or the error. The file is JSON, with one key order, so a diff of
//// two recordings shows only what changed:
////
//// ```json illustration
//// {
////   "format": "dream_postgres query recording",
////   "version": 1,
////   "queries": [
////     {
////       "sql": "SELECT id, name FROM users WHERE id = $1",
////       "parameters": [1],
////       "result": {
////         "count": 1,
////         "rows": [
////           {"tuple":[1,"Ada"]}
////         ]
////       }
////     },
////     {
////       "sql": "SELECT name FROM missing_table",
////       "parameters": [],
////       "result": {"error":"postgresql_error","code":"42P01","name":"undefined_table","message":"relation \"missing_table\" does not exist"}
////     }
////   ]
//// }
//// ```
////
//// Each parameter and each row is a value on one line. A value is written
//// as follows:
////
//// | Value from the driver | JSON | `RecordedValue` |
//// |---|---|---|
//// | `null` (SQL `NULL`) | `null` | `Null` |
//// | `true`, `false` | `true`, `false` | `Boolean` |
//// | an integer | a number with no `.` | `Integer` |
//// | a float | a number with a `.` or an `e`, such as `1.5` or `1.0e30` | `Real` |
//// | text (valid UTF-8) | a string | `Text` |
//// | bytes that are not valid UTF-8 | `{"bytes":"00FF"}` (base 16) | `Bytes` |
//// | bits, such as the SQL `bit(3)` value `101` | `{"bits":{"size":3,"hex":"A0"}}` | `Bytes` |
//// | a list (an SQL array) | an array | `Array` |
//// | a tuple (a row, a date, a time) | `{"tuple":[...]}` | `Tuple` |
//// | a map (a row with `rows_as_map`) | `{"map":[[key,value],...]}` | `Map` |
//// | another atom, such as `infinity` | `{"atom":"infinity"}` | `Atom` |
////
//// The `result` is `{"count":...,"rows":[...]}` for a query that worked, or
//// `{"error":...}` for one that failed, with the fields of the
//// `pog.QueryError`. The `reason` of a `pog.InterceptorFailed` error is a
//// value as above. A reason that no value can hold, such as a process, is
//// written as its text. `version` is 1. A later version of this package that
//// changes the format gives the files a new version, and reads version 1.

import dream_pog as pog
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

/// The version of the file format that `to_json` writes and `from_json`
/// reads.
pub const format_version = 1

/// The value of the `format` key of a recording file.
pub const format_name = "dream_postgres query recording"

/// A parameter of a query, or a value that a query returned, as the
/// recorder keeps it.
///
/// Each constructor is one kind of term that the driver gives. A query
/// played back from a recording gives the same term that it gave live.
pub type RecordedValue {
  /// SQL `NULL`.
  Null
  /// A `boolean`.
  Boolean(Bool)
  /// An integer, also a `numeric` with no fraction and a `timestamp`, which
  /// the driver gives as microseconds.
  Integer(Int)
  /// A float, also a `numeric` with a fraction.
  Real(Float)
  /// Text: `text`, `varchar`, `json`, `jsonb`, a UUID cast to text, and
  /// every other value whose bytes are valid UTF-8, a `bytea` too.
  Text(String)
  /// Bytes that are not valid UTF-8, such as a `bytea` or a `uuid`, or bits
  /// such as a `bit(3)`.
  Bytes(BitArray)
  /// An SQL array.
  Array(List(RecordedValue))
  /// A row, a `date` (year, month, day), a `time` (hours, minutes,
  /// seconds), a `timestamptz` or an `interval`.
  Tuple(List(RecordedValue))
  /// A row of a pool with `pog.rows_as_map`, or a `point`. The pairs are in
  /// the order of their keys.
  Map(List(#(RecordedValue, RecordedValue)))
  /// Another atom, such as `infinity` or `NaN` for a float.
  Atom(String)
}

/// A query that the recorder saw: its SQL and its parameters, in order.
pub type RecordedQuery {
  RecordedQuery(sql: String, parameters: List(RecordedValue))
}

/// The result of a recorded query.
pub type RecordedResult {
  /// The query worked. `count` is the row count of the driver, which is 0
  /// for a command with no row count, such as `CREATE TABLE`. `rows` holds
  /// the rows before they are decoded, so each decoder works on them as on
  /// a live result.
  Returned(count: Int, rows: List(RecordedValue))
  /// The query failed with this error.
  Failed(error: pog.QueryError)
}

/// One recorded query and its result.
pub type Recording {
  Recording(query: RecordedQuery, result: RecordedResult)
}

/// Writes recordings as the text of a recording file.
///
/// The recorder calls this function for each recorded query. Use it to
/// write a recording file by hand, for a result that is hard to get from a
/// real database.
///
/// ## Example
///
/// ### Write a recording by hand <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recording_by_hand.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recording.{Failed, Integer, RecordedQuery, Recording}
///
/// pub fn timeout_recording() -> String {
///   recording.to_json([
///     Recording(
///       query: RecordedQuery(
///         sql: "SELECT id, name, email FROM users WHERE id = $1",
///         parameters: [Integer(1)],
///       ),
///       result: Failed(pog.QueryTimeout),
///     ),
///   ])
/// }
/// ```
pub fn to_json(recordings: List(Recording)) -> String {
  Object([
    #("format", Inline(json.string(format_name))),
    #("version", Inline(json.int(format_version))),
    #("queries", Lines(list.map(recordings, recording_layout))),
  ])
  |> render("")
  <> "\n"
}

/// Reads the text of a recording file.
///
/// ## Returns
///
/// - `Ok(recordings)`: the recordings of the file, in order
/// - `Error(message)`: the text is not a recording file of version 1. The
///   message says what is wrong.
///
/// ## Example
///
/// ### Read the SQL of a recording file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recording_read.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recording
/// import gleam/list
/// import gleam/result
///
/// pub fn recorded_sql(file_text: String) -> Result(List(String), String) {
///   use recordings <- result.map(recording.from_json(file_text))
///   list.map(recordings, fn(entry) { entry.query.sql })
/// }
/// ```
pub fn from_json(text: String) -> Result(List(Recording), String) {
  case json.parse(text, file_decoder()) {
    Ok(recordings) -> Ok(recordings)
    Error(error) ->
      Error("This is not a recording file: " <> string.inspect(error))
  }
}

/// Writes values as a JSON array on one line, as a recording file writes
/// the parameters of a query.
///
/// The keys `sql_and_parameters` and `normalized_sql_and_parameters` of
/// `dream_postgres/recorder` use it, and so does the error of a query with
/// no recording.
///
/// ## Example
///
/// ### Write values as JSON <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recording_values.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recording.{Integer, Null, Text}
///
/// pub fn parameters_text() -> String {
///   recording.values_to_json([Integer(1), Text("Ada"), Null])
/// }
/// ```
pub fn values_to_json(values: List(RecordedValue)) -> String {
  json.to_string(json.array(values, value_to_json))
}

// The layout of a recording file: objects and lists of recordings span
// lines, and each value is on one line.
type Layout {
  Object(entries: List(#(String, Layout)))
  Lines(items: List(Layout))
  Inline(value: json.Json)
}

fn render(layout: Layout, indent: String) -> String {
  case layout {
    Inline(value) -> json.to_string(value)
    Lines([]) -> "[]"
    Lines(items) ->
      "[\n"
      <> list.map(items, fn(item) {
        indent <> "  " <> render(item, indent <> "  ")
      })
      |> string.join(",\n")
      <> "\n"
      <> indent
      <> "]"
    Object(entries) ->
      "{\n"
      <> list.map(entries, fn(entry) { render_entry(entry, indent <> "  ") })
      |> string.join(",\n")
      <> "\n"
      <> indent
      <> "}"
  }
}

fn render_entry(entry: #(String, Layout), indent: String) -> String {
  indent
  <> json.to_string(json.string(entry.0))
  <> ": "
  <> render(entry.1, indent)
}

fn recording_layout(recording: Recording) -> Layout {
  Object([
    #("sql", Inline(json.string(recording.query.sql))),
    #(
      "parameters",
      Inline(json.array(recording.query.parameters, value_to_json)),
    ),
    #("result", result_layout(recording.result)),
  ])
}

fn result_layout(result: RecordedResult) -> Layout {
  case result {
    Returned(count:, rows:) ->
      Object([
        #("count", Inline(json.int(count))),
        #("rows", Lines(list.map(rows, fn(row) { Inline(value_to_json(row)) }))),
      ])
    Failed(error) -> Inline(error_to_json(error))
  }
}

fn value_to_json(value: RecordedValue) -> json.Json {
  case value {
    Null -> json.null()
    Boolean(boolean) -> json.bool(boolean)
    Integer(integer) -> json.int(integer)
    Real(float) -> json.float(float)
    Text(text) -> json.string(text)
    Bytes(bytes) -> bytes_to_json(bytes)
    Array(values) -> json.array(values, value_to_json)
    Tuple(values) ->
      json.object([#("tuple", json.array(values, value_to_json))])
    Map(pairs) -> json.object([#("map", json.array(pairs, pair_to_json))])
    Atom(name) -> json.object([#("atom", json.string(name))])
  }
}

fn pair_to_json(pair: #(RecordedValue, RecordedValue)) -> json.Json {
  json.preprocessed_array([value_to_json(pair.0), value_to_json(pair.1)])
}

fn bytes_to_json(bytes: BitArray) -> json.Json {
  case bit_array.bit_size(bytes) % 8 {
    0 -> json.object([#("bytes", json.string(bit_array.base16_encode(bytes)))])
    _ -> bits_to_json(bits_to_hex(bytes))
  }
}

fn bits_to_json(bits: #(Int, String)) -> json.Json {
  json.object([
    #(
      "bits",
      json.object([#("size", json.int(bits.0)), #("hex", json.string(bits.1))]),
    ),
  ])
}

@external(erlang, "dream_postgres_recorder_ffi", "bits_to_hex")
fn bits_to_hex(bits: BitArray) -> #(Int, String)

@external(erlang, "dream_postgres_recorder_ffi", "hex_to_bits")
fn hex_to_bits(size: Int, hex: String) -> Result(BitArray, Nil)

fn error_to_json(error: pog.QueryError) -> json.Json {
  case error {
    pog.ConstraintViolated(message:, constraint:, detail:) ->
      json.object([
        #("error", json.string("constraint_violated")),
        #("message", json.string(message)),
        #("constraint", json.string(constraint)),
        #("detail", json.string(detail)),
      ])
    pog.PostgresqlError(code:, name:, message:) ->
      json.object([
        #("error", json.string("postgresql_error")),
        #("code", json.string(code)),
        #("name", json.string(name)),
        #("message", json.string(message)),
      ])
    pog.UnexpectedArgumentCount(expected:, got:) ->
      json.object([
        #("error", json.string("unexpected_argument_count")),
        #("expected", json.int(expected)),
        #("got", json.int(got)),
      ])
    pog.UnexpectedArgumentType(expected:, got:) ->
      json.object([
        #("error", json.string("unexpected_argument_type")),
        #("expected", json.string(expected)),
        #("got", json.string(got)),
      ])
    pog.UnexpectedResultType(errors) ->
      json.object([
        #("error", json.string("unexpected_result_type")),
        #("errors", json.array(errors, decode_error_to_json)),
      ])
    pog.QueryTimeout -> json.object([#("error", json.string("query_timeout"))])
    pog.ConnectionUnavailable ->
      json.object([#("error", json.string("connection_unavailable"))])
    pog.InterceptorFailed(reason:) ->
      json.object([
        #("error", json.string("interceptor_failed")),
        #("reason", value_to_json(reason_to_recorded(reason))),
      ])
  }
}

// The reason of `pog.InterceptorFailed` can be any term. A term that no
// `RecordedValue` holds, such as a process, is kept as its text.
fn reason_to_recorded(reason: Dynamic) -> RecordedValue {
  case to_recorded(reason) {
    Ok(value) -> value
    Error(text) -> Text(text)
  }
}

@external(erlang, "dream_postgres_recorder_ffi", "to_recorded")
fn to_recorded(term: Dynamic) -> Result(RecordedValue, String)

@external(erlang, "dream_postgres_recorder_ffi", "from_recorded")
fn from_recorded(value: RecordedValue) -> Dynamic

fn decode_error_to_json(error: decode.DecodeError) -> json.Json {
  json.object([
    #("expected", json.string(error.expected)),
    #("found", json.string(error.found)),
    #("path", json.array(error.path, json.string)),
  ])
}

fn file_decoder() -> decode.Decoder(List(Recording)) {
  use format <- decode.field("format", decode.string)
  use version <- decode.field("version", decode.int)
  use recordings <- decode.field("queries", decode.list(recording_decoder()))
  case format == format_name, version == format_version {
    True, True -> decode.success(recordings)
    False, _ -> decode.failure([], "the format " <> format_name)
    True, False -> decode.failure([], "version 1 of the format")
  }
}

fn recording_decoder() -> decode.Decoder(Recording) {
  use sql <- decode.field("sql", decode.string)
  use parameters <- decode.field("parameters", decode.list(value_decoder()))
  use result <- decode.field("result", result_decoder())
  decode.success(Recording(RecordedQuery(sql:, parameters:), result))
}

fn result_decoder() -> decode.Decoder(RecordedResult) {
  decode.one_of(returned_decoder(), [failed_decoder()])
}

fn returned_decoder() -> decode.Decoder(RecordedResult) {
  use count <- decode.field("count", decode.int)
  use rows <- decode.field("rows", decode.list(value_decoder()))
  decode.success(Returned(count:, rows:))
}

fn failed_decoder() -> decode.Decoder(RecordedResult) {
  use kind <- decode.field("error", decode.string)
  decode.map(error_decoder(kind), Failed)
}

fn error_decoder(kind: String) -> decode.Decoder(pog.QueryError) {
  case kind {
    "constraint_violated" -> {
      use message <- decode.field("message", decode.string)
      use constraint <- decode.field("constraint", decode.string)
      use detail <- decode.field("detail", decode.string)
      decode.success(pog.ConstraintViolated(message:, constraint:, detail:))
    }
    "postgresql_error" -> {
      use code <- decode.field("code", decode.string)
      use name <- decode.field("name", decode.string)
      use message <- decode.field("message", decode.string)
      decode.success(pog.PostgresqlError(code:, name:, message:))
    }
    "unexpected_argument_count" -> {
      use expected <- decode.field("expected", decode.int)
      use got <- decode.field("got", decode.int)
      decode.success(pog.UnexpectedArgumentCount(expected:, got:))
    }
    "unexpected_argument_type" -> {
      use expected <- decode.field("expected", decode.string)
      use got <- decode.field("got", decode.string)
      decode.success(pog.UnexpectedArgumentType(expected:, got:))
    }
    "unexpected_result_type" -> {
      use errors <- decode.field("errors", decode.list(decode_error_decoder()))
      decode.success(pog.UnexpectedResultType(errors))
    }
    "query_timeout" -> decode.success(pog.QueryTimeout)
    "connection_unavailable" -> decode.success(pog.ConnectionUnavailable)
    "interceptor_failed" -> {
      use reason <- decode.field("reason", value_decoder())
      decode.success(pog.InterceptorFailed(from_recorded(reason)))
    }
    _ -> decode.failure(pog.ConnectionUnavailable, "a pog.QueryError")
  }
}

fn decode_error_decoder() -> decode.Decoder(decode.DecodeError) {
  use expected <- decode.field("expected", decode.string)
  use found <- decode.field("found", decode.string)
  use path <- decode.field("path", decode.list(decode.string))
  decode.success(decode.DecodeError(expected:, found:, path:))
}

fn value_decoder() -> decode.Decoder(RecordedValue) {
  use <- decode.recursive
  decode.one_of(null_decoder(), [
    decode.map(decode.bool, Boolean),
    decode.map(decode.int, Integer),
    decode.map(decode.float, Real),
    decode.map(decode.string, Text),
    decode.map(decode.list(value_decoder()), Array),
    decode.map(decode.at(["tuple"], decode.list(value_decoder())), Tuple),
    decode.map(decode.at(["map"], decode.list(pair_decoder())), Map),
    decode.map(decode.at(["atom"], decode.string), Atom),
    decode.map(decode.at(["bytes"], hex_decoder()), Bytes),
    decode.map(decode.at(["bits"], bits_decoder()), Bytes),
  ])
}

fn null_decoder() -> decode.Decoder(RecordedValue) {
  decode.new_primitive_decoder("null", fn(value) {
    case is_json_null(value) {
      True -> Ok(Null)
      False -> Error(Null)
    }
  })
}

@external(erlang, "dream_postgres_recorder_ffi", "is_json_null")
fn is_json_null(value: Dynamic) -> Bool

fn pair_decoder() -> decode.Decoder(#(RecordedValue, RecordedValue)) {
  use key <- decode.field(0, value_decoder())
  use value <- decode.field(1, value_decoder())
  decode.success(#(key, value))
}

fn hex_decoder() -> decode.Decoder(BitArray) {
  use hex <- decode.then(decode.string)
  case bit_array.base16_decode(hex) {
    Ok(bytes) -> decode.success(bytes)
    Error(Nil) -> decode.failure(<<>>, "base 16 text")
  }
}

fn bits_decoder() -> decode.Decoder(BitArray) {
  use size <- decode.field("size", decode.int)
  use hex <- decode.field("hex", decode.string)
  case hex_to_bits(size, hex) {
    Ok(bits) -> decode.success(bits)
    Error(Nil) -> decode.failure(<<>>, "base 16 text of the size")
  }
}
