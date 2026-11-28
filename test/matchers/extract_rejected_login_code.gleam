//// Extracts the SQLSTATE code of a login that the server refused.

import dream_postgres/driver/login.{ServerRejectedLogin}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/server_login.{type LoginFailure, LoginFailed}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of the ErrorResponse that refused the login.
/// Fails when the login failed in any other way.
///
/// ```gleam
/// log_in(server, test_login)
/// |> should
/// |> be_error
/// |> extract_rejected_login_code
/// |> be_equal("28P01")
/// |> or_fail_with("Expected the SQLSTATE 28P01")
/// ```
pub fn extract_rejected_login_code(
  result: MatchResult(LoginFailure),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(login_failure) -> code_of(login_failure)
  }
}

fn code_of(login_failure: LoginFailure) -> MatchResult(String) {
  case login_failure {
    LoginFailed(ServerRejectedLogin(report)) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_rejected_login_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(login_failure),
          description: "Expected a login that the server refused",
        )),
      ))
  }
}
