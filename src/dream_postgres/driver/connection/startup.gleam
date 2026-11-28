//// Startup and login: connecting the socket, and the messages of the login.

import dream_postgres/driver/connection/event.{
  type ConnectError, LoginRefused, LoginRequiresTls, LoginSendFailed,
  LoginSocketFailed, LoginUndecodable, SetupTimedOut, TransportRefused,
}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/deadline.{type Deadline}
import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/login.{
  type LoginMessage, type LoginOutcome, type LoginStartError, type LoginState,
  ChannelBindingRequiresTls, Continue, LoggedIn, encode_login_message,
}
import dream_postgres/driver/message.{Decoded, NeedMoreBytes}
import dream_postgres/driver/transport.{
  type ReceiveError, type TransportError, ConnectTimedOut, ReceiveFailed,
  ReceiveTimedOut,
}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}

/// A connection after the login: the socket, the bytes after the login's
/// ReadyForQuery, and what the login gave.
pub type Session {
  Session(socket: transport.Connection, bytes: BitArray, outcome: LoginOutcome)
}

/// Connects and logs in, with the socket in passive mode. After it, the
/// socket sends its next message to this process.
pub fn open_session(config: ConnectionConfig) -> Result(Session, ConnectError) {
  let setup_deadline = deadline.from_now(config.setup_timeout_milliseconds)
  use socket <- try(
    transport.connect(config.transport, setup_deadline)
    |> map_error(setup_transport_error(_, setup_deadline)),
  )
  case log_in(socket, config, setup_deadline) {
    Ok(session) -> Ok(session)
    Error(error) -> {
      transport.close(socket)
      Error(error)
    }
  }
}

/// A step that timed out once the setup deadline had passed ran out of the
/// setup time. Any other failure is the transport's own, for example the
/// connect timeout of one TCP connect while setup time was left.
fn setup_transport_error(
  error: TransportError,
  setup_deadline: Deadline,
) -> ConnectError {
  case error, deadline.has_passed(setup_deadline) {
    ConnectTimedOut, True -> SetupTimedOut
    _, _ -> TransportRefused(error)
  }
}

fn log_in(
  socket: transport.Connection,
  config: ConnectionConfig,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  use #(state, first) <- try(
    login.start(
      config.login,
      login.random_client_nonce(),
      transport.server_certificate(socket),
    )
    |> map_error(login_start_error),
  )
  use Nil <- try(send_login_message(socket, first))
  use session <- try(login_messages(socket, state, <<>>, setup_deadline))
  transport.receive_next(socket)
  |> map_error(LoginSocketFailed)
  |> result.replace(session)
}

fn login_start_error(error: LoginStartError) -> ConnectError {
  case error {
    ChannelBindingRequiresTls -> LoginRequiresTls
  }
}

fn login_messages(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      login.step(state, message)
      |> map_error(LoginRefused)
      |> try(login_step(socket, _, rest, setup_deadline))
    Ok(NeedMoreBytes) -> more_login_bytes(socket, state, bytes, setup_deadline)
    Error(error) -> Error(LoginUndecodable(error))
  }
}

fn login_step(
  socket: transport.Connection,
  step: login.LoginStep,
  rest: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  case step {
    LoggedIn(outcome) -> Ok(Session(socket:, bytes: rest, outcome:))
    Continue(state:, reply: Some(message)) -> {
      use Nil <- try(send_login_message(socket, message))
      login_messages(socket, state, rest, setup_deadline)
    }
    Continue(state:, reply: None) ->
      login_messages(socket, state, rest, setup_deadline)
  }
}

fn more_login_bytes(
  socket: transport.Connection,
  state: LoginState,
  bytes: BitArray,
  setup_deadline: Deadline,
) -> Result(Session, ConnectError) {
  use more <- try(
    transport.receive(socket, deadline.time_left(setup_deadline))
    |> map_error(login_receive_error),
  )
  login_messages(socket, state, <<bytes:bits, more:bits>>, setup_deadline)
}

/// A login message cannot fail to encode: the login checks each value
/// that it holds (see `login.encode_login_message`).
fn send_login_message(
  socket: transport.Connection,
  message: LoginMessage,
) -> Result(Nil, ConnectError) {
  transport.send(socket, encode_login_message(message))
  |> map_error(LoginSendFailed)
}

/// The receive waits for the time left of the setup, so its timeout is
/// the end of the setup.
fn login_receive_error(error: ReceiveError) -> ConnectError {
  case error {
    ReceiveTimedOut -> SetupTimedOut
    ReceiveFailed(error) -> LoginSocketFailed(error)
  }
}
