//// Starts a login with the login steps.

import dream_postgres/driver/login.{
  type ClientNonce, type LoginConfig, type LoginMessage, type LoginStartError,
  type LoginState, client_nonce, start,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{type Option, None, Some}

@external(erlang, "driver_file_ffi", "read_certificate")
fn read_certificate(name: String) -> Result(BitArray, String)

/// Gives the result of `start` for the settings, the client nonce and the
/// server certificate: the first login state and the StartupMessage, or
/// the error. `nonce` has `shortest_client_nonce` bytes or more.
/// `certificate_file` names a DER file in
/// `test/fixtures/channel_binding`, or is `None` for a login without TLS.
/// Fails when the nonce is too short or the file cannot be read.
///
/// ```gleam
/// new(..)
/// |> should
/// |> be_ok
/// |> extract_login_start(nonce:, certificate_file: None)
/// |> be_ok
/// |> extract_startup_message
/// |> be_equal(startup_message_bytes(0, "ada", [#("database", "shop")]))
/// |> or_fail_with("Expected the StartupMessage")
/// ```
pub fn extract_login_start(
  result: MatchResult(LoginConfig),
  nonce nonce: BitArray,
  certificate_file certificate_file: Option(String),
) -> MatchResult(Result(#(LoginState, LoginMessage), LoginStartError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config) ->
      start_with_nonce(config, client_nonce(nonce), certificate_file)
  }
}

fn start_with_nonce(
  config: LoginConfig,
  nonce: Result(ClientNonce, a),
  certificate_file: Option(String),
) -> MatchResult(Result(#(LoginState, LoginMessage), LoginStartError)) {
  case nonce {
    Ok(nonce) -> start_with(config, nonce, certificate_file)
    Error(_too_short) ->
      MatchFailed(AssertionFailure(
        operator: "extract_login_start",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: "a client nonce that is too short",
          description: "Expected a client nonce of 18 bytes or more",
        )),
      ))
  }
}

fn start_with(
  config: LoginConfig,
  nonce: ClientNonce,
  certificate_file: Option(String),
) -> MatchResult(Result(#(LoginState, LoginMessage), LoginStartError)) {
  case certificate_file {
    None -> MatchOk(start(config, nonce, None))
    Some(name) -> start_with_file(config, nonce, read_certificate(name))
  }
}

fn start_with_file(
  config: LoginConfig,
  nonce: ClientNonce,
  certificate: Result(BitArray, String),
) -> MatchResult(Result(#(LoginState, LoginMessage), LoginStartError)) {
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
