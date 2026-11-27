//// Opens transport connections for the tests whose subject is not the
//// setup deadline, and reads the first answer of a login.

import dream_postgres/driver/deadline
import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/message.{type BackendMessage, Decoded}
import dream_postgres/driver/transport.{
  type Connection, type TransportConfig, type TransportError, close, receive,
  send, server_certificate,
}
import driver/servers.{database}
import fixtures/login_message_bytes.{startup_message_bytes}
import gleam/option.{None}
import gleam/result.{map_error, try}
import gleam/string.{inspect}

/// What a login as `dream_trust` got: the first message of the server,
/// and whether the connection has a server certificate, which is TLS.
pub type StartupAnswer {
  StartupAnswer(message: BackendMessage, encrypted: Bool)
}

/// Opens a connection whose setup deadline is a minute away, so only the
/// connect timeout of the settings bounds each step.
pub fn connect_with_minute_deadline(
  config: TransportConfig,
) -> Result(Connection, TransportError) {
  transport.connect(config, deadline.from_now(60_000))
}

/// Opens a connection with `config`, logs in as `dream_trust`, reads the
/// first answer and closes the connection. An error names the step that
/// failed.
pub fn connect_and_answer(
  config: Result(TransportConfig, error),
) -> Result(StartupAnswer, String) {
  use config <- try(config |> map_error(inspect))
  use connection <- try(
    connect_with_minute_deadline(config) |> map_error(inspect),
  )
  read_startup_answer(connection)
}

/// Sends a StartupMessage for `dream_trust` on `connection`, reads the
/// first answer and closes the connection.
pub fn read_startup_answer(
  connection: Connection,
) -> Result(StartupAnswer, String) {
  let answer = first_answer(connection)
  let encrypted = server_certificate(connection) != None
  close(connection)
  use message <- result.map(answer)
  StartupAnswer(message:, encrypted:)
}

fn first_answer(connection: Connection) -> Result(BackendMessage, String) {
  let startup =
    startup_message_bytes(0, "dream_trust", [#("database", database)])
  use Nil <- try(send(connection, startup) |> map_error(inspect))
  use answer <- try(receive(connection, 5000) |> map_error(inspect))
  first_message(answer)
}

fn first_message(bytes: BitArray) -> Result(BackendMessage, String) {
  case decode_backend(bytes) {
    Ok(Decoded(message, _rest)) -> Ok(message)
    other -> Error(inspect(other))
  }
}
