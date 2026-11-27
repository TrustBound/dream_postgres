//// The login of a PostgreSQL connection, as a state machine of pure
//// functions: from the StartupMessage to the first ReadyForQuery.
////
//// The caller owns the socket. `new` checks the login settings before any
//// connection is made. After the connection (and its TLS, if any) is up,
//// `start` gives the StartupMessage, with a client nonce from
//// `random_client_nonce`. Then the caller gives each message of
//// the server to `step`, and sends the reply that `step` gives, until
//// `step` gives `LoggedIn` or an error. `encode_login_message` gives the
//// bytes of each message to send. It cannot fail: each value that a login
//// message holds has a limit that keeps the message within its length
//// field, and the login checks it before it makes the message.
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
import dream_postgres/driver/crypto.{Md5, hash, random_bytes}
import dream_postgres/driver/encode.{length_field}
import dream_postgres/driver/message.{
  type BackendMessage, type ProtocolVersion, AuthenticationCleartextPassword,
  AuthenticationGss, AuthenticationKerberosV5, AuthenticationMd5Password,
  AuthenticationOk, AuthenticationSasl, AuthenticationSaslContinue,
  AuthenticationSaslFinal, AuthenticationSspi, BackendKeyData, ErrorResponse,
  NegotiateProtocolVersion, NoticeResponse, ParameterStatus, Protocol30,
  Protocol32, ReadyForQuery,
}
import dream_postgres/driver/scram.{
  type ChannelBinding, type ClientFinal, type ClientFirst, type ServerFinalError,
  type ServerFirstError, ClientWithoutChannelBinding, ServerEndPoint,
  ServerWithoutChannelBinding, client_final, client_final_message, client_first,
  client_first_message, verify_server_final,
}
import dream_postgres/internal/cell.{type ServerReport, type TransactionStatus}
import gleam/bit_array.{base16_encode, byte_size}
import gleam/bool.{guard}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list.{
  append, contains, filter, fold, map as map_list, reverse, try_each, try_fold,
}
import gleam/option.{type Option, None, Some}
import gleam/result.{map, map_error, replace, replace_error, try, unwrap}
import gleam/set.{type Set}
import gleam/string.{lowercase, to_graphemes}

/// The `application_name` that the login sends when the caller gives none.
pub const default_application_name = "dream_postgres"

/// The fewest random bytes of a SCRAM client nonce. libpq uses 18
/// (`SCRAM_RAW_NONCE_LEN`).
pub const shortest_client_nonce = 18

/// The most random bytes of a SCRAM client nonce: 618. The message holds
/// the nonce as padded base64, 4 characters for each 3 bytes, so 618 bytes
/// are 824 characters.
///
/// libpq makes a nonce of 18 random bytes (`SCRAM_RAW_NONCE_LEN` in
/// PostgreSQL's `src/include/common/scram-common.h`, master e347dae2d4),
/// which base64 makes 24 characters. Npgsql makes 18 bytes too (`GetNonce`
/// in `NpgsqlConnector.Auth.cs`). RFC 5802 sets no length.
///
/// The limit comes from `scram.longest_sasl_message`, the 1024 bytes of
/// length field and body that a PostgreSQL server reads in each SASL
/// message. The nonce goes into two of them, and each must fit:
///
/// 1. The SASLInitialResponse: the type byte `p`, then the length field
///    and `SCRAM-SHA-256-PLUS`, a zero byte, the length of the
///    client-first-message, and the client-first-message
///    `p=tls-server-end-point,,n=,r=<nonce>`. The longest one, with
///    channel binding, leaves 1024 - 4 - 19 - 4 - 24 - 5 = 968 characters
///    for the nonce.
/// 2. The SASLResponse: its client-final-message holds the server nonce,
///    which is the client nonce and the server's part. That part comes
///    from the server, not from the driver: a PostgreSQL server adds the
///    base64 of `SCRAM_RAW_NONCE_LEN` (18, `src/include/common/scram-common.h`
///    line 37) random bytes, 24 characters (`src/backend/libpq/auth-scram.c`,
///    `build_server_first_message`, lines 1228-1236 on REL_16_STABLE and
///    1232-1240 on master). So this limit depends on the server: a server
///    that adds a longer part leaves less room for the client nonce. The client nonce
///    has the `scram.longest_server_nonce()` (848) characters less 24: 824
///    characters.
///
/// The smaller of the two is 824 characters, which are the base64 of 618
/// bytes. With a longer nonce, the server refuses the SASLResponse, so
/// `client_nonce` refuses the nonce before the login.
pub fn longest_client_nonce() -> Int {
  let initial_response_characters =
    scram.longest_sasl_message
    - scram.length_field_bytes
    - string.byte_size(scram_plus_mechanism)
    - mechanism_end_bytes
    - client_first_length_bytes
    - string.byte_size(scram.server_end_point_header)
    - string.byte_size(scram.bare_message_before_nonce(scram_user_name))
  let response_characters =
    scram.longest_server_nonce()
    - scram.base64_length(postgres_server_nonce_bytes)
  int.min(initial_response_characters, response_characters)
  |> scram.longest_base64_input
}

