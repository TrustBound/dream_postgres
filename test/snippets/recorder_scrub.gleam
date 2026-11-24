//// Recorder: hide a secret before it reaches the file
////
//// The token of a session is a secret. The query transformer hides it in
//// the parameters of the INSERT, and the result transformer hides it in
//// the rows of the SELECT.

import dream_pog as pog
import dream_postgres/recorder
import dream_postgres/recording.{
  type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
}
import gleam/dynamic/decode
import gleam/list
import gleam/result

const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"

const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"

pub fn find_tokens(
  db: pog.Connection,
  user_name: String,
) -> Result(List(String), pog.QueryError) {
  pog.query(select_tokens)
  |> pog.parameter(pog.text(user_name))
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

pub fn scrubbing_builder(
  directory: String,
  name: String,
) -> recorder.RecorderBuilder {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(name)
  |> recorder.query_transformer(hide_token_parameter)
  |> recorder.result_transformer(hide_token_column)
}

// Runs in record and in playback mode, so a played-back INSERT with the
// real token still matches its recording.
fn hide_token_parameter(query: RecordedQuery) -> RecordedQuery {
  case query.sql, query.parameters {
    sql, [user_name, _token] if sql == insert_session ->
      RecordedQuery(..query, parameters: [user_name, Text("[hidden]")])
    _, _ -> query
  }
}

// Runs in record mode only: playback gives the hidden rows.
fn hide_token_column(
  query: RecordedQuery,
  result: RecordedResult,
) -> RecordedResult {
  case query.sql, result {
    sql, Returned(count:, rows:) if sql == select_tokens ->
      Returned(
        count:,
        rows: list.map(rows, fn(_row) { Tuple([Text("[hidden]")]) }),
      )
    _, _ -> result
  }
}
