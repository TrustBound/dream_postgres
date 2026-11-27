//// Logs in as dream_trust on a transport connection, and gives the first
//// answer of the server.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/message.{
  type BackendMessage, Decoded, Protocol30, StartupMessage,
}
import dream_postgres/driver/transport.{
  type Connection, type TransportError, close, receive, send, server_certificate,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/servers.{database}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}
import gleam/string.{inspect}

/// Takes the result of `connect`. On a connection, sends a StartupMessage
/// for `dream_trust`, reads the first answer and closes the connection.
/// Gives `Ok(#(message, encrypted))`: the first message of the server, and
/// whether the connection has a server certificate, which is TLS. Gives
/// the error of the connect. Fails when the send, the receive or the
/// decode fails.
///
/// ```gleam
/// connect(config)
/// |> should
/// |> extract_startup_answer
/// |> be_ok
/// |> be_equal(#(AuthenticationOk, True))
/// |> or_fail_with("Expected AuthenticationOk over TLS")
/// ```
pub fn extract_startup_answer(
  result: MatchResult(Result(Connection, TransportError)),
) -> MatchResult(Result(#(BackendMessage, Bool), TransportError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connected) -> answer_of(connected)
  }
}

fn answer_of(
  connected: Result(Connection, TransportError),
) -> MatchResult(Result(#(BackendMessage, Bool), TransportError)) {
  case connected {
    Ok(connection) -> answer_and_close(connection)
    Error(error) -> MatchOk(Error(error))
  }
}

fn answer_and_close(
  connection: Connection,
) -> MatchResult(Result(#(BackendMessage, Bool), TransportError)) {
  let answer = first_answer(connection)
  let encrypted = server_certificate(connection) != None
  close(connection)
  case answer {
    Ok(message) -> MatchOk(Ok(#(message, encrypted)))
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

fn first_answer(connection: Connection) -> Result(BackendMessage, String) {
  let startup =
    StartupMessage(Protocol30, "dream_trust", [#("database", database)])
  use bytes <- try(encode(startup) |> map_error(inspect))
  use Nil <- try(send(connection, bytes) |> map_error(inspect))
  use answer <- try(receive(connection, 5000) |> map_error(inspect))
  first_message(answer)
}

fn first_message(bytes: BitArray) -> Result(BackendMessage, String) {
  case decode_backend(bytes) {
    Ok(Decoded(message, _rest)) -> Ok(message)
    other -> Error(inspect(other))
  }
}
