//// Logs in as dream_trust on a transport connection, and gives the first
//// answer of the server.

import dream_postgres/driver/transport.{type Connection, type TransportError}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/transport_connect.{type StartupAnswer, read_startup_answer}
import gleam/option.{Some}

/// Takes the result of `connect`. On a connection, sends a StartupMessage
/// for `dream_trust`, reads the first answer and closes the connection.
/// Gives `Ok(StartupAnswer)`, or the error of the connect. Fails when the
/// send, the receive or the decode fails.
///
/// ```gleam
/// connect(config)
/// |> should
/// |> extract_startup_answer
/// |> be_error
/// |> be_equal(TlsFailed(HostNameMismatch))
/// |> or_fail_with("Expected the connect error")
/// ```
pub fn extract_startup_answer(
  result: MatchResult(Result(Connection, TransportError)),
) -> MatchResult(Result(StartupAnswer, TransportError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connected) -> answer_of(connected)
  }
}

fn answer_of(
  connected: Result(Connection, TransportError),
) -> MatchResult(Result(StartupAnswer, TransportError)) {
  case connected {
    Ok(connection) -> answer_and_close(connection)
    Error(error) -> MatchOk(Error(error))
  }
}

fn answer_and_close(
  connection: Connection,
) -> MatchResult(Result(StartupAnswer, TransportError)) {
  case read_startup_answer(connection) {
    Ok(answer) -> MatchOk(Ok(answer))
    Error(text) ->
      MatchFailed(AssertionFailure(
        operator: "extract_startup_answer",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: text,
          description: "Expected a first answer of the server",
        )),
      ))
  }
}
