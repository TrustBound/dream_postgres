//// PostgreSQL client wrapper
////
//// Provides a clean builder interface to Pog connection management.
//// Follows Dream's builder pattern for consistency.
////
//// ## Example
////
//// ### Build a config and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_postgres/client as postgres
//// import gleam/erlang/process
//// import gleam/otp/actor
////
//// pub fn database_config() -> postgres.Config {
////   let pool_name = process.new_name("db_pool")
////   postgres.new(pool_name)
////   |> postgres.host("localhost")
////   |> postgres.port(5432)
////   |> postgres.database("myapp")
////   |> postgres.user("postgres")
////   |> postgres.password("secret")
////   |> postgres.pool_size(15)
//// }
////
//// pub fn connect_database() -> Result(postgres.Connection, actor.StartError) {
////   database_config()
////   |> postgres.connect()
//// }
//// ```

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import pog

/// A connection to a PostgreSQL connection pool.
///
/// The same type as `pog.Connection`. Pass it to `pog.execute` to run a
/// query. `connect` and `from_url` return it.
pub type Connection =
  pog.Connection

/// The settings of a connection pool.
///
/// The same type as `pog.Config`. Make one with `new` or `parse_config`,
/// change it with the builder functions, then start the pool with
/// `connect`. The `pog` functions that take a `pog.Config` also accept it.
pub type Config =
  pog.Config

/// Why a query failed.
///
/// The same type as `pog.QueryError`. `pog.execute` returns it. The
/// `dream_postgres/query` helpers turn it into the simpler
/// `query.QueryError`.
pub type QueryError =
  pog.QueryError

/// A value for a parameter of a query.
///
/// The same type as `pog.Value`. Make one with `pog.int`, `pog.text` and the
/// other `pog` value functions.
pub type Value =
  pog.Value

/// The result of a query that succeeded.
///
/// The same type as `pog.Returned`. `count` is the number of rows, and
/// `rows` holds the decoded rows.
pub type Returned(a) =
  pog.Returned(a)

/// Create a new default PostgreSQL configuration
///
/// Creates a configuration with sensible defaults. You must provide a pool name
/// which is used to identify the connection pool in the process registry.
///
/// ## Parameters
///
/// - `pool_name`: A process name for the connection pool
///
/// ## Returns
///
/// A new `Config` with default values. Use builder functions to customize it.
///
/// ## Example
///
/// ### Create a config for a pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_new.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/erlang/process
///
/// pub fn create_config() -> postgres.Config {
///   let pool_name = process.new_name("my_db_pool")
///   postgres.new(pool_name)
/// }
/// ```
pub fn new(pool_name: process.Name(pog.Message)) -> Config {
  pog.default_config(pool_name: pool_name)
}

/// Set the database host
///
/// Sets the hostname or IP address of the PostgreSQL server.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The hostname (e.g., "localhost" or "db.example.com")
///
/// ## Returns
///
/// A new `Config` with the host updated.
///
/// ## Example
///
/// ### Set the host <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_host.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn use_local_host(config: postgres.Config) -> postgres.Config {
///   config
///   |> postgres.host("localhost")
/// }
/// ```
pub fn host(config: Config, value: String) -> Config {
  pog.Config(..config, host: value)
}

/// Set the database port
///
/// Sets the port number for the PostgreSQL server. Defaults to 5432.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The port number
///
/// ## Returns
///
/// A new `Config` with the port updated.
///
/// ## Example
///
/// ### Set the port <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_port.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn use_default_port(config: postgres.Config) -> postgres.Config {
///   config
///   |> postgres.port(5432)
/// }
/// ```
pub fn port(config: Config, value: Int) -> Config {
  pog.Config(..config, port: value)
}

/// Set the database name
///
/// Sets the name of the PostgreSQL database to connect to.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The database name
///
/// ## Returns
///
/// A new `Config` with the database name updated.
///
/// ## Example
///
/// ### Set the database name <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn use_production_database(config: postgres.Config) -> postgres.Config {
///   config
///   |> postgres.database("myapp_prod")
/// }
/// ```
pub fn database(config: Config, value: String) -> Config {
  pog.Config(..config, database: value)
}

/// Set the database user
///
/// Sets the username for authenticating to PostgreSQL.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The username
///
/// ## Returns
///
/// A new `Config` with the user updated.
///
/// ## Example
///
/// ### Set the user <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn use_postgres_user(config: postgres.Config) -> postgres.Config {
///   config
///   |> postgres.user("postgres")
/// }
/// ```
pub fn user(config: Config, value: String) -> Config {
  pog.Config(..config, user: value)
}

