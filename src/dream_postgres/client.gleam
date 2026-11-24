//// PostgreSQL client wrapper
////
//// Provides a clean builder interface to the connection pool of
//// `dream_pog`, a fork of Pog. Follows Dream's builder pattern for
//// consistency. Import `dream_pog` as `pog` to use its types and query
//// functions with this module.
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

import dream_pog as pog
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri

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
/// An `application_name` connection parameter, for example from
/// `pog.connection_parameter`, is the name that the server shows for the
/// connections of the pool. Without one, the server shows the Erlang node
/// name.
///
/// ## Parameters
///
/// - `config`: The complete configuration
///
/// ## Returns
///
/// - `Ok(Connection)`: The pool process started
/// - `Error(StartError)`: The pool process did not start, for example
///   because a pool with the same name runs
/// - `Error(actor.InitFailed(message))`: The user, the database name, the
///   password or a connection parameter holds a null byte (`"\u{0}"`), and
///   no pool starts. The driver would end the text at the null byte and
///   send the rest to the server as another parameter. The message names
///   the part, never its value.
/// - `Error(actor.InitExited(_))`: The SSL mode is `pog.SslVerifiedCaFile`
///   or `pog.SslVerifiedChainOnlyCaFile`, and the CA file cannot be read or
///   holds no PEM certificate. `dream_pog` reads the file before the pool
///   starts.
///
/// The pool connects to the database in the background. So this function
/// returns `Ok` at once also when no database listens at the host and port,
/// when the password is wrong, when the database does not exist, and for a
/// pool size of 0. The failure shows on the first query: it returns
/// `Error(pog.ConnectionUnavailable)` after about 2 seconds. Call `check`
/// after `connect` to stop at startup when the database does not answer.
///
/// ## See Also
///
/// - `new`: make the config
/// - `from_url`: read a URL and start the pool in one step
/// - `check`: make sure that the database answers
///
/// ## Example
///
/// ### Start a connection pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import gleam/erlang/process
/// import gleam/otp/actor
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
  use Nil <- result.try(refuse_null_bytes(config))
  config
  |> pog.start()
  |> result.map(extract_connection_from_started)
}

