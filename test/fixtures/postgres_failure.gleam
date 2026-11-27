//// Failures of the package, with a reason, for the tests of the mapping to
//// Dream errors.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError, type Reason, PostgresError}
import gleam/option.{None, Some}

/// The failure of the unnamed query `select 1` for `reason`.
///
/// ## Example
///
/// ```gleam
/// postgres_failure.with_reason(QueryTimeout)
/// // -> PostgresError(query_name: None, sql: Some("select 1"), reason: QueryTimeout)
/// ```
pub fn with_reason(reason: Reason) -> PostgresError {
  PostgresError(query_name: None, sql: Some("select 1"), reason:)
}

/// The Dream error of a failure for `reason` with no query, as an event or
/// a listener message of the client carries it.
///
/// ## Example
///
/// ```gleam
/// postgres_failure.without_query(PoolStopped)
/// // -> Unavailable("the pool is stopped", PostgresError(None, None, PoolStopped))
/// ```
pub fn without_query(reason: Reason) -> Error(PostgresError) {
  PostgresError(query_name: None, sql: None, reason:)
  |> error.to_dream_error
}
