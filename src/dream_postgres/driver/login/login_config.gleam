//// The settings of a login, checked before any connection is made: the
//// user, the database, the password, the startup parameters, channel binding
//// and the protocol version. `driver/login` runs the login with them.
////
//// No value of this module holds the password as a string: `Password` holds
//// a function that gives it, and a function prints without its value. So
//// `string.inspect`, the status of a process and a crash report cannot
//// show it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/encode.{length_field}
import dream_postgres/driver/message.{type ProtocolVersion}
import gleam/bool.{guard}
import gleam/list.{append, filter, fold, try_each, try_fold}
import gleam/result.{replace, replace_error, try, unwrap}
import gleam/set.{type Set}
import gleam/string.{lowercase, to_graphemes}

/// The `application_name` that the login sends when the caller gives none.
pub const default_application_name = "dream_postgres"

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

/// A password, or none, kept in a function so that no value prints it.
pub type Password {
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
pub type LoginConfig {
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

pub fn check_password_text(text: String) -> Result(Nil, ConfigError) {
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
