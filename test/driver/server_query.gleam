//// A test helper that runs the query steps on a logged-in connection to a
//// driver server, the way the connection process will: it sends the
//// step's messages, decodes each message of the server, gives it to the
//// step function, and sends what the step asks, until the step is done.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{
  type BackendMessage, type EncodeError, type FrontendMessage,
  type ProtocolError, Decoded, NeedMoreBytes, Protocol30,
}
import dream_postgres/driver/query.{
  type Start, type Step, type UnexpectedMessage, ConnectionEnded, Finished, Send,
  Wait,
}
import dream_postgres/driver/transport.{
  type Connection, type TransportError, NoTls, close, receive, send,
}
import dream_postgres/internal/cell.{type ServerReport}
import driver/server_login.{type LoginFailure, TestLogin, open_logged_in}
import driver/servers.{type Server}
import gleam/bit_array.{concat}
import gleam/list.{try_map}
import gleam/result.{map_error, try}

/// Why a test query failed, at the layer where it failed.
pub type QueryFailure {
  LoginFailed(failure: LoginFailure)
  TransportFailed(error: TransportError)
  EncodeFailed(error: EncodeError)
  DecodeFailed(error: ProtocolError)
  StepRefused(error: UnexpectedMessage)
  ServerEnded(report: ServerReport)
}

/// A logged-in connection, and the bytes that came but are not read yet.
pub type Session {
  Session(connection: Connection, bytes: BitArray)
}

/// A step function of `dream_postgres/driver/query`.
pub type StepFunction(state, outcome) =
  fn(state, BackendMessage) -> Result(Step(state, outcome), UnexpectedMessage)

/// Logs in as `dream` with SCRAM over plain TCP, runs `body` on the
/// session, and closes the connection.
pub fn with_session(
  server: Server,
  body: fn(Session) -> Result(value, QueryFailure),
) -> Result(value, QueryFailure) {
  let test_login =
    TestLogin(
      host: "localhost",
      tls: NoTls,
      user: "dream",
      password: "dream",
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
  use #(connection, bytes) <- try(
    open_logged_in(server, test_login) |> map_error(LoginFailed),
  )
  let value = body(Session(connection:, bytes:))
  close(connection)
  value
}

/// Runs one query step to its end, and gives its outcome and the session
/// after it.
pub fn run_step(
  session: Session,
  start: Start(state),
  step: StepFunction(state, outcome),
) -> Result(#(outcome, Session), QueryFailure) {
  use Nil <- try(send_messages(session.connection, start.messages))
  read_messages(session, start.state, step)
}

fn read_messages(
  session: Session,
  state: state,
  step: StepFunction(state, outcome),
) -> Result(#(outcome, Session), QueryFailure) {
  case decode_backend(session.bytes) {
    Ok(Decoded(message, rest)) ->
      step(state, message)
      |> map_error(StepRefused)
      |> try(next_step(Session(..session, bytes: rest), _, step))
    Ok(NeedMoreBytes) -> read_more(session, state, step)
    Error(error) -> Error(DecodeFailed(error))
  }
}

fn next_step(
  session: Session,
  query_step: Step(state, outcome),
  step: StepFunction(state, outcome),
) -> Result(#(outcome, Session), QueryFailure) {
  case query_step {
    Finished(outcome) -> Ok(#(outcome, session))
    Wait(state) -> read_messages(session, state, step)
    Send(messages, state) -> send_and_read(session, messages, state, step)
    ConnectionEnded(report, _messages) -> Error(ServerEnded(report))
  }
}

fn send_and_read(
  session: Session,
  messages: List(FrontendMessage),
  state: state,
  step: StepFunction(state, outcome),
) -> Result(#(outcome, Session), QueryFailure) {
  use Nil <- try(send_messages(session.connection, messages))
  read_messages(session, state, step)
}

fn read_more(
  session: Session,
  state: state,
  step: StepFunction(state, outcome),
) -> Result(#(outcome, Session), QueryFailure) {
  use more <- try(
    receive(session.connection, 5000) |> map_error(TransportFailed),
  )
  read_messages(
    Session(..session, bytes: <<session.bytes:bits, more:bits>>),
    state,
    step,
  )
}

fn send_messages(
  connection: Connection,
  messages: List(FrontendMessage),
) -> Result(Nil, QueryFailure) {
  use bytes <- try(try_each_encoded(messages) |> map_error(EncodeFailed))
  send(connection, bytes) |> map_error(TransportFailed)
}

fn try_each_encoded(
  messages: List(FrontendMessage),
) -> Result(BitArray, EncodeError) {
  messages
  |> try_map(encode)
  |> result.map(concat)
}
