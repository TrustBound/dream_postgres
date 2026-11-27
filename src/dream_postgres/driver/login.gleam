//// The login of a PostgreSQL connection, as a state machine of pure
//// functions: from the StartupMessage to the first ReadyForQuery.
////
//// The caller owns the socket. `new` checks the login settings before any
//// connection is made. After the connection (and its TLS, if any) is up,
//// `start` gives the StartupMessage. Then the caller gives each message of
//// the server to `step`, and sends the reply that `step` gives, until
//// `step` gives `LoggedIn` or an error.
////
//// The login methods are: no password, a cleartext password, MD5, and
//// SCRAM-SHA-256 (with SCRAM-SHA-256-PLUS over TLS). Kerberos V5, GSSAPI and
//// SSPI are errors that name the method.
////
//// No value of this module holds the password as a string: `Password` holds
//// a function that gives it, and a function prints without its value. So
//// `string.inspect`, the status of a process and a crash report cannot
//// show it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/channel_binding.{
  type CertificateError, server_end_point_hash,
}
import dream_postgres/driver/crypto.{Md5, hash}
import dream_postgres/driver/message.{
  type BackendMessage, type FrontendMessage, type ProtocolVersion,
  AuthenticationCleartextPassword, AuthenticationGss, AuthenticationKerberosV5,
  AuthenticationMd5Password, AuthenticationOk, AuthenticationSasl,
  AuthenticationSaslContinue, AuthenticationSaslFinal, AuthenticationSspi,
  BackendKeyData, ErrorResponse, NegotiateProtocolVersion, NoticeResponse,
  ParameterStatus, PasswordMessage, Protocol30, Protocol32, ReadyForQuery,
  SaslInitialResponse, SaslResponse, StartupMessage,
}
import dream_postgres/driver/scram.{
  type ChannelBinding, type ClientFinal, type ClientFirst, type ScramError,
  ClientWithoutChannelBinding, ServerEndPoint, ServerWithoutChannelBinding,
  client_final, client_final_message, client_first, client_first_message,
  verify_server_final,
}
import dream_postgres/internal/cell.{type ServerReport, type TransactionStatus}
import gleam/bit_array.{base16_encode, byte_size}
import gleam/bool.{guard}
import gleam/dict.{type Dict}
import gleam/list.{append, contains, filter, reverse, try_each, try_fold}
import gleam/option.{type Option, None, Some}
import gleam/result.{map, map_error, try, unwrap}
import gleam/set.{type Set}
import gleam/string.{lowercase, to_graphemes}

/// The `application_name` that the login sends when the caller gives none.
pub const default_application_name = "dream_postgres"

/// The fewest random bytes of a SCRAM client nonce. libpq uses 18
/// (`SCRAM_RAW_NONCE_LEN`).
pub const shortest_client_nonce = 18

const scram_mechanism = "SCRAM-SHA-256"

const scram_plus_mechanism = "SCRAM-SHA-256-PLUS"

/// A password, or none, kept in a function so that no value prints it.
pub opaque type Password {
  Password(read: fn() -> String)
  NoPassword
}

/// When the login binds SCRAM to the TLS connection. The settings are the
/// ones of libpq's `channel_binding` connection parameter.
pub type ChannelBindingSetting {
  /// Never use channel binding.
  DisableChannelBinding
  /// Use channel binding when the connection has TLS and the server offers
  /// SCRAM-SHA-256-PLUS. This is libpq's default.
  PreferChannelBinding
  /// Log in only with channel binding: the connection must have TLS, and
  /// the server must offer SCRAM-SHA-256-PLUS. Any other login request of
  /// the server is an error, and no password is sent for it.
  RequireChannelBinding
}