/// The user name of the client-first-message. PostgreSQL ignores it and
/// uses the user of the StartupMessage, so the login sends the empty name,
/// as libpq does.
const scram_user_name = ""

/// The zero byte after the mechanism name of a SASLInitialResponse.
const mechanism_end_bytes = 1

/// The Int32 length of the client-first-message in a SASLInitialResponse.
const client_first_length_bytes = 4

/// The random bytes that a PostgreSQL server adds to the client nonce to
/// make the server nonce: `SCRAM_RAW_NONCE_LEN`, 18
/// (`src/include/common/scram-common.h`, used in
/// `src/backend/libpq/auth-scram.c`).
const postgres_server_nonce_bytes = 18

/// The longest password, in bytes, that a cleartext login sends: 65530.
///
/// PostgreSQL reads a PasswordMessage with `pq_getmessage(&buf,
/// PG_MAX_AUTH_TOKEN_LENGTH)` (`src/backend/libpq/auth.c:739`), and
/// `PG_MAX_AUTH_TOKEN_LENGTH` is 65535 (`src/include/libpq/auth.h:33`).
/// `pq_getmessage` (`src/backend/libpq/pqcomm.c:1220`) refuses a length
/// field above that limit. The length field counts itself (4 bytes), the
/// password and its zero byte: 4 + 65530 + 1 = 65535. A longer password
/// is a message that the server refuses, so the login does not send it.
///
/// Only the cleartext login sends the password. MD5 sends a hash of 35
/// characters, and SCRAM only makes its keys from the password (after
/// SASLprep). So the limit applies to the cleartext login alone.
pub const longest_password = 65_530

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
    database: String,
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
  /// The StartupMessage of the settings, with the parameters that `new`
  /// adds, is too long for its length field: `length` is above
  /// 2147483647. The length field counts itself.
  StartupMessageTooLong(length: Int)
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

/// The random bytes of a SCRAM client nonce: from `shortest_client_nonce`
/// to `longest_client_nonce()`. Only `client_nonce` and `random_client_nonce`
/// make one.
pub opaque type ClientNonce {
  ClientNonce(bytes: BitArray)
}

/// Why `client_nonce` refuses the bytes.
pub type ClientNonceError {
  /// The bytes are fewer than `shortest_client_nonce`.
  ClientNonceTooShort(length: Int)
  /// The bytes are more than `longest_client_nonce()`.
  ClientNonceTooLong(length: Int)
}

/// Why `start` refuses a login.
pub type LoginStartError {
  /// The setting is `RequireChannelBinding`, and the connection has no
  /// TLS.
  ChannelBindingRequiresTls
}

