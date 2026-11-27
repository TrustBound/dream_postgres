//// A matcher that gives the database error of a transfer error whose
//// cause is `DatabaseFailed`.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/transfer_error.{
  type TransferError, DatabaseFailed, NotEnough, RollbackFailed,
}
import gleam/option.{None, Some}
import gleam/string

/// Give the database error of a transfer error whose cause is
/// `DatabaseFailed`: the same kind and message, with the `PostgresError`
/// as the cause. The chain fails for each other cause.
///
/// ## Example
///
/// ```gleam
/// transaction(connection, database: DatabaseFailed, rollback_also_failed: RollbackFailed)
/// |> step(client_statements.divide_by_zero)
/// |> commit
/// |> should
/// |> be_error()
/// |> be_database_failed()
/// |> summarise_error()
/// |> be_equal("invalid 22012")
/// |> or_fail_with("Expected the division by zero")
/// ```
pub fn be_database_failed(
  result: MatchResult(Error(TransferError)),
) -> MatchResult(Error(PostgresError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> database_error_of(failure)
  }
}

fn database_error_of(
  failure: Error(TransferError),
) -> MatchResult(Error(PostgresError)) {
  case dream_errors.cause(failure) {
    Some(DatabaseFailed(database_error)) ->
      MatchOk(dream_errors.map_cause(failure, fn(_cause) { database_error }))
    Some(NotEnough(..)) | Some(RollbackFailed(..)) | None ->
      MatchFailed(AssertionFailure(
        operator: "be_database_failed",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: string.inspect(failure),
          description: "expected the cause DatabaseFailed",
        )),
      ))
  }
}