/// The checked settings of a login. Only `new` makes one.
pub opaque type LoginConfig {
  LoginConfig(
    user: String,
    password: Password,
    parameters: List(#(String, String)),
    channel_binding: ChannelBindingSetting,
    protocol_version: ProtocolVersion,
  )
}

/// Why `new` refuses the login settings.
pub type ConfigError {
  /// The user name is empty.
  EmptyUser
  /// The password holds a zero byte, which would end it early.
  ZeroByteInPassword
  /// A parameter name or value holds a zero byte. `user` and `database`
  /// are parameters too.
  ZeroByteInParameter(name: String)
  /// A parameter name is empty, which would end the parameter list early.
  EmptyParameterName
  /// A parameter name is given two times, or is `user` or `database`, which
  /// `new` takes as their own arguments. Names compare without case.
  DuplicateParameter(name: String)
  /// A `client_encoding` other than UTF-8. Every text of the driver is
  /// UTF-8.
  UnsupportedClientEncoding(value: String)
}

/// A login method of the server.
pub type LoginMethod {
  /// The server lets the user in with no password.
  TrustLogin
  /// A cleartext password.
  CleartextLogin
  /// An MD5 hash of the password.
  Md5Login
  /// A SCRAM mechanism: `SCRAM-SHA-256` or `SCRAM-SHA-256-PLUS`.
  ScramLogin(mechanism: String)
  /// SASL, with the mechanisms that the server offers.
  SaslLogin(mechanisms: List(String))
  /// Kerberos V5.
  KerberosV5Login
  /// GSSAPI.
  GssLogin
  /// SSPI.
  SspiLogin
}

/// Why a login fails.
pub type LoginError {
  /// The server sent an ErrorResponse, for example `28P01` for a wrong
  /// password, with every field that it sent.
  ServerRejectedLogin(report: ServerReport)
  /// A message that the login does not expect at this step.
  UnexpectedMessage(message: BackendMessage)
  /// The server asks for a login method that the driver does not support.
  UnsupportedLoginMethod(method: LoginMethod)
  /// The server asks for a password, and the settings have none, or an
  /// empty one.
  PasswordRequired(method: LoginMethod)
  /// The password function gave a password that `new` would refuse.
  InvalidConfig(error: ConfigError)
  /// The client nonce has fewer than `shortest_client_nonce` bytes.
  ClientNonceTooShort(length: Int)
  /// The setting is `RequireChannelBinding`, and the connection has no
  /// TLS.
  ChannelBindingRequiresTls
  /// The setting is `RequireChannelBinding`, and the server asks for a
  /// login method that does not bind to the channel.
  ChannelBindingNotOffered(method: LoginMethod)
  /// The server offers SCRAM-SHA-256-PLUS on a connection with no TLS.
  /// libpq stops here too: something between the client and the server
  /// may have removed the TLS.
  ChannelBindingOfferedWithoutTls
  /// The server certificate gives no channel binding data.
  CertificateHashFailed(error: CertificateError)
  /// The SCRAM exchange failed, for example on a wrong server signature.
  ScramFailed(error: ScramError)
  /// The server answers with a protocol version that the driver does not
  /// speak, or a newer one than the login asked.
  UnsupportedProtocolVersion(major_version: Int, minor_version: Int)
}

/// The process ID and the secret key that a CancelRequest needs.
pub type CancelKey {
  CancelKey(process_id: Int, secret_key: BitArray)
}

/// What the server told the client during a login that worked.
pub type LoginOutcome {
  LoginOutcome(
    /// Each ParameterStatus, by name, for example `server_version`.
    parameters: Dict(String, String),
    /// The BackendKeyData, if the server sent one.
    cancel_key: Option(CancelKey),
    /// The protocol version of the connection: the one the login asked, or
    /// 3.0 when the server answered NegotiateProtocolVersion with 3.0.
    protocol_version: ProtocolVersion,
    /// The `_pq_.` startup parameters that the server did not know, from
    /// its NegotiateProtocolVersion.
    unrecognized_options: List(String),
    /// Each NoticeResponse, in the order the server sent them.
    notices: List(ServerReport),
    /// The transaction status of the first ReadyForQuery.
    transaction_status: TransactionStatus,
  )
}

/// The state of a login between two messages of the server.
pub opaque type LoginState {
  LoginState(
    stage: Stage,
    config: LoginConfig,
    client_nonce: BitArray,
    server_certificate: Option(BitArray),
    progress: Progress,
  )
}

/// The result of one step of a login.
pub type LoginStep {
  /// The login goes on: send the reply, if any, then give the next message
  /// of the server to `step`.
  Continue(state: LoginState, reply: Option(FrontendMessage))
  /// The login is done. The connection is ready for queries.
  LoggedIn(outcome: LoginOutcome)
}

/// The message that the login waits for.
type Stage {
  /// A NegotiateProtocolVersion or a login request.
  AwaitingLoginRequest
  /// The server-first-message of SCRAM.
  AwaitingServerFirst(mechanism: String, first: ClientFirst)
  /// The server-final-message of SCRAM.
  AwaitingServerFinal(final: ClientFinal)
  /// The AuthenticationOk after a password or SCRAM.
  AwaitingAuthenticationOk
  /// ParameterStatus and BackendKeyData, until ReadyForQuery.
  AwaitingReadyForQuery
}

/// What the server told the client so far.
type Progress {
  Progress(
    negotiated: Bool,
    protocol_version: ProtocolVersion,
    unrecognized_options: List(String),
    parameters: Dict(String, String),
    cancel_key: Option(CancelKey),
    /// The newest notice first.
    notices: List(ServerReport),
  )
}

// Settings --------------------------------------------------------------------

/// Makes a password.
///
/// ## Parameters
///
/// - `text`: the password
///
/// ## Returns
///
/// The password, in a function.
pub fn password(text: String) -> Password {
  Password(read: fn() { text })
}

/// Makes a password that a function gives each time the server asks for
/// it, for example from a secret store.
///
/// ## Parameters
///
/// - `read`: the function that gives the password
///
/// ## Returns
///
/// The password function.
pub fn password_function(read: fn() -> String) -> Password {
  Password(read:)
}

/// Gives no password: the login fails if the server asks for one.
///
/// ## Returns
///
/// No password.
pub fn no_password() -> Password {
  NoPassword
}

/// Checks the settings of a login. No connection is needed.
///
/// The StartupMessage gets `database`, then each parameter of the caller
/// (for example `options`), then `application_name` (the caller's, or
/// `default_application_name`), then `client_encoding` with `UTF8`.
///
/// ## Parameters
///
/// - `user`: the database user
/// - `database`: the database, or the empty string for the user's name
/// - `password`: the password, read here once to check it
/// - `parameters`: the other startup parameters, in order. A
///   `client_encoding` must name UTF-8, as PostgreSQL spells it (for
///   example `UTF8`, `utf-8` or `unicode`).
/// - `channel_binding`: when to bind SCRAM to the TLS connection
/// - `protocol_version`: the protocol version to ask for
///
/// ## Returns
///
/// - `Ok(LoginConfig)`: the checked settings
/// - `Error(ConfigError)`: a value that the StartupMessage cannot hold, a
///   parameter given two times, or an encoding other than UTF-8
pub fn new(
  user user: String,
  database database: String,
  password password: Password,
  parameters parameters: List(#(String, String)),
  channel_binding channel_binding: ChannelBindingSetting,
  protocol_version protocol_version: ProtocolVersion,
) -> Result(LoginConfig, ConfigError) {
  use <- guard(user == "", Error(EmptyUser))
  use _ <- try(check_password(password))
  let given = [#("user", user), #("database", database), ..parameters]
  use _ <- try(try_each(given, check_parameter))
  use _ <- try(try_fold(given, set.new(), check_unique_name))
  use _ <- try(try_each(parameters, check_client_encoding))
  Ok(LoginConfig(
    user:,
    password:,
    parameters: startup_parameters(database, parameters),
    channel_binding:,
    protocol_version:,
  ))
}

fn check_password(password: Password) -> Result(Nil, ConfigError) {
  case password {
    Password(read:) -> check_password_text(read())
    NoPassword -> Ok(Nil)
  }
}

fn check_password_text(text: String) -> Result(Nil, ConfigError) {
  use <- guard(string.contains(text, "\u{0000}"), Error(ZeroByteInPassword))
  Ok(Nil)
}

fn check_parameter(parameter: #(String, String)) -> Result(Nil, ConfigError) {
  let #(name, value) = parameter
  use <- guard(name == "", Error(EmptyParameterName))
  let zero_byte =
    string.contains(name, "\u{0000}") || string.contains(value, "\u{0000}")
  use <- guard(zero_byte, Error(ZeroByteInParameter(name)))
  Ok(Nil)
}

fn check_unique_name(
  seen: Set(String),
  parameter: #(String, String),
) -> Result(Set(String), ConfigError) {
  let name = lowercase(parameter.0)
  use <- guard(set.contains(seen, name), Error(DuplicateParameter(parameter.0)))
  Ok(set.insert(seen, name))
}

/// PostgreSQL's `clean_encoding_name` keeps the letters and digits of an
/// encoding name, in lower case. `utf8` and `unicode` both name UTF-8.
fn check_client_encoding(
  parameter: #(String, String),
) -> Result(Nil, ConfigError) {
  let #(name, value) = parameter
  let is_encoding = lowercase(name) == "client_encoding"
  let clean_value = to_graphemes(lowercase(value)) |> filter(is_letter_or_digit)
  let utf8 = clean_value == ["u", "t", "f", "8"] || clean_value == unicode
  use <- guard(is_encoding && !utf8, Error(UnsupportedClientEncoding(value)))
  Ok(Nil)
}

const unicode = ["u", "n", "i", "c", "o", "d", "e"]

const letters_and_digits = "abcdefghijklmnopqrstuvwxyz0123456789"

fn is_letter_or_digit(grapheme: String) -> Bool {
  string.contains(letters_and_digits, grapheme)
}

fn startup_parameters(
  database: String,
  parameters: List(#(String, String)),
) -> List(#(String, String)) {
  let application_name =
    find_parameter(parameters, "application_name")
    |> unwrap(#("application_name", default_application_name))
  [#("database", database), ..filter(parameters, is_caller_parameter)]
  |> append([application_name, #("client_encoding", "UTF8")])
}

fn is_caller_parameter(parameter: #(String, String)) -> Bool {
  let name = lowercase(parameter.0)
  name != "application_name" && name != "client_encoding"
}

fn find_parameter(
  parameters: List(#(String, String)),
  name: String,
) -> Result(#(String, String), Nil) {
  case parameters {
    [] -> Error(Nil)
    [parameter, ..rest] -> {
      use <- guard(lowercase(parameter.0) == name, Ok(parameter))
      find_parameter(rest, name)
    }
  }
}

// The state machine -----------------------------------------------------------

/// Starts a login on a connection that is up.
///
/// ## Parameters
///
/// - `config`: the checked settings
/// - `client_nonce`: `shortest_client_nonce` or more random bytes from
///   `crypto:strong_rand_bytes/1`, new for each login. Only SCRAM uses
///   them, as its client nonce.
/// - `server_certificate`: the DER bytes of the server's TLS certificate,
///   or `None` for a connection with no TLS
///
/// ## Returns
///
/// - `Ok(#(LoginState, StartupMessage))`: the state, and the StartupMessage
///   to send
/// - `Error(LoginError)`: the nonce is too short, or the settings require
///   channel binding and the connection has no TLS
pub fn start(
  config: LoginConfig,
  client_nonce: BitArray,
  server_certificate: Option(BitArray),
) -> Result(#(LoginState, FrontendMessage), LoginError) {
  let nonce_length = byte_size(client_nonce)
  use <- guard(nonce_length < shortest_client_nonce, {
    Error(ClientNonceTooShort(nonce_length))
  })
  let requires_tls = config.channel_binding == RequireChannelBinding
  use <- guard(requires_tls && server_certificate == None, {
    Error(ChannelBindingRequiresTls)
  })
  let state = initial_state(config, client_nonce, server_certificate)
  let startup =
    StartupMessage(config.protocol_version, config.user, config.parameters)
  Ok(#(state, startup))
}

fn initial_state(
  config: LoginConfig,
  client_nonce: BitArray,
  server_certificate: Option(BitArray),
) -> LoginState {
  let progress =
    Progress(False, config.protocol_version, [], dict.new(), None, [])
  LoginState(
    AwaitingLoginRequest,
    config,
    client_nonce,
    server_certificate,
    progress,
  )
}

/// Takes the next message of the server.
///
/// A NoticeResponse is kept at any step, and an ErrorResponse ends the
/// login at any step.
///
/// ## Parameters
///
/// - `state`: the state from `start` or from the last `step`
/// - `message`: the next message of the server
///
/// ## Returns
///
/// - `Ok(Continue(state, reply))`: send the reply, if any, and go on
/// - `Ok(LoggedIn(outcome))`: the login is done
/// - `Error(LoginError)`: the login failed
pub fn step(
  state: LoginState,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case message {
    ErrorResponse(report:) -> Error(ServerRejectedLogin(report))
    NoticeResponse(report:) -> Ok(Continue(keep_notice(state, report), None))
    _ -> stage_step(state, message)
  }
}

fn keep_notice(state: LoginState, report: ServerReport) -> LoginState {
  let progress = state.progress
  LoginState(
    ..state,
    progress: Progress(..progress, notices: [report, ..progress.notices]),
  )
}

fn stage_step(
  state: LoginState,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case state.stage {
    AwaitingLoginRequest -> login_request(state, message)
    AwaitingServerFirst(mechanism:, first:) ->
      server_first(state, mechanism, first, message)
    AwaitingServerFinal(final:) -> server_final(state, final, message)
    AwaitingAuthenticationOk -> authentication_ok(state, message)
    AwaitingReadyForQuery -> ready_for_query(state, message)
  }
}

fn login_request(
  state: LoginState,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case message {
    NegotiateProtocolVersion(major, minor, options) ->
      negotiate(state, message, major, minor, options)
    AuthenticationOk -> trust_login(state)
    AuthenticationCleartextPassword -> cleartext_login(state)
    AuthenticationMd5Password(salt:) -> md5_login(state, salt)
    AuthenticationSasl(mechanisms:) -> sasl_login(state, mechanisms)
    AuthenticationKerberosV5 -> Error(UnsupportedLoginMethod(KerberosV5Login))
    AuthenticationGss -> Error(UnsupportedLoginMethod(GssLogin))
    AuthenticationSspi -> Error(UnsupportedLoginMethod(SspiLogin))
    _ -> Error(UnexpectedMessage(message))
  }
}

/// The server sends NegotiateProtocolVersion at most once, before the
/// login request.
fn negotiate(
  state: LoginState,
  message: BackendMessage,
  major: Int,
  minor: Int,
  options: List(String),
) -> Result(LoginStep, LoginError) {
  let progress = state.progress
  use <- guard(progress.negotiated, Error(UnexpectedMessage(message)))
  use version <- try(negotiated_version(progress.protocol_version, major, minor))
  let progress =
    Progress(
      ..progress,
      negotiated: True,
      protocol_version: version,
      unrecognized_options: options,
    )
  Ok(Continue(LoginState(..state, progress:), None))
}

fn negotiated_version(
  asked: ProtocolVersion,
  major: Int,
  minor: Int,
) -> Result(ProtocolVersion, LoginError) {
  case major, minor, asked {
    3, 0, _ -> Ok(Protocol30)
    3, 2, Protocol32 -> Ok(Protocol32)
    _, _, _ -> Error(UnsupportedProtocolVersion(major, minor))
  }
}

fn trust_login(state: LoginState) -> Result(LoginStep, LoginError) {
  let required = state.config.channel_binding == RequireChannelBinding
  use <- guard(required, Error(ChannelBindingNotOffered(TrustLogin)))
  continue(state, AwaitingReadyForQuery, None)
}

fn cleartext_login(state: LoginState) -> Result(LoginStep, LoginError) {
  use password <- try(unbound_password(state, CleartextLogin))
  continue(state, AwaitingAuthenticationOk, Some(PasswordMessage(password)))
}

fn md5_login(
  state: LoginState,
  salt: BitArray,
) -> Result(LoginStep, LoginError) {
  use password <- try(unbound_password(state, Md5Login))
  let inner = md5_hex(<<password:utf8, state.config.user:utf8>>)
  let hashed = "md5" <> md5_hex(<<inner:utf8, salt:bits>>)
  continue(state, AwaitingAuthenticationOk, Some(PasswordMessage(hashed)))
}

fn md5_hex(bytes: BitArray) -> String {
  hash(Md5, bytes) |> base16_encode |> lowercase
}

/// The password for a method that does not bind to the channel. libpq's
/// `check_expected_areq` sends no password for one when channel binding
/// is required.
fn unbound_password(
  state: LoginState,
  method: LoginMethod,
) -> Result(String, LoginError) {
  let required = state.config.channel_binding == RequireChannelBinding
  use <- guard(required, Error(ChannelBindingNotOffered(method)))
  read_password(state.config.password, method)
}

/// Reads the password when the server asks for it. libpq refuses an empty
/// password too ("no password supplied").
fn read_password(
  password: Password,
  method: LoginMethod,
) -> Result(String, LoginError) {
  case password {
    Password(read:) -> checked_password(read(), method)
    NoPassword -> Error(PasswordRequired(method))
  }
}

fn checked_password(
  text: String,
  method: LoginMethod,
) -> Result(String, LoginError) {
  use <- guard(text == "", Error(PasswordRequired(method)))
  use _ <- try(check_password_text(text) |> map_error(InvalidConfig))
  Ok(text)
}

fn sasl_login(
  state: LoginState,
  mechanisms: List(String),
) -> Result(LoginStep, LoginError) {
  use binding <- try(choose_channel_binding(state, mechanisms))
  let mechanism = mechanism_name(binding)
  let first = client_first("", state.client_nonce, binding)
  let reply = SaslInitialResponse(mechanism, Some(client_first_message(first)))
  continue(state, AwaitingServerFirst(mechanism, first), Some(reply))
}

fn mechanism_name(binding: ChannelBinding) -> String {
  case binding {
    ServerEndPoint(_) -> scram_plus_mechanism
    ClientWithoutChannelBinding | ServerWithoutChannelBinding -> scram_mechanism
  }
}

/// Chooses the mechanism and its channel binding as libpq's
/// `pg_SASL_init` (`fe-auth.c`) does.
fn choose_channel_binding(
  state: LoginState,
  mechanisms: List(String),
) -> Result(ChannelBinding, LoginError) {
  case state.server_certificate {
    None -> binding_without_tls(mechanisms)
    Some(certificate) ->
      binding_with_tls(state.config.channel_binding, certificate, mechanisms)
  }
}

/// `start` refuses `RequireChannelBinding` with no TLS, so it cannot reach
/// this function.
fn binding_without_tls(
  mechanisms: List(String),
) -> Result(ChannelBinding, LoginError) {
  use <- guard(contains(mechanisms, scram_plus_mechanism), {
    Error(ChannelBindingOfferedWithoutTls)
  })
  scram_without_plus(mechanisms, ClientWithoutChannelBinding)
}

fn binding_with_tls(
  setting: ChannelBindingSetting,
  certificate: BitArray,
  mechanisms: List(String),
) -> Result(ChannelBinding, LoginError) {
  let offers_plus = contains(mechanisms, scram_plus_mechanism)
  case setting, offers_plus {
    DisableChannelBinding, _ ->
      scram_without_plus(mechanisms, ClientWithoutChannelBinding)
    PreferChannelBinding, True | RequireChannelBinding, True ->
      end_point_binding(certificate)
    PreferChannelBinding, False ->
      scram_without_plus(mechanisms, ServerWithoutChannelBinding)
    RequireChannelBinding, False -> {
      use _ <- try(scram_without_plus(mechanisms, ClientWithoutChannelBinding))
      Error(ChannelBindingNotOffered(SaslLogin(mechanisms)))
    }
  }
}

fn scram_without_plus(
  mechanisms: List(String),
  binding: ChannelBinding,
) -> Result(ChannelBinding, LoginError) {
  use <- guard(!contains(mechanisms, scram_mechanism), {
    Error(UnsupportedLoginMethod(SaslLogin(mechanisms)))
  })
  Ok(binding)
}

fn end_point_binding(
  certificate: BitArray,
) -> Result(ChannelBinding, LoginError) {
  server_end_point_hash(certificate)
  |> map(ServerEndPoint)
  |> map_error(CertificateHashFailed)
}

fn server_first(
  state: LoginState,
  mechanism: String,
  first: ClientFirst,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case message {
    AuthenticationSaslContinue(data:) ->
      scram_proof(state, mechanism, first, data)
    _ -> Error(UnexpectedMessage(message))
  }
}

fn scram_proof(
  state: LoginState,
  mechanism: String,
  first: ClientFirst,
  data: BitArray,
) -> Result(LoginStep, LoginError) {
  let method = ScramLogin(mechanism)
  use password <- try(read_password(state.config.password, method))
  use final <- try(
    client_final(first, password, data) |> map_error(ScramFailed),
  )
  let reply = SaslResponse(client_final_message(final))
  continue(state, AwaitingServerFinal(final), Some(reply))
}

/// A server that sends AuthenticationOk before its SASLFinal has not proved
/// that it knows the password's key, so that is an unexpected message.
fn server_final(
  state: LoginState,
  final: ClientFinal,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case message {
    AuthenticationSaslFinal(data:) -> {
      use _ <- try(verify_server_final(final, data) |> map_error(ScramFailed))
      continue(state, AwaitingAuthenticationOk, None)
    }
    _ -> Error(UnexpectedMessage(message))
  }
}

fn authentication_ok(
  state: LoginState,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  case message {
    AuthenticationOk -> continue(state, AwaitingReadyForQuery, None)
    _ -> Error(UnexpectedMessage(message))
  }
}

fn ready_for_query(
  state: LoginState,
  message: BackendMessage,
) -> Result(LoginStep, LoginError) {
  let progress = state.progress
  case message {
    ParameterStatus(name:, value:) -> {
      let parameters = dict.insert(progress.parameters, name, value)
      keep_progress(state, Progress(..progress, parameters:))
    }
    BackendKeyData(process_id:, secret_key:) -> {
      let cancel_key = Some(CancelKey(process_id:, secret_key:))
      keep_progress(state, Progress(..progress, cancel_key:))
    }
    ReadyForQuery(status:) -> Ok(LoggedIn(outcome(progress, status)))
    _ -> Error(UnexpectedMessage(message))
  }
}

fn keep_progress(
  state: LoginState,
  progress: Progress,
) -> Result(LoginStep, LoginError) {
  Ok(Continue(LoginState(..state, progress:), None))
}

fn outcome(progress: Progress, status: TransactionStatus) -> LoginOutcome {
  LoginOutcome(
    parameters: progress.parameters,
    cancel_key: progress.cancel_key,
    protocol_version: progress.protocol_version,
    unrecognized_options: progress.unrecognized_options,
    notices: reverse(progress.notices),
    transaction_status: status,
  )
}

fn continue(
  state: LoginState,
  stage: Stage,
  reply: Option(FrontendMessage),
) -> Result(LoginStep, LoginError) {
  Ok(Continue(LoginState(..state, stage:), reply))
}