/// Why `step` ends a login.
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
  /// The password function gave a password with a zero byte, which would
  /// end it early. No password went to the server.
  PasswordHasZeroByte
  /// The server asks for a cleartext password, and the password has
  /// `length` bytes, more than `longest_password`. No password went to the
  /// server.
  PasswordTooLong(length: Int)
  /// The setting is `RequireChannelBinding`, and the server asks for a
  /// login method that does not bind to the channel.
  ChannelBindingNotOffered(method: LoginMethod)
  /// The server offers SCRAM-SHA-256-PLUS on a connection with no TLS.
  /// libpq stops here too: something between the client and the server
  /// may have removed the TLS.
  ChannelBindingOfferedWithoutTls
  /// The server certificate gives no channel binding data.
  CertificateHashFailed(error: CertificateError)
  /// The server-first-message of SCRAM is not valid, for example a server
  /// nonce that does not extend the client's nonce.
  ScramServerFirstFailed(error: ServerFirstError)
  /// The server-final-message of SCRAM is not valid, or it holds an error
  /// or a wrong server signature.
  ScramServerFinalFailed(error: ServerFinalError)
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

/// A message that the login sends to the server. Only `start` and `step`
/// make one, from values that fit the message, so `encode_login_message`
/// cannot fail.
pub opaque type LoginMessage {
  /// The StartupMessage of the settings that `new` checked: no zero byte,
  /// no empty or repeated name, and a length that its length field holds.
  StartupMessage(config: LoginConfig)
  /// A cleartext password of `longest_password` bytes or fewer with no
  /// zero byte, or the 35 characters of an MD5 hash.
  PasswordMessage(password: String)
  /// One of the two SCRAM mechanism names, and the client-first-message of
  /// a client nonce of `longest_client_nonce()` bytes or fewer.
  SaslInitialResponse(mechanism: String, first: ClientFirst)
  /// The client-final-message of a server nonce of
  /// `scram.longest_server_nonce()` bytes or fewer.
  SaslResponse(final: ClientFinal)
}

/// The state of a login between two messages of the server.
pub opaque type LoginState {
  LoginState(
    stage: Stage,
    config: LoginConfig,
    client_nonce: ClientNonce,
    server_certificate: Option(BitArray),
    progress: Progress,
  )
}

