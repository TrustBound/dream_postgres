//// The keys of `recorder.match_on`: what a recorder makes of each request
//// to check, in playback, that the request is the next request of the
//// recording. A recorder makes the key after its own interceptors, so a
//// key holds the placeholders of `normalize`, not the random values.
//// The app can give its own `fn(Request) -> String`, for example one
//// that uses only the name of the query.
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
  type Parameter, type Request, CopyFrom, CopyTo, Sql, Statement,
}
import dream_postgres/internal/cell.{type Cell, Binary, Null, Text}
import dream_postgres/internal/copy_request.{type RowFeed}
import dream_postgres/internal/query.{WrittenCell, WrittenSecret}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// The key of the kind, the SQL, and each written parameter or row of the
/// request. A secret parameter counts only by its position and its codec,
/// so any value of the same codec matches it. The default of a recorder.
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
pub fn sql_and_parameters(request: Request) -> String {
  let parameter_lines =
    list.index_map(request.parameters, fn(parameter, position) {
      "$" <> int.to_string(position + 1) <> " " <> parameter_text(parameter)
    })
  let row_lines = case request.kind {
    CopyFrom(rows:, ..) ->
      feed_rows(rows, [])
      |> list.index_map(fn(row, number) {
        "row "
        <> int.to_string(number + 1)
        <> " "
        <> string.join(list.map(row, parameter_text), ", ")
      })
    Statement | Sql | CopyTo -> []
  }
  string.join(
    [sql_only(request), ..list.append(parameter_lines, row_lines)],
    "\n",
  )
}

/// The key of the kind and the SQL of the request: the parameters and the
/// rows do not count.
///
/// ### Match on the SQL only <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_sql_only_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_only}
///
/// /// A recorder that takes any parameters of the recorded SQL, for a test
/// /// whose parameters change in each run.
/// pub fn start_sql_only_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_list.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_only)
///   |> start
/// }
/// ```
pub fn sql_only(request: Request) -> String {
  kind_name(request) <> "\n" <> request.sql
}

fn kind_name(request: Request) -> String {
  case request.kind {
    Statement -> "statement"
    Sql -> "sql"
    CopyFrom(..) -> "copy_from"
    CopyTo -> "copy_to"
  }
}

fn parameter_text(parameter: Parameter) -> String {
  case query.written(parameter) {
    Some(WrittenCell(type_description:, cell:)) ->
      type_description.name <> " " <> cell_text(cell)
    Some(WrittenSecret(..)) -> "secret " <> query.codec_name(parameter)
    None -> "not written " <> query.codec_name(parameter)
  }
}

fn cell_text(cell: Cell) -> String {
  case cell {
    Binary(bytes:) -> "binary " <> bit_array.base16_encode(bytes)
    Text(bytes:) -> "text " <> bit_array.base16_encode(bytes)
    Null -> "null"
  }
}

fn feed_rows(
  rows: RowFeed,
  read: List(List(Parameter)),
) -> List(List(Parameter)) {
  case copy_request.next_row(rows) {
    Some(#(values, rest)) -> feed_rows(rest, [values, ..read])
    None -> list.reverse(read)
  }
}
