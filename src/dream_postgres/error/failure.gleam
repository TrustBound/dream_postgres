//// The `Error(PostgresError)` of a failure, with the name and the SQL of
//// the query that failed, if there is one.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError, type Reason}
import gleam/option.{type Option, None}

pub fn failure(
  query_name: Option(String),
  sql: Option(String),
  reason: Reason,
) -> Error(PostgresError) {
  error.PostgresError(query_name:, sql:, reason:)
  |> error.postgres_error_to_dream_error
}

/// The failure of a call that has no query, such as a bad config.
pub fn failure_with_no_query(reason: Reason) -> Error(PostgresError) {
  failure(None, None, reason)
}