/// The result of one step of a login.
pub type LoginStep {
  /// The login goes on: send the reply, if any, then give the next message
  /// of the server to `step`.
  Continue(state: LoginState, reply: Option(LoginMessage))
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

/// The database that the server opens for the login.
///
/// ## Parameters
///
/// - `config`: the login settings
///
/// ## Returns
///
/// The database of the settings, or the user's name for an empty one: the
/// server opens the database with the user's name then (PostgreSQL docs,
/// protocol-message-formats, StartupMessage `database`).
pub fn database(config: LoginConfig) -> String {
  case config.database {
    "" -> config.user
    database -> database
  }
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
///   parameter given two times, an encoding other than UTF-8, or a
///   StartupMessage longer than its length field can hold
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
  let startup = startup_parameters(database, parameters)
  use _ <- try(check_startup_length(user, startup))
  Ok(LoginConfig(
    user:,
    database:,
    password:,
    parameters: startup,
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
/// Only the value of `client_encoding` is read: the graphemes of a long
/// value of another parameter would take a long time to find.
fn check_client_encoding(
  parameter: #(String, String),
) -> Result(Nil, ConfigError) {
  let #(name, value) = parameter
  use <- guard(lowercase(name) != "client_encoding", Ok(Nil))
  let clean_value = to_graphemes(lowercase(value)) |> filter(is_letter_or_digit)
  let utf8 = clean_value == ["u", "t", "f", "8"] || clean_value == unicode
  use <- guard(!utf8, Error(UnsupportedClientEncoding(value)))
  Ok(Nil)
}

/// The length is worked out from the lengths of the texts, so that no
/// bytes of the message are built for the check.
fn check_startup_length(
  user: String,
  parameters: List(#(String, String)),
) -> Result(Nil, ConfigError) {
  let length = startup_message_length(user, parameters)
  length_field(length)
  |> replace_error(StartupMessageTooLong(length))
  |> replace(Nil)
}

/// The length field of the StartupMessage of `user` and `parameters`,
/// worked out from the lengths of the texts alone, with no bytes built:
/// the length field itself, the protocol version, each name and value with
/// its zero byte, and the zero byte that ends the list.
fn startup_message_length(
  user: String,
  parameters: List(#(String, String)),
) -> Int {
  let length_and_version = 8
  let end_of_list = 1
  fold(
    parameters,
    length_and_version + end_of_list + parameter_length(#("user", user)),
    add_parameter_length,
  )
}

fn add_parameter_length(total: Int, parameter: #(String, String)) -> Int {
  total + parameter_length(parameter)
}

/// A name and a value, each with its zero byte.
fn parameter_length(parameter: #(String, String)) -> Int {
  string.byte_size(parameter.0) + 1 + string.byte_size(parameter.1) + 1
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

/// A client nonce of `shortest_client_nonce` random bytes from
/// `crypto:strong_rand_bytes/1`. Use a new one for each login.
///
/// ## Returns
///
/// The new client nonce.
pub fn random_client_nonce() -> ClientNonce {
  ClientNonce(random_bytes(shortest_client_nonce))
}

/// A client nonce of the given bytes, for a login that must be the same
/// each time, as a test of the SCRAM exchange is.
///
/// ## Parameters
///
/// - `bytes`: from `shortest_client_nonce` to `longest_client_nonce()`
///   random bytes
///
/// ## Returns
///
/// - `Ok(ClientNonce)`: the client nonce
/// - `Error(ClientNonceTooShort(length))`: the bytes are too few
/// - `Error(ClientNonceTooLong(length))`: the bytes are too many
pub fn client_nonce(bytes: BitArray) -> Result(ClientNonce, ClientNonceError) {
  let length = byte_size(bytes)
  use <- guard(length < shortest_client_nonce, {
    Error(ClientNonceTooShort(length))
  })
  use <- guard(length > longest_client_nonce(), {
    Error(ClientNonceTooLong(length))
  })
  Ok(ClientNonce(bytes))
}

/// Starts a login on a connection that is up.
///
/// ## Parameters
///
/// - `config`: the checked settings
/// - `client_nonce`: a new one for each login, from `random_client_nonce`.
///   Only SCRAM uses it.
/// - `server_certificate`: the DER bytes of the server's TLS certificate,
///   or `None` for a connection with no TLS
///
/// ## Returns
///
/// - `Ok(#(LoginState, LoginMessage))`: the state, and the StartupMessage
///   to send
/// - `Error(ChannelBindingRequiresTls)`: the settings require channel
///   binding, and the connection has no TLS
pub fn start(
  config: LoginConfig,
  client_nonce: ClientNonce,
  server_certificate: Option(BitArray),
) -> Result(#(LoginState, LoginMessage), LoginStartError) {
  let requires_tls = config.channel_binding == RequireChannelBinding
  use <- guard(requires_tls && server_certificate == None, {
    Error(ChannelBindingRequiresTls)
  })
  let state = initial_state(config, client_nonce, server_certificate)
  Ok(#(state, StartupMessage(config)))
}

fn initial_state(
  config: LoginConfig,
  client_nonce: ClientNonce,
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
  use password <- try(check_password_length(password))
  continue(state, AwaitingAuthenticationOk, Some(PasswordMessage(password)))
}

/// The one check of the limit `longest_password`, on the text that the
/// password gives for the PasswordMessage. `new` does not check it: the
/// login method is not known before the server asks, and only the
/// cleartext login sends the password.
fn check_password_length(password: String) -> Result(String, LoginError) {
  let length = string.byte_size(password)
  use <- guard(length > longest_password, Error(PasswordTooLong(length)))
  Ok(password)
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
  use _ <- try(check_password_text(text) |> replace_error(PasswordHasZeroByte))
  Ok(text)
}

fn sasl_login(
  state: LoginState,
  mechanisms: List(String),
) -> Result(LoginStep, LoginError) {
  use binding <- try(choose_channel_binding(state, mechanisms))
  let mechanism = mechanism_name(binding)
  let first = client_first(scram_user_name, state.client_nonce.bytes, binding)
  let reply = SaslInitialResponse(mechanism, first)
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
    client_final(first, password, data) |> map_error(ScramServerFirstFailed),
  )
  let reply = SaslResponse(final)
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
      use _ <- try(
        verify_server_final(final, data) |> map_error(ScramServerFinalFailed),
      )
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
  reply: Option(LoginMessage),
) -> Result(LoginStep, LoginError) {
  Ok(Continue(LoginState(..state, stage:), reply))
}

// The bytes of a login message ------------------------------------------------

/// Writes a login message as the bytes to send. The layouts are the ones
/// of the PostgreSQL documentation, chapter "Frontend/Backend Protocol",
/// section "Message Formats".
///
/// The function cannot fail. The values of each message are checked when
/// the login makes it, so its length field holds its length:
///
/// - StartupMessage: `new` refuses a zero byte, an empty or repeated name,
///   and a length above 2147483647 (`StartupMessageTooLong`).
/// - PasswordMessage: at most `longest_password` bytes and no zero byte,
///   or an MD5 hash of 35 characters.
/// - SASLInitialResponse: a client nonce of at most `longest_client_nonce()`
///   bytes, so a length field of at most 880: 4 for itself, 19 for
///   `SCRAM-SHA-256-PLUS` and its zero byte, 4 for the data length, 24 for
///   the gs2-header `p=tls-server-end-point,,`, 5 for `n=,r=`, and 824
///   for the nonce in base64.
/// - SASLResponse: a channel binding hash of at most 64 bytes (SHA-512)
///   and a server nonce of at most `scram.longest_server_nonce()` bytes,
///   so a length field of at most `scram.longest_sasl_message` (1024): 4
///   for itself, 122 for `c=` and the gs2-header with the hash in base64,
///   3 for `,r=`, 848 for the server nonce, and 47 for `,p=` and the
///   proof in base64.
///
/// ## Parameters
///
/// - `message`: a message from `start` or `step`
///
/// ## Returns
///
/// The whole message, with its type byte (if it has one) and its length.
pub fn encode_login_message(message: LoginMessage) -> BitArray {
  case message {
    StartupMessage(config:) -> startup_message_bytes(config)
    PasswordMessage(password:) -> typed_message("p", <<password:utf8, 0>>)
    SaslInitialResponse(mechanism:, first:) -> {
      let data = client_first_message(first)
      let data_length = byte_size(data)
      typed_message("p", <<mechanism:utf8, 0, data_length:32, data:bits>>)
    }
    SaslResponse(final:) -> typed_message("p", client_final_message(final))
  }
}

/// The StartupMessage has no type byte: the length, the protocol version,
/// each name and value with its zero byte, then a zero byte.
fn startup_message_bytes(config: LoginConfig) -> BitArray {
  let parameters = [#("user", config.user), ..config.parameters]
  let body = <<
    version_code(config.protocol_version):32,
    bit_array.concat(map_list(parameters, parameter_bytes)):bits,
    0,
  >>
  let length = byte_size(body) + 4
  <<length:32, body:bits>>
}

fn parameter_bytes(parameter: #(String, String)) -> BitArray {
  <<parameter.0:utf8, 0, parameter.1:utf8, 0>>
}

fn version_code(version: ProtocolVersion) -> Int {
  case version {
    Protocol30 -> 196_608
    Protocol32 -> 196_610
  }
}

/// A message with a type byte: the byte, the length, the body. The length
/// field counts itself and the body, not the type byte.
fn typed_message(type_byte: String, body: BitArray) -> BitArray {
  let length = byte_size(body) + 4
  <<type_byte:utf8, length:32, body:bits>>
}