// dream_pgo, the driver under dream_pog, writes the user, the database name and the
// connection parameters into the startup packet as strings that end with a
// null byte. So a null byte in one of them ends that string early, and the
// server reads the rest as the next name or value: a database name of
// "app\u{0}search_path\u{0}evil" sets `search_path`. A PostgreSQL name or
// password is SQL text, which cannot hold a null byte, so no correct config
// has one in these parts.
fn refuse_null_bytes(config: Config) -> Result(Nil, actor.StartError) {
  let parts = [
    #("the user", config.user),
    #("the database name", config.database),
    #("the password", option.unwrap(config.password, "")),
    ..list.flat_map(config.connection_parameters, parameter_parts)
  ]
  case list.find(parts, holds_null_byte) {
    Ok(#(part, _value)) ->
      Error(actor.InitFailed(
        part <> " holds a null byte, which PostgreSQL cannot take",
      ))
    Error(Nil) -> Ok(Nil)
  }
}

fn parameter_parts(parameter: #(String, String)) -> List(#(String, String)) {
  [
    #("a connection parameter", parameter.0),
    #("a connection parameter", parameter.1),
  ]
}

fn holds_null_byte(part: #(String, String)) -> Bool {
  string.contains(part.1, "\u{0}")
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
  /// is not a number (for example `localhost:abc`) also gives this error,
  /// and so does `%00` in the name or the value of a query parameter.
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
  /// The user name has a bad percent-encoding, for example `%zz`, or holds
  /// `%00`. PostgreSQL names cannot hold a null byte, and the driver would
  /// read the text after it as another connection parameter.
  InvalidUserEncoding
  /// The password has a bad percent-encoding, for example `%zz`, or holds
  /// `%00`. A PostgreSQL password cannot hold a null byte.
  InvalidPasswordEncoding
  /// The database name has a bad percent-encoding, for example `%zz`, or
  /// holds `%00`. PostgreSQL names cannot hold a null byte, and the driver
  /// would read the text after it as another connection parameter.
  InvalidDatabaseEncoding
  /// The query string has a `libpq` connection keyword that this package
  /// does not read, for example `connect_timeout`, `channel_binding`,
  /// `user` or `client_encoding`, or `database`, which the path of the URL
  /// sets. The server cannot apply these, so they are not sent to it. An
  /// empty name also gives this error, and so does a name that starts with
  /// `_pq_.`, which PostgreSQL reads as a protocol option, not a setting.
  UnsupportedParameter(name: String)
  /// The query string has a name that is not a `libpq` connection keyword
  /// but is at most one edit from one: one character added, removed or
  /// changed, or two characters next to each other swapped, with upper case
  /// read as lower case. `keyword` is that keyword. For example `sslmod`,
  /// `ssl_mode` and `SSLMODE` give
  /// `UnknownParameterLooksLike(name, "sslmode")`. Each server parameter of
  /// PostgreSQL 16 is either a keyword or more than one edit from every
  /// keyword, so such a name is a misspelled keyword.
  UnknownParameterLooksLike(name: String, keyword: String)
  /// The `sslmode` value is not one that this package reads. Use `disable`,
  /// `require`, `verify-ca` or `verify-full`. They have the meaning of
  /// `libpq`: `verify-ca` checks the certificate chain, and `verify-full`
  /// also checks that the certificate names the host.
  UnsupportedSslMode(mode: String)
  /// The URL has `sslrootcert=system` with an `sslmode` other than
  /// `verify-full`. As in `libpq`, the CA certificates of the system need
  /// `sslmode=verify-full`, or no `sslmode`.
  SslRootCertSystemNeedsVerifyFull(mode: String)
  /// The URL has `sslrootcert=<path>` but no `sslmode`. Add
  /// `sslmode=verify-full` or `sslmode=verify-ca`. This package does not read
  /// `prefer`, the `libpq` default.
  SslRootCertWithoutSslMode
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
/// ```text illustration
/// postgresql://user:password@host:port/database?parameter=value
/// ```
///
/// - The scheme is `postgresql` or `postgres`.
/// - `user` and `password` are optional and percent-decoded, so a password
///   can hold `@`, `:` or `/` when you encode them as `%40`, `%3A` and `%2F`.
///   The password starts after the first `:`. Without a user, the config
///   keeps the default user `postgres`. `%00` in the user or the password
///   gives `InvalidUserEncoding` or `InvalidPasswordEncoding`.
/// - `host` is required. An IPv6 host such as `[::1]` sets IPv6.
/// - `port` is optional and defaults to 5432.
/// - `database` is required and percent-decoded. `%00` in it gives
///   `InvalidDatabaseEncoding`.
/// - Query parameters: `sslmode` (`disable`, `require`, `verify-ca`,
///   `verify-full`) and `sslrootcert` set the SSL mode, as the table below
///   shows. `application_name` and `options` go
///   to the server. An `application_name` in `options`
///   (`-c application_name=x`) does not show, because the server applies
///   the separate parameters after `options` and the driver always sends
///   one: use the `application_name` parameter. The other `libpq` connection
///   keywords, such as `connect_timeout`, `database` and a name that starts
///   with `_pq_.` give `UnsupportedParameter(name)`, because the server
///   cannot apply them. A name one edit from a keyword,
///   such as `sslmod`, gives `UnknownParameterLooksLike(name, keyword)`.
///   Every other name, such as `search_path` or `timezone`, goes to the
///   server as a run-time parameter, with its percent-decoded value. Of two
///   parameters with the same name, the last wins, as in `libpq`.
///
/// `sslmode` and `sslrootcert` give the `pog.Ssl` of the config, with the
/// meaning that `libpq` gives them, the same as `pog.url_config` of
/// `dream_pog`:
///
/// | `sslmode`     | no `sslrootcert`       | `sslrootcert=<path>`               |
/// |---------------|------------------------|------------------------------------|
/// | not set       | `SslDisabled`          | `SslRootCertWithoutSslMode`        |
/// | `disable`     | `SslDisabled`          | `SslDisabled` (the file is unused) |
/// | `require`     | `SslUnverified`        | `SslVerifiedChainOnlyCaFile(path)` |
/// | `verify-ca`   | `SslVerifiedChainOnly` | `SslVerifiedChainOnlyCaFile(path)` |
/// | `verify-full` | `SslVerified`          | `SslVerifiedCaFile(path)`          |
///
/// `verify-ca` checks that a trusted CA signed the certificate, and
/// `verify-full` also checks that the certificate names the host. With a
/// path, the pool trusts the CA certificates of that PEM file only, and
/// without one, the CA certificates of the system. `sslrootcert=system`
/// selects the CA certificates of the system: with `sslmode=verify-full` or
/// no `sslmode` it gives `SslVerified`, and with another `sslmode` it gives
/// `SslRootCertSystemNeedsVerifyFull(mode)`. `connect` reads the file before
/// the pool starts.
///
/// This function does not know the parameters of the server. A name that
/// the server does not know, or a value that it refuses, gives `Ok` here,
/// and each query on the pool then returns `pog.ConnectionUnavailable`
/// after about 2 seconds. The server log says why. Call `check` at startup.
///
/// The connection parameters of the config keep the order of the URL. The
/// `application_name` of the URL is the name that the server shows, also
/// when you give the config to `pog.supervised` or `pog.start`.
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
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import gleam/erlang/process
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
/// the connection returns `Error(pog.ConnectionUnavailable)`. Call `check`
/// after `from_url` to stop at startup when the database does not answer.
///
/// See `parse_config` for the URL format and the supported query parameters.
/// An `application_name` in the URL is the name that the server shows for
/// the connections of the pool. A server parameter in the URL, such as
/// `search_path`, applies to each connection of the pool. When the server
/// refuses one, this function still returns `Ok`, and each query returns
/// `Error(pog.ConnectionUnavailable)`.
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
/// - `check`: make sure that the database answers
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

/// Make sure that the database answers
///
/// Runs `SELECT 1` on the connection. `connect` and `from_url` return `Ok`
/// before the pool connects, so call this function after them to find a
/// database that does not answer at startup, not at the first request.
///
/// ## Parameters
///
/// - `connection`: The connection from `connect` or `from_url`
///
/// ## Returns
///
/// - `Ok(Nil)`: The database answered
/// - `Error(QueryError)`: The error of the query. When no database listens
///   at the host and port, the password is wrong, the database does not
///   exist or the pool size is 0, the error is `pog.ConnectionUnavailable`,
///   after about 2 seconds.
///
/// ## See Also
///
/// - `from_url`: read a URL and start the pool in one step
/// - `connect`: start the pool from a config
///
/// ## Example
///
/// ### Check that the database answers <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/string
///
/// pub fn describe_database(connection: postgres.Connection) -> String {
///   case postgres.check(connection) {
///     Ok(Nil) -> "The database answers"
///     Error(error) -> "The database did not answer: " <> string.inspect(error)
///   }
/// }
/// ```
pub fn check(connection: Connection) -> Result(Nil, QueryError) {
  pog.query("SELECT 1")
  |> pog.execute(connection)
  |> result.replace(Nil)
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
    False -> decode_part(encoded_name, InvalidDatabaseEncoding)
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
    _ -> decode_part(encoded_user, InvalidUserEncoding)
  }
}

fn decode_password(encoded_password: String) -> Result(String, UrlError) {
  decode_part(encoded_password, InvalidPasswordEncoding)
}

// Percent-decodes the user, the password or the database name. A decoded
// null byte gives `error` too: the driver sends each of them as a string
// that ends with a null byte, so the rest would reach the server as another
// parameter (see `refuse_null_bytes`).
fn decode_part(encoded: String, error: UrlError) -> Result(String, UrlError) {
  case uri.percent_decode(encoded) {
    Ok(decoded) -> refuse_decoded_null_byte(decoded, error)
    Error(Nil) -> Error(error)
  }
}

fn refuse_decoded_null_byte(
  decoded: String,
  error: UrlError,
) -> Result(String, UrlError) {
  case string.contains(decoded, "\u{0}") {
    True -> Error(error)
    False -> Ok(decoded)
  }
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

// The `sslmode` and the `sslrootcert` of a URL. `parse_config` reads the
// whole query string first, and then both together, because `sslrootcert`
// changes the meaning of `sslmode`, as in libpq. The last value of each
// wins.
type SslSettings {
  SslSettings(
    mode: option.Option(String),
    root_certificate: option.Option(String),
  )
}

fn apply_query_string(
  config: Config,
  query: String,
) -> Result(Config, UrlError) {
  use parameters <- result.try(
    uri.parse_query(query)
    |> result.replace_error(MalformedUrl),
  )
  let start = #(
    config,
    SslSettings(mode: option.None, root_certificate: option.None),
  )
  use #(config, settings) <- result.try(list.try_fold(
    parameters,
    start,
    apply_parameter,
  ))
  use ssl <- result.try(resolve_ssl(config.ssl, settings))
  Ok(pog.ssl(config, ssl))
}

