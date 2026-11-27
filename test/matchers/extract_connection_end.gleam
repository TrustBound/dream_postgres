//// Takes the end of the connection out of a request failure.

import dream_postgres/driver/connection.{
  type ConnectionEnd, type RequestFailure, ConnectionEnded,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the end of a `ConnectionEnded`. Fails for another request
/// failure.
///
/// ```gleam
/// answer
/// |> should
/// |> be_error
/// |> extract_copy_failure
/// |> extract_connection_end
/// |> extract_ending_report
/// |> extract_report_code
/// |> be_equal("57P01")
/// |> or_fail_with("Expected the server to end the session")
/// ```
pub fn extract_connection_end(
  result: MatchResult(RequestFailure),
) -> MatchResult(ConnectionEnd) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> end_of(failure)
  }
}

fn end_of(failure: RequestFailure) -> MatchResult(ConnectionEnd) {
  case failure {
    ConnectionEnded(end) -> MatchOk(end)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_connection_end",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(failure),
          description: "Expected ConnectionEnded",
        )),
      ))
  }
}
