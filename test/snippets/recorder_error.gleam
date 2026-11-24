import dream_postgres/recorder
import dream_postgres_client

pub fn explain(query_error: dream_postgres_client.QueryError) -> String {
  case recorder.error(query_error) {
    Ok(recorder.NoRecording(sql:, parameters:, path:, ..)) ->
      "Record again: " <> path <> " has no " <> sql <> " with " <> parameters
    Ok(_other) -> "The recorder failed the query"
    Error(Nil) -> "The database failed the query"
  }
}
