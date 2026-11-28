//// Database URLs: the parts of a `postgres://` or `postgresql://` URL, read
//// as libpq reads them. The module `dream_postgres/url` gives the public
//// function `config_from_url`, which makes a config of the parts.

import dream_postgres/error.{
  type UrlFault, type UrlPart, InvalidPercentEncoding, InvalidUrlPort,
  MalformedBracketedHost, MissingScheme, MultipleHosts, ParameterGivenTwice,
  ParameterWithoutValue, UnixSocketHost, UnixSocketNotSupported, UnknownSslMode,
  UnknownSslNegotiation, UnsupportedParameter, UnsupportedScheme,
  UnsupportedSslMode, UrlDatabase, UrlHost, UrlParameters, UrlPassword, UrlUser,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// The parts of a database URL. An empty part is `None`.
pub type DatabaseUrl {
  DatabaseUrl(
    user: Option(String),
    password: Option(String),
    host: Option(String),
    port: Option(Int),
    database: Option(String),
    ssl_mode: SslMode,
    root_certificate: RootCertificate,
    direct_negotiation: Bool,
  )
}

/// The `sslmode` of a URL. A URL with no `sslmode` has `VerifyFull`, the
/// TLS of the default config.
pub type SslMode {
  Disable
  Prefer
  Require
  VerifyCa
  VerifyFull
}

/// The `sslrootcert` of a URL.
pub type RootCertificate {
  /// No `sslrootcert`.
  DefaultRootCertificate
  /// `sslrootcert=system`: the authorities of the operating system.
  SystemRootCertificate
  /// A PEM file of authorities.
  RootCertificateFile(path: String)
}

/// Reads the parts of a database URL.
pub fn parse(url: String) -> Result(DatabaseUrl, UrlFault) {
  use #(scheme, after_scheme) <- result.try(
    string.split_once(url, "://") |> result.replace_error(MissingScheme),
  )
  use Nil <- result.try(check_scheme(scheme))
  let #(before_query, query) = split_at_first(after_scheme, "?")
  let #(authority, path) = split_at_first(before_query, "/")
  let #(user_information, host_and_port) = split_at_last(authority, "@")
  use #(user, password) <- result.try(read_user_information(user_information))
  use #(host, port) <- result.try(read_host_and_port(host_and_port))
  use database <- result.try(decode_part(option.unwrap(path, ""), UrlDatabase))
  use parameters <- result.try(read_parameters(query))
  use ssl_mode <- result.try(read_ssl_mode(dict.get(parameters, "sslmode")))
  use direct_negotiation <- result.try(
    read_negotiation(dict.get(parameters, "sslnegotiation")),
  )
  Ok(DatabaseUrl(
    user:,
    password:,
    host:,
    port:,
    database:,
    ssl_mode:,
    root_certificate: read_root_certificate(dict.get(parameters, "sslrootcert")),
    direct_negotiation:,
  ))
}

fn check_scheme(scheme: String) -> Result(Nil, UrlFault) {
  case scheme {
    "postgres" | "postgresql" -> Ok(Nil)
    _ -> Error(UnsupportedScheme(scheme:))
  }
}

// The text before the first separator, and the text after it if the
// separator is there.
fn split_at_first(
  text: String,
  separator: String,
) -> #(String, Option(String)) {
  case string.split_once(text, separator) {
    Ok(#(before, after)) -> #(before, Some(after))
    Error(Nil) -> #(text, None)
  }
}

// The text before the last separator if the separator is there, and the
// text after it. A password may hold an `@`, so the host follows the last
// one.
fn split_at_last(text: String, separator: String) -> #(Option(String), String) {
  case string.split_once(string.reverse(text), separator) {
    Ok(#(reversed_after, reversed_before)) -> #(
      Some(string.reverse(reversed_before)),
      string.reverse(reversed_after),
    )
    Error(Nil) -> #(None, text)
  }
}

