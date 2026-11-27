//// Logs in as dream_trust on a transport connection, and gives the first
//// answer of the server.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/message.{
  type BackendMessage, Decoded, Protocol30, StartupMessage,
}
import dream_postgres/driver/transport.{
  type Connection, type TransportError, Unlisted, close, receive, send,
  server_certificate,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/servers.{database}
import gleam/option.{None}
import gleam/pair
import gleam/result.{map, replace_error, try}

/// Takes the result of `connect`. On a connection, sends a StartupMessage
/// for `dream_trust`, reads the first answer and closes the connection.
/// Gives `Ok(#(message, encrypted))`: the first message of the server, and
/// whether the connection has a server certificate, which is TLS. Gives
/// the error of the connect, the send or the receive.
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
    MatchOk(connected) -> MatchOk(try(connected, answer_and_close))
  }
}

fn answer_and_close(
  connection: Connection,
) -> Result(#(BackendMessage, Bool), TransportError) {
  let answer = first_answer(connection)
  let encrypted = server_certificate(connection) != None
  close(connection)
  answer |> map(pair.new(_, encrypted))
}

fn first_answer(
  connection: Connection,
) -> Result(BackendMessage, TransportError) {
  let startup =
    StartupMessage(Protocol30, "dream_trust", [#("database", database)])
  use bytes <- try(encode(startup) |> replace_error(Unlisted("encode")))
  use Nil <- try(send(connection, bytes))
  use answer <- try(receive(connection, 5000))
  first_message(answer)
}

fn first_message(bytes: BitArray) -> Result(BackendMessage, TransportError) {
  case decode_backend(bytes) {
    Ok(Decoded(message, _rest)) -> Ok(message)
    _other -> Error(Unlisted("decode"))
  }
}
