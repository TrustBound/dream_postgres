//// Extracts the SQLSTATE code of a login that the server refused.

import dream_postgres/driver/connection/event.{type ConnectError, LoginRefused}
import dream_postgres/driver/login.{ServerRejectedLogin}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of the ErrorResponse to a login, for example
/// `28P01` for a wrong password. Fails for other start errors.
///
/// ```gleam
/// start(config)
/// |> should
/// |> be_error
/// |> extract_login_refusal_code
/// |> be_equal("28P01")
/// |> or_fail_with("Expected 28P01")
/// ```
pub fn extract_login_refusal_code(
  result: MatchResult(ConnectError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: ConnectError) -> MatchResult(String) {
  case error {
    LoginRefused(ServerRejectedLogin(report)) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_login_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected a login that the server rejected",
        )),
      ))
  }
}
