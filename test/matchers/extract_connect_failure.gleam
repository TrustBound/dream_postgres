//// Extracts the connect error of a hold that got no connection.

import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/pool/pool_failure.{type HoldError, ConnectFailed}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the connect error of `ConnectFailed`. Fails for another hold
/// error.
///
/// ```gleam
/// pool_holds.hold(pool, 5000, backend_pid)
/// |> should
/// |> be_error
/// |> extract_connect_failure
/// |> extract_login_refusal_code
/// |> be_equal("28P01")
/// |> or_fail_with("Expected the login refusal 28P01")
/// ```
pub fn extract_connect_failure(
  result: MatchResult(HoldError),
) -> MatchResult(ConnectError) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> connect_error_of(error)
  }
}

fn connect_error_of(error: HoldError) -> MatchResult(ConnectError) {
  case error {
    ConnectFailed(connect_error) -> MatchOk(connect_error)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_connect_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ConnectFailed",
        )),
      ))
  }
}
