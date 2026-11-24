import dream_pog as pog
import dream_postgres/recorder

pub fn explain(query_error: pog.QueryError) -> String {
  case recorder.error(query_error) {
    Ok(recorder.NoRecording(sql:, parameters:, path:)) ->
      "Record again: " <> path <> " has no " <> sql <> " with " <> parameters
    Ok(_other) -> "The recorder failed the query"
    Error(Nil) -> "The database failed the query"
  }
}