fn read_user_information(
  user_information: Option(String),
) -> Result(#(Option(String), Option(String)), UrlFault) {
  let #(user_text, password_text) =
    split_at_first(option.unwrap(user_information, ""), ":")
  use user <- result.try(decode_part(user_text, UrlUser))
  use password <- result.try(decode_part(
    option.unwrap(password_text, ""),
    UrlPassword,
  ))
  Ok(#(user, password))
}

fn read_host_and_port(
  host_and_port: String,
) -> Result(#(Option(String), Option(Int)), UrlFault) {
  case string.contains(host_and_port, ","), host_and_port {
    True, _ -> Error(MultipleHosts)
    False, "[" <> bracketed -> read_bracketed_host(bracketed)
    False, _ -> read_named_host(host_and_port)
  }
}

// An IPv6 address in square brackets, with an optional port after it.
fn read_bracketed_host(
  bracketed: String,
) -> Result(#(Option(String), Option(Int)), UrlFault) {
  case string.split_once(bracketed, "]") {
    Ok(#(address, "")) -> Ok(#(Some(address), None))
    Ok(#(address, ":" <> port_text)) ->
      read_port(port_text) |> result.map(fn(port) { #(Some(address), port) })
    Ok(#(_address, _text_after_bracket)) | Error(Nil) ->
      Error(MalformedBracketedHost)
  }
}

fn read_named_host(
  host_and_port: String,
) -> Result(#(Option(String), Option(Int)), UrlFault) {
  let #(host_text, port_text) = split_at_first(host_and_port, ":")
  use host <- result.try(decode_part(host_text, UrlHost))
  use Nil <- result.try(check_host(host))
  use port <- result.try(read_port(option.unwrap(port_text, "")))
  Ok(#(host, port))
}

fn check_host(host: Option(String)) -> Result(Nil, UrlFault) {
  case host {
    Some("/" <> directory) -> Error(UnixSocketHost(path: "/" <> directory))
    None -> Error(UnixSocketNotSupported)
    Some(_) -> Ok(Nil)
  }
}

// An empty port is the default port, as in libpq. A port is only digits,
// with no sign and no leading zero.
fn read_port(text: String) -> Result(Option(Int), UrlFault) {
  case text, int.parse(text) |> result.try(only_digits(_, text)) {
    "", _ -> Ok(None)
    _, Ok(port) if port >= 1 && port <= 65_535 -> Ok(Some(port))
    _, Ok(_) | _, Error(Nil) -> Error(InvalidUrlPort(port: text))
  }
}

fn only_digits(port: Int, text: String) -> Result(Int, Nil) {
  case int.to_string(port) == text {
    True -> Ok(port)
    False -> Error(Nil)
  }
}

// The percent-decoded text, or `None` when it is empty.
fn decode_part(
  text: String,
  part: UrlPart,
) -> Result(Option(String), UrlFault) {
  case uri.percent_decode(text) {
    Ok("") -> Ok(None)
    Ok(decoded) -> Ok(Some(decoded))
    Error(Nil) -> Error(InvalidPercentEncoding(part:))
  }
}

fn read_parameters(
  query: Option(String),
) -> Result(Dict(String, String), UrlFault) {
  case query {
    None -> Ok(dict.new())
    Some(text) ->
      text
      |> string.split("&")
      |> list.try_fold(dict.new(), add_parameter)
  }
}

fn add_parameter(
  parameters: Dict(String, String),
  text: String,
) -> Result(Dict(String, String), UrlFault) {
  use #(encoded_name, encoded_value) <- result.try(
    string.split_once(text, "=")
    |> result.replace_error(ParameterWithoutValue(name: text)),
  )
  use name <- result.try(decode_parameter(encoded_name))
  use value <- result.try(decode_parameter(encoded_value))
  use Nil <- result.try(check_parameter_name(name))
  case dict.has_key(parameters, name) {
    True -> Error(ParameterGivenTwice(name:))
    False -> Ok(dict.insert(parameters, name, value))
  }
}

fn decode_parameter(text: String) -> Result(String, UrlFault) {
  uri.percent_decode(text)
  |> result.replace_error(InvalidPercentEncoding(part: UrlParameters))
}

// The parameters of libpq that a config has a setting for. A config has no
// connect timeout, so `connect_timeout` is not one of them.
fn check_parameter_name(name: String) -> Result(Nil, UrlFault) {
  case name {
    "sslmode" | "sslrootcert" | "sslnegotiation" -> Ok(Nil)
    _ -> Error(UnsupportedParameter(name:))
  }
}

fn read_ssl_mode(mode: Result(String, Nil)) -> Result(SslMode, UrlFault) {
  case mode {
    Ok("disable") -> Ok(Disable)
    Ok("prefer") -> Ok(Prefer)
    Ok("require") -> Ok(Require)
    Ok("verify-ca") -> Ok(VerifyCa)
    Ok("verify-full") | Error(Nil) -> Ok(VerifyFull)
    Ok("allow") -> Error(UnsupportedSslMode(mode: "allow"))
    Ok(unknown) -> Error(UnknownSslMode(mode: unknown))
  }
}

fn read_negotiation(
  negotiation: Result(String, Nil),
) -> Result(Bool, UrlFault) {
  case negotiation {
    Ok("postgres") | Error(Nil) -> Ok(False)
    Ok("direct") -> Ok(True)
    Ok(unknown) -> Error(UnknownSslNegotiation(negotiation: unknown))
  }
}

fn read_root_certificate(path: Result(String, Nil)) -> RootCertificate {
  case path {
    Error(Nil) -> DefaultRootCertificate
    Ok("system") -> SystemRootCertificate
    Ok(file) -> RootCertificateFile(path: file)
  }
}