/// Set the database password
///
/// Sets the password for authenticating to PostgreSQL.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The password
///
/// ## Returns
///
/// A new `Config` with the password updated.
///
/// ## Example
///
/// ### Set the password <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_password.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn use_password(config: postgres.Config) -> postgres.Config {
///   config
///   |> postgres.password("secret123")
/// }
/// ```
pub fn password(config: Config, value: String) -> Config {
  pog.Config(..config, password: option.Some(value))
}

/// Set the connection pool size
///
/// Sets the maximum number of connections in the pool. The pool manages
/// connections automatically, creating and reusing them as needed.
///
/// ## Parameters
///
/// - `config`: The configuration to modify
/// - `value`: The maximum number of connections (e.g., 15)
///
/// ## Returns
///
/// A new `Config` with the pool size updated.
///
/// ## Example
///
/// ### Set the pool size <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_pool_size.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn allow_twenty_connections(config: postgres.Config) -> postgres.Config {
///   config
///   // Allow up to 20 connections at the same time
///   |> postgres.pool_size(20)
/// }
/// ```
pub fn pool_size(config: Config, value: Int) -> Config {
  pog.Config(..config, pool_size: value)
}

/// Start the connection pool
///
/// Creates and starts the PostgreSQL connection pool with the provided
/// configuration. The pool will be registered with the process name you
/// provided to `new()`.
///
/// ## Parameters
///
/// - `config`: The complete configuration
///
/// ## Returns
///
/// - `Ok(Connection)`: Successfully started the pool
/// - `Error(StartError)`: Failed to start (e.g., connection refused, invalid config)
///
/// ## See Also
///
/// - `new`: make the config
/// - `from_url`: read a URL and start the pool in one step
///
/// ## Example
///
/// ### Start a connection pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/erlang/process
/// import gleam/otp/actor
/// import pog
///
/// pub fn connect_database(
///   pool_name: process.Name(pog.Message),
/// ) -> Result(postgres.Connection, actor.StartError) {
///   postgres.new(pool_name)
///   |> postgres.host("localhost")
///   |> postgres.port(5432)
///   |> postgres.database("myapp")
///   |> postgres.user("postgres")
///   |> postgres.password("secret")
///   |> postgres.pool_size(15)
///   |> postgres.connect()
/// }
/// ```
pub fn connect(config: Config) -> Result(Connection, actor.StartError) {
  pog.start(config)
  |> result.map(extract_connection_from_started)
}

fn extract_connection_from_started(
  started: actor.Started(Connection),
) -> Connection {
  let actor.Started(_pid, connection) = started
  connection
}

/// What is wrong with a PostgreSQL connection URL.
///
/// No value of this type holds the password from the URL, so it is safe to
/// log an error with `string.inspect`.
pub type UrlError {
  /// The text is not a URL, or its query string cannot be read. A port that
  /// is not a number (for example `localhost:abc`) also gives this error.
  MalformedUrl
  /// The URL has no scheme. Start it with `postgresql://` or `postgres://`.
  MissingScheme
  /// The scheme is not `postgresql` or `postgres`.
  UnsupportedScheme(scheme: String)
  /// The URL has no host, for example `postgresql:///myapp`.
  MissingHost
  /// The port is not in the range 1 to 65535.
  InvalidPort(port: Int)
  /// The URL has no database name after the host.
  MissingDatabase
  /// The path has more than one segment, for example `/my/app`. Encode a
  /// `/` in a database name as `%2F`.
  InvalidDatabase(path: String)
  /// The URL has a password but no user name, for example `:secret@host`.
  MissingUser
  /// The user name has a bad percent-encoding, for example `%zz`.
  InvalidUserEncoding
  /// The password has a bad percent-encoding, for example `%zz`.
  InvalidPasswordEncoding
  /// The database name has a bad percent-encoding, for example `%zz`.
  InvalidDatabaseEncoding
  /// The query string has a parameter that this package does not support.
  /// Only `sslmode` and `application_name` are supported.
  UnsupportedParameter(name: String)
  /// The `sslmode` value has no exact equivalent in the pool settings.
  /// Use `disable`, `require`, `verify-ca` or `verify-full`.
  UnsupportedSslMode(mode: String)
  /// The URL has a fragment (a `#` part). PostgreSQL URLs do not use one.
  UnsupportedFragment
}

/// Why `from_url` did not give a connection.
///
/// No value of this type holds the password from the URL.
pub type FromUrlError {
  /// The URL is not a valid PostgreSQL connection URL.
  InvalidUrl(error: UrlError)
  /// The pool process stopped while it started. The exit reason is not kept,
  /// because it can hold the pool settings, and the settings hold the
  /// password.
  PoolStartExited
}

