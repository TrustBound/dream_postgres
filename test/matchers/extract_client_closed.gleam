//// Asks a fake server whether its client closed the connection after a
//// failed connect.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/fake_server.{type FakeServer, client_closed}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Takes the result of a connect to a fake server and that server. When
/// the connect failed, waits for the server to finish with its client and
/// gives whether that client closed the connection. Fails when the connect
/// worked, or when a step of the fake server failed.
///
/// ```gleam
/// #(try(config, connect), server)
/// |> should
/// |> extract_client_closed
/// |> be_true
/// |> or_fail_with("Expected the client to close its socket")
/// ```
pub fn extract_client_closed(
  result: MatchResult(#(Result(a, e), FakeServer)),
) -> MatchResult(Bool) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(Ok(value), _server)) ->
      failure(inspect(value), "Expected the connect to fail")
    MatchOk(#(Error(_error), server)) -> closed_of(client_closed(server))
  }
}

fn closed_of(answer: Result(Bool, String)) -> MatchResult(Bool) {
  case answer {
    Ok(closed) -> MatchOk(closed)
    Error(reason) -> failure(reason, "Expected the fake server to answer")
  }
}

fn failure(actual: String, description: String) -> MatchResult(Bool) {
  MatchFailed(AssertionFailure(
    operator: "extract_client_closed",
    message: "",
    payload: Some(CustomMatcherFailure(actual:, description:)),
  ))
}
