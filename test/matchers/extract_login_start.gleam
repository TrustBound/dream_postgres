//// Starts a login with the login steps.

import dream_postgres/driver/login.{
  type LoginConfig, type LoginError, type LoginState, start,
}
import dream_postgres/driver/message.{type FrontendMessage}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{type Option, None, Some}

@external(erlang, "driver_file_ffi", "read_certificate")
fn read_certificate(name: String) -> Result(BitArray, String)

/// Gives the result of `start` for the settings, the client nonce and the
/// server certificate: the first login state and the StartupMessage, or
/// the error. `certificate_file` names a DER file in
/// `test/fixtures/channel_binding`, or is `None` for a login without TLS.
/// Fails when the file cannot be read.
///
/// ```gleam
/// new(..)
/// |> should
/// |> be_ok
/// |> extract_login_start(nonce:, certificate_file: None)
/// |> be_ok
/// |> extract_startup_message
/// |> be_equal(StartupMessage(Protocol30, "ada", [#("database", "shop")]))
/// |> or_fail_with("Expected the StartupMessage")
/// ```
pub fn extract_login_start(
  result: MatchResult(LoginConfig),
  nonce nonce: BitArray,
  certificate_file certificate_file: Option(String),
) -> MatchResult(Result(#(LoginState, FrontendMessage), LoginError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config) -> start_with(config, nonce, certificate_file)
  }
}

fn start_with(
  config: LoginConfig,
  nonce: BitArray,
  certificate_file: Option(String),
) -> MatchResult(Result(#(LoginState, FrontendMessage), LoginError)) {
  case certificate_file {
    None -> MatchOk(start(config, nonce, None))
    Some(name) -> start_with_file(config, nonce, read_certificate(name))
  }
}

fn start_with_file(
  config: LoginConfig,
  nonce: BitArray,
  certificate: Result(BitArray, String),
) -> MatchResult(Result(#(LoginState, FrontendMessage), LoginError)) {
  case certificate {
    Ok(bytes) -> MatchOk(start(config, nonce, Some(bytes)))
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "extract_login_start",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "Expected a readable certificate file",
        )),
      ))
  }
}
