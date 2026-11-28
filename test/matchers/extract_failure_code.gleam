//// Extracts the SQLSTATE code of a query failure.

import dream_postgres/driver/query/step.{
  type Failure, CopyNotSupported, ServerError,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{None, Some}

/// Gives the SQLSTATE code of the ErrorResponse of a failure: of a server
/// error, or of the answer to a refused COPY. Fails for a refused COPY
/// that came with no ErrorResponse.
///
/// ```gleam
/// outcome
/// |> should
/// |> extract_outcome_result
/// |> be_error
/// |> extract_failure_code
/// |> be_equal("42P01")
/// |> or_fail_with("Expected 42P01")
/// ```
pub fn extract_failure_code(
  result: MatchResult(Failure),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(failure) -> code_of(failure)
  }
}

fn code_of(failure: Failure) -> MatchResult(String) {
  case failure {
    ServerError(report) -> MatchOk(report.code)
    CopyNotSupported(Some(report)) -> MatchOk(report.code)
    CopyNotSupported(None) ->
      MatchFailed(AssertionFailure(
        operator: "extract_failure_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "CopyNotSupported(None)",
          description: "Expected a failure with an ErrorResponse",
        )),
      ))
  }
}