/// Parse a PostgreSQL connection URL into a `Config`
///
/// This function is pure: it does not connect to the database. Use it to
/// check a URL, or to change the config before you call `connect()`.
///
/// ## URL Format
///
/// ```text
/// postgresql://user:password@host:port/database?parameter=value
/// ```
///
/// - The scheme is `postgresql` or `postgres`.
/// - `user` and `password` are optional and percent-decoded, so a password
///   can hold `@`, `:` or `/` when you encode them as `%40`, `%3A` and `%2F`.
///   The password starts after the first `:`. Without a user, the config
///   keeps the default user `postgres`.
/// - `host` is required. An IPv6 host such as `[::1]` sets IPv6.
/// - `port` is optional and defaults to 5432.
/// - `database` is required and percent-decoded.
/// - Query parameters: `sslmode` (`disable`, `require`, `verify-ca`,
///   `verify-full`) sets the SSL mode, and `application_name` sets the
///   PostgreSQL connection parameter with that name. Any other parameter is
///   an error.
///
/// All other settings keep the values from `new(pool_name)`.
///
/// ## Parameters
///
/// - `pool_name`: A process name for the connection pool
/// - `url`: The PostgreSQL connection URL
///
/// ## Returns
///
/// - `Ok(Config)`: The config that the URL describes
/// - `Error(UrlError)`: What is wrong with the URL. The error never holds
///   the password.
///
/// ## See Also
///
/// - `from_url`: read a URL and start the pool in one step
/// - `connect`: start the pool from a config
///
/// ## Example
///
/// ### Read a connection URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_parse_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/erlang/process
/// import pog
///
/// pub fn read_database_url(
///   pool_name: process.Name(pog.Message),
/// ) -> Result(postgres.Config, postgres.UrlError) {
///   postgres.parse_config(pool_name, "postgresql://user:pass@localhost/myapp")
/// }
/// ```
pub fn parse_config(
  pool_name: process.Name(pog.Message),
  url: String,
) -> Result(Config, UrlError) {
  use parsed <- result.try(parse_uri(url))
  use Nil <- result.try(check_scheme(parsed.scheme))
  use Nil <- result.try(check_fragment(parsed.fragment))
  use host_name <- result.try(require_host(parsed.host))
  use port_number <- result.try(check_port(parsed.port))
  use database_name <- result.try(parse_database(parsed.path))
  let config =
    new(pool_name)
    |> set_host_and_ip_version(host_name)
    |> port(port_number)
    |> database(database_name)
  use config <- result.try(apply_userinfo(config, parsed.userinfo))
  apply_query(config, parsed.query)
}

/// Connect from a PostgreSQL connection URL
///
/// Parses the URL with `parse_config`, sets a pool size of 15 and starts the
/// connection pool with `connect()`. Each call registers its pool under a new
/// unique process name, so you can call it more than once.
///
/// The pool connects to the database in the background. When no database
/// listens at the URL, this function still returns `Ok`, and each query on
/// the connection returns `Error(pog.ConnectionUnavailable)`.
///
/// See `parse_config` for the URL format and the supported query parameters.
///
/// ## Parameters
///
/// - `url`: The PostgreSQL connection URL
///
/// ## Returns
///
/// - `Ok(Connection)`: The pool started
/// - `Error(InvalidUrl(UrlError))`: The URL is not valid
/// - `Error(PoolStartExited)`: The pool process did not start. `pog` 4
///   reports every start failure as an exit.
///
/// No error holds the password.
///
/// ## See Also
///
/// - `parse_config`: read a URL without starting a pool
/// - `connect`: start the pool from a config
///
/// ## Example
///
/// ### Start a pool from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_from_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/string
///
/// pub fn describe_connection(url: String) -> String {
///   case postgres.from_url(url) {
///     Ok(_connection) -> "The pool started"
///     Error(postgres.InvalidUrl(error)) ->
///       "Invalid URL: " <> string.inspect(error)
///     Error(error) -> "The pool did not start: " <> string.inspect(error)
///   }
/// }
/// ```
pub fn from_url(url: String) -> Result(Connection, FromUrlError) {
  use config <- result.try(
    parse_config(process.new_name("postgres_pool"), url)
    |> result.map_error(InvalidUrl),
  )
  config
  |> pool_size(15)
  |> connect()
  // `pog.start` reports every start failure as `actor.InitExited`, and the
  // exit reason can hold the password, so it is not kept.
  |> result.replace_error(PoolStartExited)
}

// Private URL parsing - flat functions, no nesting

fn parse_uri(url: String) -> Result(uri.Uri, UrlError) {
  uri.parse(url)
  |> result.replace_error(MalformedUrl)
}

fn check_scheme(scheme: option.Option(String)) -> Result(Nil, UrlError) {
  case scheme {
    option.Some("postgresql") | option.Some("postgres") -> Ok(Nil)
    option.Some(other) -> Error(UnsupportedScheme(other))
    option.None -> Error(MissingScheme)
  }
}