fn apply_parameter(
  state: #(Config, SslSettings),
  parameter: #(String, String),
) -> Result(#(Config, SslSettings), UrlError) {
  let #(config, settings) = state
  let #(name, value) = parameter
  case string.contains(name, "\u{0}"), string.contains(value, "\u{0}"), name {
    True, _, _ | _, True, _ -> Error(MalformedUrl)
    False, False, "sslmode" -> apply_ssl_mode(config, settings, value)
    False, False, "sslrootcert" ->
      Ok(#(
        config,
        SslSettings(..settings, root_certificate: option.Some(value)),
      ))
    False, False, _ ->
      apply_named_parameter(config, name, value)
      |> result.map(fn(config) { #(config, settings) })
  }
}

// `application_name` and `options` go to the server. The server reads
// `options` like the command line of a backend, for example
// `-c statement_timeout=5s`, the same as libpq sends it.
fn apply_named_parameter(
  config: Config,
  name: String,
  value: String,
) -> Result(Config, UrlError) {
  case list.contains(passed_keywords, name), is_refused_name(name) {
    True, _ -> Ok(append_connection_parameter(config, name, value))
    False, True -> Error(UnsupportedParameter(name))
    False, False -> apply_server_parameter(config, name, value)
  }
}

// A name that is not a keyword goes to the server, unless it is one edit
// from a keyword: then it is almost always a misspelled keyword, such as
// `sslmod` for `sslmode`, and the server would refuse it or, worse, the
// connection would run without the setting.
fn apply_server_parameter(
  config: Config,
  name: String,
  value: String,
) -> Result(Config, UrlError) {
  case find_near_keyword(name) {
    Ok(keyword) -> Error(UnknownParameterLooksLike(name:, keyword:))
    Error(Nil) -> Ok(append_connection_parameter(config, name, value))
  }
}

// Keeps the order of the URL, so that of two parameters with the same name
// the server takes the last, as libpq does.
fn append_connection_parameter(
  config: Config,
  name: String,
  value: String,
) -> Config {
  pog.Config(
    ..config,
    connection_parameters: list.append(config.connection_parameters, [
      #(name, value),
    ]),
  )
}

// The keywords that `parse_config` reads: `sslmode` and `sslrootcert` set
// the SSL mode, and the others go to the server.
const handled_keywords = [
  "sslmode", "sslrootcert", "application_name", "options",
]

const passed_keywords = ["application_name", "options"]

// The libpq connection keywords that this package has no code for, then
// `database` (the path of the URL sets it, and a second one in the startup
// message would replace it) and the empty name (the startup message cannot
// hold it). libpq 16 accepts each keyword up to `target_session_attrs`
// except `sslnegotiation`, `sslkeylogfile`, `min_protocol_version`,
// `max_protocol_version`, `scram_client_key` and `scram_server_key`, which
// come from later libpq versions, as do the `oauth_` keywords.
const refused_names = [
  "host", "hostaddr", "port", "dbname", "user", "password", "passfile",
  "require_auth", "channel_binding", "connect_timeout", "client_encoding",
  "fallback_application_name", "keepalives", "keepalives_idle",
  "keepalives_interval", "keepalives_count", "tcp_user_timeout", "replication",
  "gssencmode", "requiressl", "sslnegotiation", "sslcompression", "sslcert",
  "sslkey", "sslkeylogfile", "sslpassword", "sslcertmode", "sslcrl", "sslcrldir",
  "sslsni", "requirepeer", "ssl_min_protocol_version",
  "ssl_max_protocol_version", "min_protocol_version", "max_protocol_version",
  "krbsrvname", "gsslib", "gssdelegation", "scram_client_key",
  "scram_server_key", "service", "target_session_attrs", "load_balance_hosts",
  "oauth_issuer", "oauth_client_id", "oauth_client_secret", "oauth_scope",
  "database", "",
]

// A name that starts with `_pq_.` is a protocol option of PostgreSQL, not a
// server parameter. The server refuses one that it does not know and closes
// the connection, so the URL is refused here, where the error names it.
fn is_refused_name(name: String) -> Bool {
  list.contains(refused_names, name) || string.starts_with(name, "_pq_.")
}

// Gives the first keyword that the lower-case name is at most one edit
// from: one character added, removed or changed, or two characters next to
// each other swapped. libpq keywords are case-sensitive, so `SSLMODE` is
// not `sslmode` and gives this error too. No server parameter of
// PostgreSQL 16 (`SELECT name FROM pg_settings`) is one edit from a
// keyword without being that keyword, and a test checks this on each run.
fn find_near_keyword(name: String) -> Result(String, Nil) {
  let letters = string.to_graphemes(string.lowercase(name))
  list.append(handled_keywords, refused_names)
  |> list.find(fn(keyword) {
    keyword != "" && within_one_edit(letters, string.to_graphemes(keyword))
  })
}

fn within_one_edit(left: List(String), right: List(String)) -> Bool {
  case left, right {
    [], _ -> list.length(right) <= 1
    _, [] -> list.length(left) <= 1
    [first, ..left_rest], [second, ..right_rest] if first == second ->
      within_one_edit(left_rest, right_rest)
    [_, ..left_rest], [_, ..right_rest] ->
      left_rest == right_rest
      || left_rest == right
      || left == right_rest
      || is_swap(left, right)
  }
}

fn is_swap(left: List(String), right: List(String)) -> Bool {
  case left, right {
    [first, second, ..left_rest], [third, fourth, ..right_rest] ->
      first == fourth && second == third && left_rest == right_rest
    _, _ -> False
  }
}

fn apply_ssl_mode(
  config: Config,
  settings: SslSettings,
  mode: String,
) -> Result(#(Config, SslSettings), UrlError) {
  case list.contains(ssl_modes, mode) {
    True -> Ok(#(config, SslSettings(..settings, mode: option.Some(mode))))
    False -> Error(UnsupportedSslMode(mode))
  }
}

const ssl_modes = ["disable", "require", "verify-ca", "verify-full"]

// The rules of `pog.url_config` in dream_pog, which are the rules of libpq:
// a CA file makes `require` check the chain, as `verify-ca` does, and
// `sslrootcert=system` needs `verify-full`. `apply_ssl_mode` let only the
// four modes of `ssl_modes` through, so the last two branches are
// `verify-full`.
fn resolve_ssl(
  current: pog.Ssl,
  settings: SslSettings,
) -> Result(pog.Ssl, UrlError) {
  case settings.mode, settings.root_certificate {
    option.None, option.None -> Ok(current)
    option.Some("verify-full"), option.Some("system")
    | option.None, option.Some("system")
    -> Ok(pog.SslVerified)
    option.Some(mode), option.Some("system") ->
      Error(SslRootCertSystemNeedsVerifyFull(mode))
    option.None, option.Some(_path) -> Error(SslRootCertWithoutSslMode)
    option.Some("disable"), _ -> Ok(pog.SslDisabled)
    option.Some("require"), option.None -> Ok(pog.SslUnverified)
    option.Some("require"), option.Some(path)
    | option.Some("verify-ca"), option.Some(path)
    -> Ok(pog.SslVerifiedChainOnlyCaFile(path))
    option.Some("verify-ca"), option.None -> Ok(pog.SslVerifiedChainOnly)
    option.Some(_verify_full), option.None -> Ok(pog.SslVerified)
    option.Some(_verify_full), option.Some(path) ->
      Ok(pog.SslVerifiedCaFile(path))
  }
}
