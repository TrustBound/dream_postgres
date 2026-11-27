//// Extracts the violation of a connection that the server broke the protocol
//// on.

import dream_postgres/driver/connection.{
  type RequestFailure, type Violation, ProtocolViolation,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the violation of `ProtocolViolation`, whatever it is. Fails for
/// other errors.
///
/// ```gleam
/// copy_from(connection, "COPY t FROM STDIN", 5000, send_across_violation(_, proxy))
/// |> should
/// |> be_error
/// |> extract_copy_driver_error
/// |> extract_protocol_violation
/// |> or_fail_with("Expected the violation")
/// ```
pub fn extract_protocol_violation(
  result: MatchResult(RequestFailure),
) -> MatchResult(Violation) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> violation_of(value)
  }
}

fn violation_of(value: RequestFailure) -> MatchResult(Violation) {
  case value {
    ProtocolViolation(violation) -> MatchOk(violation)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_protocol_violation",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(value),
          description: "Expected ProtocolViolation",
        )),
      ))
  }
}
