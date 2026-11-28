//// A test helper that logs in to a driver server with the transport and
//// the login steps, the way the connection process will. It reads the
//// server's bytes, decodes each message, gives it to `login.step`, and
//// sends each reply, until the login is done or fails.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/login.{
  type ClientNonce, type ClientNonceError, type LoginError, type LoginMessage,
  type LoginOutcome, type LoginStartError, type LoginState, Continue, LoggedIn,
  encode_login_message,
}
import dream_postgres/driver/login/login_config.{
  type ChannelBindingSetting, type ConfigError,
}
import dream_postgres/driver/message.{
  type ProtocolError, type ProtocolVersion, Decoded, NeedMoreBytes,
}
import dream_postgres/driver/transport.{
  type Connection, type ReceiveError, type SendError, type Tls,
  type TransportError, TransportConfig, address, close, receive, send,
  server_certificate,
}
import driver/servers.{type Server}
import fixtures/transport_connect.{connect_with_minute_deadline}
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result.{map_error, try}

/// Why a test login failed, at the layer where it failed.
pub type LoginFailure {
  AddressRefused
  ConfigRefused(error: ConfigError)
  TransportFailed(error: TransportError)
  SendRefused(error: SendError)
  ReceiveRefused(error: ReceiveError)
  DecodeFailed(error: ProtocolError)
  NonceRefused(error: ClientNonceError)
  StartFailed(error: LoginStartError)
  LoginFailed(error: LoginError)
}

/// One test login.
pub type TestLogin {
  TestLogin(
    host: String,
    tls: Tls,
    user: String,
    password: String,
    channel_binding: ChannelBindingSetting,
    protocol_version: ProtocolVersion,
  )
}

/// Logs in to the server, then closes the connection.
pub fn log_in(
  server: Server,
  test_login: TestLogin,
) -> Result(LoginOutcome, LoginFailure) {
  log_in_with(server, test_login, login.random_client_nonce())
}

/// Logs in with the given client nonce bytes, then closes the connection.
/// Fails with `NonceRefused` when `login.client_nonce` refuses the bytes.
pub fn log_in_with_nonce(
  server: Server,
  test_login: TestLogin,
  nonce_bytes: BitArray,
) -> Result(LoginOutcome, LoginFailure) {
  use nonce <- try(login.client_nonce(nonce_bytes) |> map_error(NonceRefused))
  log_in_with(server, test_login, nonce)
}

fn log_in_with(
  server: Server,
  test_login: TestLogin,
  nonce: ClientNonce,
) -> Result(LoginOutcome, LoginFailure) {
  use config <- try(login_config(test_login))
  use connection <- try(open(server, test_login))
  let outcome = run_login(connection, config, nonce)
  close(connection)
  outcome |> result.map(pair.first)
}

/// Logs in and keeps the connection open. The caller closes it.
///
/// The result is the connection and the bytes that came after the
/// ReadyForQuery of the login.
pub fn open_logged_in(
  server: Server,
  test_login: TestLogin,
) -> Result(#(Connection, BitArray), LoginFailure) {
  use config <- try(login_config(test_login))
  use connection <- try(open(server, test_login))
  case run_login(connection, config, login.random_client_nonce()) {
    Ok(#(_outcome, rest)) -> Ok(#(connection, rest))
    Error(failure) -> close_with(connection, failure)
  }
}

fn close_with(
  connection: Connection,
  failure: LoginFailure,
) -> Result(a, LoginFailure) {
  close(connection)
  Error(failure)
}

fn login_config(
  test_login: TestLogin,
) -> Result(login_config.LoginConfig, LoginFailure) {
  login_config.new(
    user: test_login.user,
    database: servers.database,
    password: login_config.password(test_login.password),
    parameters: [],
    channel_binding: test_login.channel_binding,
    protocol_version: test_login.protocol_version,
  )
  |> map_error(ConfigRefused)
}

fn open(
  server: Server,
  test_login: TestLogin,
) -> Result(Connection, LoginFailure) {
  use checked <- try(
    address(test_login.host, server.port)
    |> result.replace_error(AddressRefused),
  )
  connect_with_minute_deadline(TransportConfig(
    checked,
    test_login.tls,
    5000,
    5000,
  ))
  |> map_error(TransportFailed)
}

fn run_login(
  connection: Connection,
  config: login_config.LoginConfig,
  nonce: ClientNonce,
) -> Result(#(LoginOutcome, BitArray), LoginFailure) {
  use #(state, first) <- try(
    login.start(config, nonce, server_certificate(connection))
    |> map_error(StartFailed),
  )
  use Nil <- try(send_message(connection, first))
  read_messages(connection, state, <<>>)
}

fn read_messages(
  connection: Connection,
  state: LoginState,
  bytes: BitArray,
) -> Result(#(LoginOutcome, BitArray), LoginFailure) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      login.step(state, message)
      |> map_error(LoginFailed)
      |> try(next_step(connection, _, rest))
    Ok(NeedMoreBytes) -> read_more(connection, state, bytes)
    Error(error) -> Error(DecodeFailed(error))
  }
}

fn next_step(
  connection: Connection,
  login_step: login.LoginStep,
  rest: BitArray,
) -> Result(#(LoginOutcome, BitArray), LoginFailure) {
  case login_step {
    LoggedIn(outcome) -> Ok(#(outcome, rest))
    Continue(state:, reply:) -> reply_and_read(connection, state, reply, rest)
  }
}

fn reply_and_read(
  connection: Connection,
  state: LoginState,
  reply: Option(LoginMessage),
  rest: BitArray,
) -> Result(#(LoginOutcome, BitArray), LoginFailure) {
  use Nil <- try(send_reply(connection, reply))
  read_messages(connection, state, rest)
}

fn send_reply(
  connection: Connection,
  reply: Option(LoginMessage),
) -> Result(Nil, LoginFailure) {
  case reply {
    Some(message) -> send_message(connection, message)
    None -> Ok(Nil)
  }
}

fn read_more(
  connection: Connection,
  state: LoginState,
  bytes: BitArray,
) -> Result(#(LoginOutcome, BitArray), LoginFailure) {
  use more <- try(receive(connection, 5000) |> map_error(ReceiveRefused))
  read_messages(connection, state, <<bytes:bits, more:bits>>)
}

fn send_message(
  connection: Connection,
  message: LoginMessage,
) -> Result(Nil, LoginFailure) {
  send(connection, encode_login_message(message)) |> map_error(SendRefused)
}