fn check_fragment(fragment: option.Option(String)) -> Result(Nil, UrlError) {
  case fragment {
    option.None -> Ok(Nil)
    option.Some(_) -> Error(UnsupportedFragment)
  }
}

fn require_host(host_name: option.Option(String)) -> Result(String, UrlError) {
  case host_name {
    option.None | option.Some("") -> Error(MissingHost)
    option.Some(value) -> Ok(value)
  }
}

fn check_port(port_number: option.Option(Int)) -> Result(Int, UrlError) {
  case port_number {
    option.None -> Ok(5432)
    option.Some(value) if value >= 1 && value <= 65_535 -> Ok(value)
    option.Some(value) -> Error(InvalidPort(value))
  }
}

// When the URL has a host, `gleam/uri` gives a path that is empty or that
// starts with `/`, so dropping the first character removes that `/`.
fn parse_database(path: String) -> Result(String, UrlError) {
  case string.drop_start(path, 1) {
    "" -> Error(MissingDatabase)
    encoded_name -> decode_database_name(path, encoded_name)
  }
}

fn decode_database_name(
  path: String,
  encoded_name: String,
) -> Result(String, UrlError) {
  case string.contains(encoded_name, "/") {
    True -> Error(InvalidDatabase(path))
    False ->
      uri.percent_decode(encoded_name)
      |> result.replace_error(InvalidDatabaseEncoding)
  }
}

fn set_host_and_ip_version(config: Config, host_name: String) -> Config {
  case string.contains(host_name, ":") {
    True ->
      host(config, host_name)
      |> pog.ip_version(pog.Ipv6)
    False -> host(config, host_name)
  }
}

fn apply_userinfo(
  config: Config,
  userinfo: option.Option(String),
) -> Result(Config, UrlError) {
  case userinfo {
    option.None -> Ok(config)
    option.Some(value) -> apply_user_and_password(config, value)
  }
}

fn apply_user_and_password(
  config: Config,
  userinfo: String,
) -> Result(Config, UrlError) {
  case string.split_once(userinfo, ":") {
    Ok(#(encoded_user, encoded_password)) ->
      apply_user_with_password(config, encoded_user, encoded_password)
    Error(Nil) -> apply_user(config, userinfo)
  }
}

fn apply_user_with_password(
  config: Config,
  encoded_user: String,
  encoded_password: String,
) -> Result(Config, UrlError) {
  use config <- result.try(apply_user(config, encoded_user))
  use decoded_password <- result.try(decode_password(encoded_password))
  Ok(password(config, decoded_password))
}

fn apply_user(
  config: Config,
  encoded_user: String,
) -> Result(Config, UrlError) {
  use decoded_user <- result.try(decode_user(encoded_user))
  Ok(user(config, decoded_user))
}

fn decode_user(encoded_user: String) -> Result(String, UrlError) {
  case encoded_user {
    "" -> Error(MissingUser)
    _ ->
      uri.percent_decode(encoded_user)
      |> result.replace_error(InvalidUserEncoding)
  }
}

fn decode_password(encoded_password: String) -> Result(String, UrlError) {
  uri.percent_decode(encoded_password)
  |> result.replace_error(InvalidPasswordEncoding)
}

fn apply_query(
  config: Config,
  query: option.Option(String),
) -> Result(Config, UrlError) {
  case query {
    option.None -> Ok(config)
    option.Some(value) -> apply_query_string(config, value)
  }
}

fn apply_query_string(
  config: Config,
  query: String,
) -> Result(Config, UrlError) {
  use parameters <- result.try(
    uri.parse_query(query)
    |> result.replace_error(MalformedUrl),
  )
  list.try_fold(parameters, config, apply_parameter)
}

fn apply_parameter(
  config: Config,
  parameter: #(String, String),
) -> Result(Config, UrlError) {
  case parameter {
    #("sslmode", mode) -> apply_ssl_mode(config, mode)
    #("application_name", value) ->
      Ok(pog.connection_parameter(config, name: "application_name", value:))
    #(name, _value) -> Error(UnsupportedParameter(name))
  }
}

fn apply_ssl_mode(config: Config, mode: String) -> Result(Config, UrlError) {
  use ssl <- result.try(parse_ssl_mode(mode))
  Ok(pog.ssl(config, ssl))
}

fn parse_ssl_mode(mode: String) -> Result(pog.Ssl, UrlError) {
  case mode {
    "disable" -> Ok(pog.SslDisabled)
    "require" -> Ok(pog.SslUnverified)
    "verify-ca" | "verify-full" -> Ok(pog.SslVerified)
    _ -> Error(UnsupportedSslMode(mode))
  }
}
