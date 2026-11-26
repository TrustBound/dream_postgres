//// Database query helpers
////
//// Simple utilities for extracting rows from Pog query results. Use these
//// after executing database queries to get your data out cleanly.
////
//// ## Example
////
//// ### Read the first row <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/query_first_row.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_postgres/query
//// import dream_postgres_client
////
//// pub fn find_name(
////   result: Result(
////     dream_postgres_client.Returned(String),
////     dream_postgres_client.QueryError,
////   ),
//// ) -> Result(String, String) {
////   case query.first_row(result) {
////     Ok(name) -> Ok(name)
////     Error(query.NotFound) -> Error("User not found")
////     Error(query.DatabaseError) -> Error("Database error")
////   }
//// }
//// ```

import dream_errors.{type Error, Failed}
import dream_postgres_client
import gleam/list
import gleam/result

/// Query error types
///
/// Simplified error types for query results. Converts Pog's `QueryError`
/// into a simpler two-variant type for easier error handling.
///
/// ## Variants
///
/// - `NotFound`: Query succeeded but returned no rows
/// - `DatabaseError`: Query failed (connection error, SQL error, etc.)
pub type QueryError {
  /// The query succeeded but returned no rows.
  NotFound
  /// The query failed, for example because of a connection error or an SQL
  /// error.
  DatabaseError
}

/// Extract the first row from a query result
///
/// Extracts the first row from a Pog query result. This is useful for
/// queries that should return exactly one row (e.g., "get by ID" queries).
///
/// Returns `NotFound` if the query succeeded but returned no rows, or
/// `DatabaseError` if the query itself failed.
///
/// ## Parameters
///
/// - `result`: The result from a Pog query execution
///
/// ## Returns
///
/// - `Ok(row)`: First row found
/// - `Error(NotFound)`: Query succeeded but no rows returned
/// - `Error(DatabaseError)`: Query failed (connection error, SQL error, etc.)
///
/// ## See Also
///
/// - `all_rows`: get every row
///
/// ## Example
///
/// ### Read the first row <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/query_first_row.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/query
/// import dream_postgres_client
///
/// pub fn find_name(
///   result: Result(
///     dream_postgres_client.Returned(String),
///     dream_postgres_client.QueryError,
///   ),
/// ) -> Result(String, String) {
///   case query.first_row(result) {
///     Ok(name) -> Ok(name)
///     Error(query.NotFound) -> Error("User not found")
///     Error(query.DatabaseError) -> Error("Database error")
///   }
/// }
/// ```
pub fn first_row(
  result: Result(
    dream_postgres_client.Returned(row),
    dream_postgres_client.QueryError,
  ),
) -> Result(row, QueryError) {
  case result {
    Ok(db_result) -> first_of_rows(db_result.rows)
    Error(_) -> Error(DatabaseError)
  }
}

fn first_of_rows(rows: List(row)) -> Result(row, QueryError) {
  list.first(rows)
  |> result.replace_error(NotFound)
}

/// Extract all rows from a query result
///
/// Extracts all rows from a Pog query result. This is useful for queries
/// that return multiple rows (e.g., "list all" queries).
///
/// Returns an empty list if the query succeeded but found no rows, or
/// `DatabaseError` if the query itself failed.
///
/// ## Parameters
///
/// - `result`: The result from a Pog query execution
///
/// ## Returns
///
/// - `Ok(List(row))`: All rows (may be empty)
/// - `Error(DatabaseError)`: Query failed (connection error, SQL error, etc.)
///
/// ## See Also
///
/// - `first_row`: get only the first row
///
/// ## Example
///
/// ### Read all rows <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/query_all_rows.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/query
/// import dream_postgres_client
/// import gleam/string
///
/// pub fn find_names(
///   result: Result(
///     dream_postgres_client.Returned(String),
///     dream_postgres_client.QueryError,
///   ),
/// ) -> Result(List(String), String) {
///   case query.all_rows(result) {
///     Ok(names) -> Ok(names)
///     Error(error) -> Error("Database error: " <> string.inspect(error))
///   }
/// }
/// ```
pub fn all_rows(
  result: Result(
    dream_postgres_client.Returned(row),
    dream_postgres_client.QueryError,
  ),
) -> Result(List(row), QueryError) {
  case result {
    Ok(db_result) -> Ok(db_result.rows)
    Error(_) -> Error(DatabaseError)
  }
}

/// Map a `QueryError` of this module to the shared error of the Dream
/// ecosystem
///
/// `NotFound` gives `dream_errors.NotFound`, and `DatabaseError` gives
/// `dream_errors.Failed`. The cause is `Nil`, because `DatabaseError` does
/// not keep the error of the database. To keep that error, use `execute`
/// of `dream_postgres/client` and `client.to_error`.
///
/// The message is for developers and logs. Never show it to the users of
/// an app.
///
/// ## Parameters
///
/// - `error`: The error from `first_row` or `all_rows`
///
/// ## Returns
///
/// A `dream_errors.Error(Nil)`.
///
/// ## Example
///
/// ### Map the first row to the shared error <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/query_to_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/query.{first_row, to_error}
/// import dream_postgres_client.{type QueryError, type Returned}
/// import gleam/result
///
/// pub fn find_name(
///   result: Result(Returned(String), QueryError),
/// ) -> Result(String, Error(Nil)) {
///   first_row(result)
///   |> result.map_error(to_error)
/// }
/// ```
pub fn to_error(error: QueryError) -> Error(Nil) {
  case error {
    NotFound -> dream_errors.NotFound("the query returned no rows")
    DatabaseError -> Failed("the query failed", Nil)
  }
}
