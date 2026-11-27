//// Extracts the driver error of a COPY that failed in the driver or on the
//// server.

import dream_postgres/driver/connection.{
  type CopyError, type DriverError, DriverFailed,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the error of `DriverFailed`. Fails for a COPY that the app's
/// function failed.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, send_bad_row)
/// |> should
/// |> be_error
/// |> extract_copy_driver_error
/// |> extract_driver_error_code
/// |> be_equal("22P02")
/// |> or_fail_with("Expected the server's 22P02")
/// ```
pub fn extract_copy_driver_error(
  result: MatchResult(CopyError(reason)),
) -> MatchResult(DriverError) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> error_of(value)
  }
}

fn error_of(value: CopyError(reason)) -> MatchResult(DriverError) {
  case value {
    DriverFailed(error) -> MatchOk(error)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_copy_driver_error",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(value),
          description: "Expected DriverFailed",
        )),
      ))
  }
}
