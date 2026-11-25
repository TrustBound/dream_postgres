//// PostgreSQL client wrapper
////
//// Provides a clean builder interface to the connection pool of
//// `dream_postgres_client`, a fork of Pog. Follows Dream's builder pattern
//// for consistency.
////
//// It also has the query functions, the value functions and the types of
//// `dream_postgres_client`, so most code imports only this module. Code
//// that the SQL generator writes uses this module when `gleam.toml` sets
//// `client_module = "dream_postgres/client"`.
////
//// ## Example
////
//// ### Build a config and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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

import dream_postgres_client
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri

/// A connection to a PostgreSQL connection pool.
///
/// The same type as `dream_postgres_client.Connection`. Pass it to `execute`
/// to run a query. `connect` and `from_url` return it.
pub type Connection =
  dream_postgres_client.Connection

/// The settings of a connection pool.
///
/// The same type as `dream_postgres_client.Config`. Make one with `new` or
/// `parse_config`, change it with the builder functions, then start the pool
/// with `connect`. The `dream_postgres_client` functions that take a
/// `dream_postgres_client.Config` also accept it.
pub type Config =
  dream_postgres_client.Config

/// Why a query failed.
///
/// The same type as `dream_postgres_client.QueryError`. `execute` returns
/// it. The `dream_postgres/query` helpers turn it into the simpler
/// `query.QueryError`.
pub type QueryError =
  dream_postgres_client.QueryError

/// A value for a parameter of a query.
///
/// The same type as `dream_postgres_client.Value`. Make one with `int`,
/// `text` and the other value functions of this module.
pub type Value =
  dream_postgres_client.Value

/// The result of a query that succeeded.
///
/// The same type as `dream_postgres_client.Returned`. `count` is the number of
/// rows, and `rows` holds the decoded rows.
pub type Returned(a) =
  dream_postgres_client.Returned(a)

/// A query that is ready to run, with its SQL, its parameters and the decoder
/// of its rows.
///
/// The same type as `dream_postgres_client.Query`. Make one with `query`,
/// add parameters with `parameter`, set the row decoder with `returning`,
/// then run it with `execute`. `row` is the type of one decoded row.
pub type Query(row) =
  dream_postgres_client.Query(row)

/// Why a transaction failed.
///
/// The same type as `dream_postgres_client.TransactionError`. `transaction`
/// returns it. `TransactionQueryError` holds the error of the `BEGIN` or the
/// `COMMIT`, and `TransactionRolledBack` holds the error that the callback
/// returned.
pub type TransactionError(error) =
  dream_postgres_client.TransactionError(error)

/// A point in time, from a `timestamp` or `timestamptz` column.
///
/// The same type as `gleam/time/timestamp.Timestamp`. `timestamp` sends
/// one, and `timestamp_decoder` reads one. Code that names the type through
/// this module needs no `gleam_time` import.
///
/// ## Example
///
/// ### Read the time of a row <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timestamp_type.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn created_at(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
///   "SELECT timestamp '2024-01-02 03:04:05'"
///   |> postgres.query
///   |> postgres.returning(decode.at([0], postgres.timestamp_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub type Timestamp =
  timestamp.Timestamp

/// A calendar date, from a `date` column.
///
/// The same type as `gleam/time/calendar.Date`. `calendar_date` sends one,
/// and `calendar_date_decoder` reads one. Code that names the type through
/// this module needs no `gleam_time` import.
///
/// ## Example
///
/// ### Read a date <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_date_type.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn birthday(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(postgres.Date), postgres.QueryError) {
///   "SELECT date '2024-01-02'"
///   |> postgres.query
///   |> postgres.returning(decode.at([0], postgres.calendar_date_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub type Date =
  calendar.Date

/// A time of day, from a `time` column.
///
/// The same type as `gleam/time/calendar.TimeOfDay`. `calendar_time_of_day`
/// sends one, and `calendar_time_of_day_decoder` reads one. Code that names
/// the type through this module needs no `gleam_time` import.
///
/// ## Example
///
/// ### Read a time of day <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_time_of_day_type.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn opening_time(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(postgres.TimeOfDay), postgres.QueryError) {
///   "SELECT time '03:04:05'"
///   |> postgres.query
///   |> postgres.returning(decode.at([0], postgres.calendar_time_of_day_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub type TimeOfDay =
  calendar.TimeOfDay

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
/// ### Create a config for a pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_new.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
pub fn new(pool_name: process.Name(dream_postgres_client.Message)) -> Config {
  dream_postgres_client.default_config(pool_name: pool_name)
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
/// ### Set the host <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_host.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, host: value)
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
/// ### Set the port <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_port.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, port: value)
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
/// ### Set the database name <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, database: value)
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
/// ### Set the user <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, user: value)
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
/// ### Set the password <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_password.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, password: option.Some(value))
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
/// ### Set the pool size <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_pool_size.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.Config(..config, pool_size: value)
}

/// Start the connection pool
///
/// Creates and starts the PostgreSQL connection pool with the provided
/// configuration. The pool will be registered with the process name you
/// provided to `new()`.
///
/// An `application_name` connection parameter, for example from
/// `dream_postgres_client.connection_parameter`, is the name that the server
/// shows for the connections of the pool. Without one, the server shows the
/// Erlang node name.
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
/// - `Error(actor.InitExited(_))`: The SSL mode is
///   `dream_postgres_client.SslVerifiedCaFile` or
///   `dream_postgres_client.SslVerifiedChainOnlyCaFile`, and the CA file cannot
///   be read or holds no PEM certificate. `dream_postgres_client` reads the
///   file before the pool starts.
///
/// The pool connects to the database in the background. So this function
/// returns `Ok` at once also when no database listens at the host and port,
/// when the password is wrong, when the database does not exist, and for a pool
/// size of 0. The failure shows on the first query: it returns
/// `Error(dream_postgres_client.ConnectionUnavailable)` after 2 to 3 seconds.
/// Call `check` after `connect` to stop at startup when the database does not
/// answer.
///
/// ## See Also
///
/// - `new`: make the config
/// - `from_url`: read a URL and start the pool in one step
/// - `check`: make sure that the database answers
///
/// ## Example
///
/// ### Start a connection pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres_client
/// import gleam/erlang/process
/// import gleam/otp/actor
///
/// pub fn connect_database(
///   pool_name: process.Name(dream_postgres_client.Message),
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
  |> dream_postgres_client.start()
  |> result.map(extract_connection_from_started)
}

// dream_postgres_driver, the driver under dream_postgres_client, writes the
// user, the database name and the connection parameters into the startup packet
// as strings that end with a null byte. So a null byte in one of them ends that
// string early, and the server reads the rest as the next name or value: a
// database name of "app\u{0}search_path\u{0}evil" sets `search_path`. A
// PostgreSQL name or password is SQL text, which cannot hold a null byte, so no
// correct config has one in these parts.
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
/// `sslmode` and `sslrootcert` give the `dream_postgres_client.Ssl` of the
/// config, with the meaning that `libpq` gives them, the same as
/// `dream_postgres_client.url_config` of `dream_postgres_client`:
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
/// This function does not know the parameters of the server. A name that the
/// server does not know, or a value that it refuses, gives `Ok` here, and each
/// query on the pool then returns `dream_postgres_client.ConnectionUnavailable`
/// after 2 to 3 seconds. The server log says why. Call `check` at startup.
///
/// The connection parameters of the config keep the order of the URL. The
/// `application_name` of the URL is the name that the server shows, also when
/// you give the config to `dream_postgres_client.supervised` or
/// `dream_postgres_client.start`.
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
/// ### Read a connection URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_parse_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres_client
/// import gleam/erlang/process
///
/// pub fn read_database_url(
///   pool_name: process.Name(dream_postgres_client.Message),
/// ) -> Result(postgres.Config, postgres.UrlError) {
///   postgres.parse_config(pool_name, "postgresql://user:pass@localhost/myapp")
/// }
/// ```
pub fn parse_config(
  pool_name: process.Name(dream_postgres_client.Message),
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
/// listens at the URL, this function still returns `Ok`, and each query on the
/// connection returns `Error(dream_postgres_client.ConnectionUnavailable)`.
/// Call `check` after `from_url` to stop at startup when the database does not
/// answer.
///
/// See `parse_config` for the URL format and the supported query parameters.
/// An `application_name` in the URL is the name that the server shows for
/// the connections of the pool. A server parameter in the URL, such as
/// `search_path`, applies to each connection of the pool. When the server
/// refuses one, this function still returns `Ok`, and each query returns
/// `Error(dream_postgres_client.ConnectionUnavailable)`.
///
/// ## Parameters
///
/// - `url`: The PostgreSQL connection URL
///
/// ## Returns
///
/// - `Ok(Connection)`: The pool started
/// - `Error(InvalidUrl(UrlError))`: The URL is not valid
/// - `Error(PoolStartExited)`: The pool process did not start.
///   `dream_postgres_client` reports every start failure as an exit.
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
/// ### Start a pool from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_from_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  // `dream_postgres_client.start` reports every start failure as
  // `actor.InitExited`, and the exit reason can hold the password, so it is not
  // kept.
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
/// - `Error(QueryError)`: The error of the query. When no database listens at
///   the host and port, the password is wrong, the database does not exist or
///   the pool size is 0, the error is
///   `dream_postgres_client.ConnectionUnavailable`, after 2 to 3 seconds.
///
/// ## See Also
///
/// - `from_url`: read a URL and start the pool in one step
/// - `connect`: start the pool from a config
///
/// ## Example
///
/// ### Check that the database answers <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
  dream_postgres_client.query("SELECT 1")
  |> dream_postgres_client.execute(connection)
  |> result.replace(Nil)
}

// Queries and values. Code that the SQL generator writes with
// `client_module = "dream_postgres/client"` calls these functions.

/// Create a query from SQL text
///
/// Makes a query that `execute` runs. The query has no parameters, a timeout
/// of 5000 milliseconds, and a decoder that ignores the rows. Write `$1`,
/// `$2` and so on in the SQL for the parameters, then add them with
/// `parameter`. The same function as `dream_postgres_client.query`.
///
/// ## Parameters
///
/// - `sql`: The SQL text of the query
///
/// ## Returns
///
/// A new `Query(Nil)`. Set the row decoder with `returning`.
///
/// ## Example
///
/// ### Add two numbers in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn add(
///   connection: postgres.Connection,
///   left: Int,
///   right: Int,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT $1::int + $2::int"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(left))
///   |> postgres.parameter(postgres.int(right))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn query(sql: String) -> Query(Nil) {
  dream_postgres_client.query(sql)
}

/// Add a parameter to a query
///
/// Gives the value of the next `$n` placeholder of the SQL. The first call
/// fills `$1`, the second fills `$2`, and so on. The value travels apart from
/// the SQL text, so it cannot change the query. The same function as
/// `dream_postgres_client.parameter`.
///
/// ## Parameters
///
/// - `query`: The query to change
/// - `parameter`: The value, from `int`, `text` or another value function
///
/// ## Returns
///
/// The query with the parameter added.
///
/// ## Example
///
/// ### Add two numbers in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn add(
///   connection: postgres.Connection,
///   left: Int,
///   right: Int,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT $1::int + $2::int"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(left))
///   |> postgres.parameter(postgres.int(right))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn parameter(query: Query(row), parameter: Value) -> Query(row) {
  dream_postgres_client.parameter(query, parameter)
}

/// Set the decoder of the rows of a query
///
/// Each row comes to the decoder as a tuple of its columns. So
/// `decode.at([0], decode.int)` gives the first column as an `Int`, and
/// `decode.field(1, decode.string)` gives the second column as a `String`.
/// The same function as `dream_postgres_client.returning`.
///
/// ## Parameters
///
/// - `query`: The query to change
/// - `decoder`: The decoder of one row
///
/// ## Returns
///
/// The query with the new row type.
///
/// ## Example
///
/// ### Add two numbers in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn add(
///   connection: postgres.Connection,
///   left: Int,
///   right: Int,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT $1::int + $2::int"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(left))
///   |> postgres.parameter(postgres.int(right))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn returning(query: Query(a), decoder: decode.Decoder(b)) -> Query(b) {
  dream_postgres_client.returning(query, decoder)
}

/// Set the timeout of a query
///
/// The query fails with `QueryTimeout` when the database does not answer in
/// time. The default is 5000 milliseconds. The same function as
/// `dream_postgres_client.timeout`.
///
/// ## Parameters
///
/// - `query`: The query to change
/// - `timeout`: The time in milliseconds
///
/// ## Returns
///
/// The query with the new timeout.
///
/// ## Example
///
/// ### Give a query one second <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn one_in_a_second(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT 1"
///   |> postgres.query
///   |> postgres.timeout(1000)
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn timeout(query: Query(row), timeout: Int) -> Query(row) {
  dream_postgres_client.timeout(query, timeout)
}

/// Run a query
///
/// Sends the query and its parameters to the database, and decodes each row
/// with the decoder of `returning`. Code that the SQL generator writes calls
/// this function. The same function as `dream_postgres_client.execute`.
///
/// ## Parameters
///
/// - `query`: The query to run
/// - `pool`: The connection, from `connect` or `from_url`
///
/// ## Returns
///
/// `Ok(Returned(row))` with the number of rows and the decoded rows, or the
/// `QueryError` of the failure.
///
/// ## Example
///
/// ### Add two numbers in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn add(
///   connection: postgres.Connection,
///   left: Int,
///   right: Int,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT $1::int + $2::int"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(left))
///   |> postgres.parameter(postgres.int(right))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn execute(
  query query: Query(row),
  on pool: Connection,
) -> Result(Returned(row), QueryError) {
  dream_postgres_client.execute(query, pool)
}

/// Run a function in a transaction
///
/// Starts a transaction and gives the callback a connection in it. When the
/// callback returns `Ok`, the transaction commits. When it returns `Error`,
/// the transaction rolls back. Run every query of the transaction on the
/// connection that the callback gets. The same function as
/// `dream_postgres_client.transaction`.
///
/// ## Parameters
///
/// - `pool`: The connection, from `connect` or `from_url`
/// - `callback`: The function that runs the queries of the transaction
///
/// ## Returns
///
/// The `Ok` value of the callback, `TransactionRolledBack` with the error of
/// the callback, or `TransactionQueryError` when the `BEGIN` or the `COMMIT`
/// fails.
///
/// ## Example
///
/// ### Run a query in a transaction <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_transaction.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/result
///
/// pub fn answer_in_transaction(
///   connection: postgres.Connection,
/// ) -> Result(List(Int), postgres.TransactionError(postgres.QueryError)) {
///   use transaction <- postgres.transaction(connection)
///   "SELECT 40 + 2"
///   |> postgres.query
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(transaction)
///   |> result.map(fn(returned) { returned.rows })
/// }
/// ```
pub fn transaction(
  pool: Connection,
  callback: fn(Connection) -> Result(value, error),
) -> Result(value, TransactionError(error)) {
  dream_postgres_client.transaction(pool, callback)
}

/// A SQL `NULL` parameter
///
/// Use it for a column that has no value. `nullable` gives `NULL` for `None`.
/// The same function as `dream_postgres_client.null`.
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Send NULL <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_null.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn null_is_null(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(Bool), postgres.QueryError) {
///   "SELECT $1::text IS NULL"
///   |> postgres.query
///   |> postgres.parameter(postgres.null())
///   |> postgres.returning(decode.at([0], decode.bool))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn null() -> Value {
  dream_postgres_client.null()
}

/// A boolean parameter
///
/// Gives a `bool` value to PostgreSQL. The same function as
/// `dream_postgres_client.bool`.
///
/// ## Parameters
///
/// - `value`: The boolean
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Negate a boolean in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_bool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn negate(
///   connection: postgres.Connection,
///   value: Bool,
/// ) -> Result(postgres.Returned(Bool), postgres.QueryError) {
///   "SELECT NOT $1::bool"
///   |> postgres.query
///   |> postgres.parameter(postgres.bool(value))
///   |> postgres.returning(decode.at([0], decode.bool))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn bool(value: Bool) -> Value {
  dream_postgres_client.bool(value)
}

/// An integer parameter
///
/// Gives an integer value to PostgreSQL, for an `int`, `bigint` or `smallint`
/// column. The same function as `dream_postgres_client.int`.
///
/// ## Parameters
///
/// - `value`: The integer
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Add one in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_int.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn next_number(
///   connection: postgres.Connection,
///   value: Int,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT $1::int + 1"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(value))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn int(value: Int) -> Value {
  dream_postgres_client.int(value)
}

/// A float parameter
///
/// Gives a floating point value to PostgreSQL, for a `real` or `double
/// precision` column. The same function as `dream_postgres_client.float`.
///
/// ## Parameters
///
/// - `value`: The float
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Double a float in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_float.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn double(
///   connection: postgres.Connection,
///   value: Float,
/// ) -> Result(postgres.Returned(Float), postgres.QueryError) {
///   "SELECT $1::float8 * 2"
///   |> postgres.query
///   |> postgres.parameter(postgres.float(value))
///   |> postgres.returning(decode.at([0], decode.float))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn float(value: Float) -> Value {
  dream_postgres_client.float(value)
}

/// A text parameter
///
/// Gives a string to PostgreSQL, for a `text` or `varchar` column. The same
/// function as `dream_postgres_client.text`.
///
/// ## Parameters
///
/// - `value`: The string
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Change text in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_text.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn shout(
///   connection: postgres.Connection,
///   value: String,
/// ) -> Result(postgres.Returned(String), postgres.QueryError) {
///   "SELECT upper($1::text)"
///   |> postgres.query
///   |> postgres.parameter(postgres.text(value))
///   |> postgres.returning(decode.at([0], decode.string))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn text(value: String) -> Value {
  dream_postgres_client.text(value)
}

/// A bytea parameter
///
/// Gives binary data to PostgreSQL, for a `bytea` column. The same function
/// as `dream_postgres_client.bytea`.
///
/// ## Parameters
///
/// - `value`: The bytes
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Count bytes in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_bytea.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn byte_count(
///   connection: postgres.Connection,
///   value: BitArray,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT length($1::bytea)"
///   |> postgres.query
///   |> postgres.parameter(postgres.bytea(value))
///   |> postgres.returning(decode.at([0], decode.int))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn bytea(value: BitArray) -> Value {
  dream_postgres_client.bytea(value)
}

/// An array parameter
///
/// Gives a list to PostgreSQL as an array. The converter makes the `Value` of
/// each item. The same function as `dream_postgres_client.array`.
///
/// ## Parameters
///
/// - `converter`: The value function of one item, such as `int`
/// - `values`: The items
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Sort an array in the database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_array.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn sort_numbers(
///   connection: postgres.Connection,
///   values: List(Int),
/// ) -> Result(postgres.Returned(List(Int)), postgres.QueryError) {
///   "SELECT array(SELECT unnest($1::int[]) ORDER BY 1)"
///   |> postgres.query
///   |> postgres.parameter(postgres.array(postgres.int, values))
///   |> postgres.returning(decode.at([0], decode.list(decode.int)))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn array(converter: fn(a) -> Value, values: List(a)) -> Value {
  dream_postgres_client.array(converter, values)
}

/// A parameter that can be NULL
///
/// Gives `NULL` for `None`, and the value of the converter for `Some`. The
/// same function as `dream_postgres_client.nullable`.
///
/// ## Parameters
///
/// - `inner_type`: The value function for `Some`, such as `text`
/// - `value`: The optional value
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Send an optional value <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_nullable.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/option.{type Option}
///
/// pub fn nickname_or_none(
///   connection: postgres.Connection,
///   nickname: Option(String),
/// ) -> Result(postgres.Returned(String), postgres.QueryError) {
///   "SELECT coalesce($1::text, 'none')"
///   |> postgres.query
///   |> postgres.parameter(postgres.nullable(postgres.text, nickname))
///   |> postgres.returning(decode.at([0], decode.string))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn nullable(inner_type: fn(a) -> Value, value: Option(a)) -> Value {
  dream_postgres_client.nullable(inner_type, value)
}

/// A timestamp parameter
///
/// Gives a `Timestamp` to PostgreSQL, with microsecond precision, for a
/// `timestamp` column. Read the column back with `timestamp_decoder`. The
/// same function as `dream_postgres_client.timestamp`.
///
/// ## Parameters
///
/// - `timestamp`: The time
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Send and read a timestamp <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timestamp.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/timestamp.{type Timestamp}
///
/// pub fn one_hour_later(
///   connection: postgres.Connection,
///   value: Timestamp,
/// ) -> Result(postgres.Returned(Timestamp), postgres.QueryError) {
///   "SELECT $1::timestamp + interval '1 hour'"
///   |> postgres.query
///   |> postgres.parameter(postgres.timestamp(value))
///   |> postgres.returning(decode.at([0], postgres.timestamp_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn timestamp(timestamp: Timestamp) -> Value {
  dream_postgres_client.timestamp(timestamp)
}

/// Decode a timestamp column
///
/// Reads a `timestamp` column as a `Timestamp`. The same function as
/// `dream_postgres_client.timestamp_decoder`.
///
/// ## Returns
///
/// A decoder for `returning`.
///
/// ## Example
///
/// ### Send and read a timestamp <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timestamp.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/timestamp.{type Timestamp}
///
/// pub fn one_hour_later(
///   connection: postgres.Connection,
///   value: Timestamp,
/// ) -> Result(postgres.Returned(Timestamp), postgres.QueryError) {
///   "SELECT $1::timestamp + interval '1 hour'"
///   |> postgres.query
///   |> postgres.parameter(postgres.timestamp(value))
///   |> postgres.returning(decode.at([0], postgres.timestamp_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn timestamp_decoder() -> decode.Decoder(Timestamp) {
  dream_postgres_client.timestamp_decoder()
}

/// Decode a timestamptz column
///
/// Reads a `timestamptz` (`timestamp with time zone`) column as a
/// `Timestamp`. `timestamp_decoder` reads only a `timestamp` column:
/// `dream_postgres_client` gives a `timestamptz` value as a date and a time
/// of day in UTC, and this decoder reads that form. Send a `Timestamp` to a
/// `timestamptz` column with `timestamp`.
///
/// ## Returns
///
/// A decoder for `returning`.
///
/// ## Example
///
/// ### Read a timestamptz <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timestamp_with_time_zone_decoder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn signed_up_at(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
///   "SELECT timestamptz '2024-01-02 03:04:05.25+00'"
///   |> postgres.query
///   |> postgres.returning(decode.at(
///     [0],
///     postgres.timestamp_with_time_zone_decoder(),
///   ))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn timestamp_with_time_zone_decoder() -> decode.Decoder(Timestamp) {
  use date <- decode.field(0, dream_postgres_client.calendar_date_decoder())
  use time <- decode.field(
    1,
    dream_postgres_client.calendar_time_of_day_decoder(),
  )
  decode.success(timestamp.from_calendar(date, time, calendar.utc_offset))
}

/// A date parameter
///
/// Gives a `Date` to PostgreSQL, for a `date` column. Read the column back
/// with `calendar_date_decoder`. The same function as
/// `dream_postgres_client.calendar_date`.
///
/// ## Parameters
///
/// - `date`: The date
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Send and read a date <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_calendar_date.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/calendar.{type Date}
///
/// pub fn next_day(
///   connection: postgres.Connection,
///   value: Date,
/// ) -> Result(postgres.Returned(Date), postgres.QueryError) {
///   "SELECT $1::date + 1"
///   |> postgres.query
///   |> postgres.parameter(postgres.calendar_date(value))
///   |> postgres.returning(decode.at([0], postgres.calendar_date_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn calendar_date(date: Date) -> Value {
  dream_postgres_client.calendar_date(date)
}

/// Decode a date column
///
/// Reads a `date` column as a `Date`. The same function as
/// `dream_postgres_client.calendar_date_decoder`.
///
/// ## Returns
///
/// A decoder for `returning`.
///
/// ## Example
///
/// ### Send and read a date <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_calendar_date.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/calendar.{type Date}
///
/// pub fn next_day(
///   connection: postgres.Connection,
///   value: Date,
/// ) -> Result(postgres.Returned(Date), postgres.QueryError) {
///   "SELECT $1::date + 1"
///   |> postgres.query
///   |> postgres.parameter(postgres.calendar_date(value))
///   |> postgres.returning(decode.at([0], postgres.calendar_date_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn calendar_date_decoder() -> decode.Decoder(Date) {
  dream_postgres_client.calendar_date_decoder()
}

/// A time of day parameter
///
/// Gives a `TimeOfDay` to PostgreSQL, for a `time` column. Read the column
/// back with `calendar_time_of_day_decoder`. The same function as
/// `dream_postgres_client.calendar_time_of_day`.
///
/// ## Parameters
///
/// - `time`: The time of day
///
/// ## Returns
///
/// A `Value` for `parameter`.
///
/// ## Example
///
/// ### Send and read a time of day <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_calendar_time_of_day.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/calendar.{type TimeOfDay}
///
/// pub fn one_minute_later(
///   connection: postgres.Connection,
///   value: TimeOfDay,
/// ) -> Result(postgres.Returned(TimeOfDay), postgres.QueryError) {
///   "SELECT $1::time + interval '1 minute'"
///   |> postgres.query
///   |> postgres.parameter(postgres.calendar_time_of_day(value))
///   |> postgres.returning(decode.at([0], postgres.calendar_time_of_day_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn calendar_time_of_day(time: TimeOfDay) -> Value {
  dream_postgres_client.calendar_time_of_day(time)
}

/// Decode a time column
///
/// Reads a `time` column as a `TimeOfDay`. The same function as
/// `dream_postgres_client.calendar_time_of_day_decoder`.
///
/// ## Returns
///
/// A decoder for `returning`.
///
/// ## Example
///
/// ### Send and read a time of day <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_calendar_time_of_day.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
/// import gleam/time/calendar.{type TimeOfDay}
///
/// pub fn one_minute_later(
///   connection: postgres.Connection,
///   value: TimeOfDay,
/// ) -> Result(postgres.Returned(TimeOfDay), postgres.QueryError) {
///   "SELECT $1::time + interval '1 minute'"
///   |> postgres.query
///   |> postgres.parameter(postgres.calendar_time_of_day(value))
///   |> postgres.returning(decode.at([0], postgres.calendar_time_of_day_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn calendar_time_of_day_decoder() -> decode.Decoder(TimeOfDay) {
  dream_postgres_client.calendar_time_of_day_decoder()
}

/// Decode a numeric column
///
/// Reads a `numeric` column as a `Float`. A whole number becomes a `Float`
/// too. A `Float` can lose digits of a large or exact `numeric` value. The
/// same function as `dream_postgres_client.numeric_decoder`.
///
/// ## Returns
///
/// A decoder for `returning`.
///
/// ## Example
///
/// ### Read a numeric result <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_numeric_decoder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn price_with_tax(
///   connection: postgres.Connection,
///   cents: Int,
/// ) -> Result(postgres.Returned(Float), postgres.QueryError) {
///   "SELECT $1::int * 1.25 / 100"
///   |> postgres.query
///   |> postgres.parameter(postgres.int(cents))
///   |> postgres.returning(decode.at([0], postgres.numeric_decoder()))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn numeric_decoder() -> decode.Decoder(Float) {
  dream_postgres_client.numeric_decoder()
}

// Helpers for the code that dream_model generates. Generated code imports
// only this module, so it cannot match a `QueryError` variant itself.

/// Get the name of the constraint that a query violated
///
/// When a query fails because it violates a constraint, this function gives
/// the name of the constraint, for example `users_email_key`. This includes
/// a unique constraint, a primary key, a unique index, a foreign key, a
/// check constraint and an exclusion constraint. Every other error gives
/// `Error(Nil)`, also a `NOT NULL` violation.
///
/// This function does not tell the kinds of constraints apart. To find a
/// duplicate, compare the name with the names of constraints that you know
/// are unique. dream_model makes sure at generation time that each
/// `-- unique <name>` hint names a unique constraint, a primary key or a
/// unique index of the table. The schema fingerprint holds each constraint
/// and each index of the table, with its kind and its definition. So
/// `check_schema` finds a unique constraint or a unique index that changed
/// after that, for example one that became a plain index.
///
/// ## Parameters
///
/// - `error`: The error from `execute`
///
/// ## Returns
///
/// - `Ok(constraint)`: The query violated the constraint `constraint`
/// - `Error(Nil)`: The error is not a constraint violation
///
/// ## Example
///
/// ### Tell the user that the email is taken <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_violated_constraint.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn sign_up_error_message(error: postgres.QueryError) -> String {
///   case postgres.violated_constraint(error) {
///     Ok("users_email_key") -> "Email already taken"
///     Ok(constraint) -> "The sign-up broke the constraint " <> constraint
///     Error(Nil) -> "The sign-up failed"
///   }
/// }
/// ```
pub fn violated_constraint(error: QueryError) -> Result(String, Nil) {
  case error {
    dream_postgres_client.ConstraintViolated(constraint:, ..) -> Ok(constraint)
    _ -> Error(Nil)
  }
}

/// Decode a column that a SQL file promised is never NULL
///
/// PostgreSQL cannot tell if a computed column, such as `sum(amount)`, can
/// be NULL. A `.sql` file for dream_model can promise it with a
/// `-- not null: total` line, and the generated decoder then reads the
/// column with this function. It checks the promise on each row.
///
/// A value that is not NULL goes to `decoder`. A NULL fails the row with
/// one `decode.DecodeError`: `found` is `"NULL"`, and `expected` is the
/// marker `[dream_postgres promised_not_null] ` and then the message `the
/// SQL file order_total.sql promised the column total is never NULL, and
/// PostgreSQL returned NULL`. `broken_promise` finds the error by the
/// marker and gives the message without it. `execute` then returns
/// `UnexpectedResultType` with that error. The path of the error is the
/// path of the column, for example `["0"]` for `decode.at([0], ...)`. A
/// NULL fails also when `decoder` accepts NULL.
///
/// ## Parameters
///
/// - `decoder`: The decoder for a value that is not NULL
/// - `file`: The name of the SQL file that made the promise
/// - `column`: The name of the column
///
/// ## Returns
///
/// A decoder that fails on NULL with a message that names `file` and
/// `column`.
///
/// ## Example
///
/// ### Read a sum that the SQL file promised is never NULL <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_promised_not_null.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn order_total(
///   connection: postgres.Connection,
/// ) -> Result(postgres.Returned(Int), postgres.QueryError) {
///   "SELECT sum(amount)::int AS total FROM orders"
///   |> postgres.query
///   |> postgres.returning(decode.at(
///     [0],
///     postgres.promised_not_null(decode.int, "order_total.sql", "total"),
///   ))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn promised_not_null(
  decoder: decode.Decoder(a),
  file: String,
  column: String,
) -> decode.Decoder(a) {
  let null_error =
    decode.DecodeError(
      expected: promise_marker
        <> "the SQL file "
        <> file
        <> " promised the column "
        <> column
        <> " is never NULL, and PostgreSQL returned NULL",
      found: "NULL",
      path: [],
    )
  use found <- decode.then(decode.optional(decoder))
  case found {
    option.Some(value) -> decode.success(value)
    option.None ->
      decoder
      |> decode.then(decode.failure(_, null_error.expected))
      |> decode.map_errors(fn(_errors) { [null_error] })
  }
}

/// Read the message of a broken `-- not null:` promise
///
/// `promised_not_null` fails a NULL row with a message that names the SQL
/// file and the column. `execute` then returns `UnexpectedResultType` with
/// that message in a `decode.DecodeError`. This function gives the message,
/// so that code that imports only this module can show it. Code that
/// dream_model generates returns it as an `InternalServerError`.
///
/// ## Parameters
///
/// - `error`: The error from `execute`
///
/// ## Returns
///
/// - `Ok(message)`: A column that a SQL file promised is never NULL was
///   NULL. The message is the `expected` text of the decode error after
///   the marker `[dream_postgres promised_not_null] `, for
///   example `the SQL file order_total.sql promised the column total is
///   never NULL, and PostgreSQL returned NULL`
/// - `Error(Nil)`: The error has no broken promise
///
/// ## Example
///
/// ### Show the broken promise of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_broken_promise.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn error_message(error: postgres.QueryError) -> String {
///   case postgres.broken_promise(error) {
///     Ok(message) -> message
///     Error(Nil) -> "The query failed"
///   }
/// }
/// ```
pub fn broken_promise(error: QueryError) -> Result(String, Nil) {
  case error {
    dream_postgres_client.UnexpectedResultType(errors) ->
      list.find(errors, is_broken_promise)
      |> result.map(fn(decode_error) {
        string.drop_start(decode_error.expected, string.length(promise_marker))
      })
    _ -> Error(Nil)
  }
}

fn is_broken_promise(error: decode.DecodeError) -> Bool {
  error.found == "NULL" && string.starts_with(error.expected, promise_marker)
}

// The start of the `expected` text of a broken promise. A decoder of the
// standard library or of an app does not write it, so `broken_promise`
// finds only the errors of `promised_not_null`.
const promise_marker = "[dream_postgres promised_not_null] "

/// Decode a timestamp column that can hold infinity
///
/// A `timestamp` or `timestamptz` column can hold `'infinity'` and
/// `'-infinity'`. A `Timestamp` cannot hold them. This decoder fails such a
/// value with one `decode.DecodeError`: `found` is `"infinity"` or
/// `"-infinity"`, and `expected` is the marker `[dream_postgres finite] `
/// and then the message `the column happened_at holds infinity, which the
/// Gleam type Timestamp cannot hold`. `execute`
/// then returns `UnexpectedResultType` with that error, and
/// `infinite_value` gives the message. Every other value goes to
/// `decoder`.
///
/// ## Parameters
///
/// - `decoder`: The decoder of a finite value, for example
///   `timestamp_decoder()`
/// - `column`: The name of the column, for the message
///
/// ## Returns
///
/// A decoder that fails on infinity with a message that names `column`.
///
/// ## Example
///
/// ### Read a timestamp that can be infinity <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_finite_timestamp.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn ends_at(
///   connection: postgres.Connection,
///   sql: String,
/// ) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
///   sql
///   |> postgres.query
///   |> postgres.returning(decode.at(
///     [0],
///     postgres.finite_timestamp(postgres.timestamp_decoder(), "ends_at"),
///   ))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn finite_timestamp(
  decoder: decode.Decoder(Timestamp),
  column: String,
) -> decode.Decoder(Timestamp) {
  finite(decoder, timestamp.unix_epoch, column, "Timestamp")
}

/// Decode a date column that can hold infinity
///
/// A `date` column can hold `'infinity'` and `'-infinity'`. A `Date`
/// cannot hold them. This decoder fails such a value with one
/// `decode.DecodeError`: `found` is `"infinity"` or `"-infinity"`, and
/// `expected` is the marker `[dream_postgres finite] ` and then the
/// message `the column day holds infinity, which the Gleam type Date
/// cannot hold`. `infinite_value` gives the message. Every
/// other value goes to `decoder`.
///
/// ## Parameters
///
/// - `decoder`: The decoder of the date, for example
///   `calendar_date_decoder()`
/// - `column`: The name of the column, for the message
///
/// ## Returns
///
/// A decoder that fails on infinity with a message that names `column`.
///
/// ## Example
///
/// ### Read a date that can be infinity <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_finite_date.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn valid_until(
///   connection: postgres.Connection,
///   sql: String,
/// ) -> Result(postgres.Returned(postgres.Date), postgres.QueryError) {
///   sql
///   |> postgres.query
///   |> postgres.returning(decode.at(
///     [0],
///     postgres.finite_date(postgres.calendar_date_decoder(), "valid_until"),
///   ))
///   |> postgres.execute(connection)
/// }
/// ```
pub fn finite_date(
  decoder: decode.Decoder(Date),
  column: String,
) -> decode.Decoder(Date) {
  finite(decoder, calendar.Date(1970, calendar.January, 1), column, "Date")
}

fn finite(
  decoder: decode.Decoder(a),
  zero: a,
  column: String,
  type_name: String,
) -> decode.Decoder(a) {
  use raw <- decode.then(decode.dynamic)
  case infinity_of(raw) {
    Ok(value) -> infinity_failure(zero, column, value, type_name)
    Error(Nil) -> decoder
  }
}

/// Read the message of an infinite value
///
/// `finite_timestamp` and `finite_date` fail an infinite value with a
/// message that names the column. `execute` then returns
/// `UnexpectedResultType` with that message in a `decode.DecodeError`.
/// This function gives the message. Code that dream_model generates
/// returns it as an `InternalServerError`, after the name of the model
/// function.
///
/// ## Parameters
///
/// - `error`: The error from `execute`
///
/// ## Returns
///
/// - `Ok(message)`: A column held infinity or -infinity. The message is
///   the `expected` text of the decode error after the marker
///   `[dream_postgres finite] `, for example `the column
///   ends_at holds infinity, which the Gleam type Timestamp cannot hold`
/// - `Error(Nil)`: The error has no infinite value
///
/// ## Example
///
/// ### Show the infinite value of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_infinite_value.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn error_message(error: postgres.QueryError) -> String {
///   case postgres.infinite_value(error) {
///     Ok(message) -> message
///     Error(Nil) -> "The query failed"
///   }
/// }
/// ```
pub fn infinite_value(error: QueryError) -> Result(String, Nil) {
  case error {
    dream_postgres_client.UnexpectedResultType(errors) ->
      list.find(errors, is_infinite_value)
      |> result.map(fn(decode_error) {
        string.drop_start(decode_error.expected, string.length(infinity_marker))
      })
    _ -> Error(Nil)
  }
}

fn is_infinite_value(error: decode.DecodeError) -> Bool {
  list.contains(infinity_names, error.found)
  && string.starts_with(error.expected, infinity_marker)
}

fn infinity_of(raw: dynamic.Dynamic) -> Result(String, Nil) {
  decode.run(raw, atom.decoder())
  |> result.map(atom.to_string)
  |> result.replace_error(Nil)
  |> result.try(fn(name) {
    case list.contains(infinity_names, name) {
      True -> Ok(name)
      False -> Error(Nil)
    }
  })
}

fn infinity_failure(
  zero: a,
  column: String,
  value: String,
  type_name: String,
) -> decode.Decoder(a) {
  let message =
    infinity_marker
    <> "the column "
    <> column
    <> " holds "
    <> value
    <> ", which the Gleam type "
    <> type_name
    <> " cannot hold"
  decode.failure(zero, message)
  |> decode.map_errors(fn(_errors) {
    [decode.DecodeError(expected: message, found: value, path: [])]
  })
}

/// The values of an infinite timestamp or date.
const infinity_names = ["infinity", "-infinity"]

// The start of the `expected` text of an infinite value. A decoder of the
// standard library or of an app does not write it, so `infinite_value`
// finds only the errors of `finite_timestamp` and `finite_date`.
const infinity_marker = "[dream_postgres finite] "

/// The schema fingerprint that a generated module expects.
///
/// dream_model writes one value for each module that it generates. Give the
/// values to `check_schema` right after the pool starts.
pub type SchemaFingerprint {
  SchemaFingerprint(
    /// The name of the generated module, for example `app/sql/users`.
    module: String,
    /// The tables that the module reads or writes, each as
    /// `schema.table`, for example `public.users`.
    tables: List(String),
    /// The value of `schema_fingerprint` for `tables` when dream_model
    /// generated the module: 64 lowercase hexadecimal digits.
    hash: String,
  )
}

/// A generated module whose tables changed after dream_model generated it.
pub type SchemaMismatch {
  SchemaMismatch(
    /// The name of the generated module.
    module: String,
    /// The tables of the module.
    tables: List(String),
    /// The fingerprint that the module expects.
    expected: String,
    /// The fingerprint of the database.
    found: String,
  )
}

/// Why `check_schema` failed.
pub type SchemaCheckError {
  /// The schema of these modules changed. Regenerate the modules with
  /// dream_model.
  SchemaChanged(mismatches: List(SchemaMismatch))
  /// The fingerprint query of `module` failed with `error`.
  SchemaUnreadable(module: String, error: QueryError)
}

/// The SQL of `schema_fingerprint`
///
/// `$1` is a `text[]` of table names. The query gives one row with one
/// `text` column: the canonical text of the schema. `schema_fingerprint`
/// gives the SHA-256 hash of its UTF-8 bytes, as 64 lowercase hexadecimal
/// digits. A tool that does not use this package, such as a code
/// generator, runs this SQL to get the same fingerprint.
///
/// The text has one entry for each fact, sorted by byte value and joined by
/// a newline. An entry starts with the name of its table or type. The
/// definition of a view or a rule can hold newlines. The text holds these
/// facts for each table or view, and for each child table and partition of
/// the table, at all levels:
///
/// - The kind of the relation (`relkind`), row level security and forced
///   row level security, if it has a row-level `BEFORE` trigger, if it has
///   a row-level `INSTEAD OF` trigger, the `check_option` of a view, the
///   partition key and the partition bound. A statement-level trigger and
///   an `AFTER` trigger do not change the rows that a query returns, so
///   they are not in the text.
/// - The definition of a view or a materialized view (`pg_get_viewdef`)
/// - Each parent of the table
/// - Each column that is not dropped: its name, its position, its type
///   (`format_type`), `NOT NULL`, if it has a default, its identity and
///   generated kind, and the expression of a generated column
/// - Each constraint: its kind, name, if it is validated, and its
///   definition (`pg_get_constraintdef`). On PostgreSQL 18 and later, this
///   includes the `NOT NULL` constraints.
/// - Each index: its name, if it is unique, if it is valid, and its
///   definition (`pg_get_indexdef`)
/// - Each rule other than the `_RETURN` rule of a view: its name, if it is
///   enabled, and its definition (`pg_get_ruledef`)
/// - Each policy: its name, command, if it is permissive, its roles, and
///   its `USING` and `WITH CHECK` expressions
/// - Each type that a column uses, also through an array, a domain, a
///   composite type or a range: for a domain its base type, `NOT NULL` and
///   constraints, for an enum its labels in order, for a composite type
///   the position, name and type of each field, and for a range its
///   subtype
///
/// A name that is not a table gives the line `<name> missing`, so a
/// missing table changes the fingerprint and is not an error.
///
/// The position of a column is its place among the columns that are not
/// dropped, in the order of `SELECT *`: 1 for the first column, 2 for the
/// second, and so on. The generated decoders read the columns by position,
/// so a change of the order changes the fingerprint. A dropped column
/// changes the position of each column after it, and of no other column.
/// So a table that had a column dropped has the same text as a table that
/// the same columns made without it. The text holds no OIDs and no
/// attribute numbers, so two databases that the same migrations made give
/// the same text.
///
/// While it reads the catalog, the query sets these settings, because they
/// change how PostgreSQL writes a name or a constant: `search_path` to
/// `pg_catalog`, `TimeZone` to `UTC`, `DateStyle` to `ISO, YMD`,
/// `IntervalStyle` to `postgres`, `extra_float_digits` to `1`,
/// `quote_all_identifiers` to `off`, `bytea_output` to `hex`,
/// `standard_conforming_strings` to `on` and `lc_monetary` to `C`. Then
/// it sets the earlier values back. It sets them with `set_config(...,
/// true)`, so when the query fails, the end of its transaction sets them
/// back. The settings of the connection thus do not change the text, and
/// each name in the text has its schema.
///
/// PostgreSQL 17 and later keep the `NOT NULL` of a domain as a
/// constraint, and PostgreSQL 18 and later keep the `NOT NULL` of a column
/// as a constraint. So the text of a schema with a `NOT NULL` is different
/// on PostgreSQL 16, on 17, and on 18 and later. Generate the modules
/// against the major version of PostgreSQL that the app uses.
///
/// ## Example
///
/// ### Read the canonical text of the fingerprint <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_schema_fingerprint_sql.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/dynamic/decode
///
/// pub fn fingerprint_text(
///   connection: postgres.Connection,
///   tables: List(String),
/// ) -> Result(postgres.Returned(String), postgres.QueryError) {
///   postgres.schema_fingerprint_sql
///   |> postgres.query
///   |> postgres.parameter(postgres.array(postgres.text, tables))
///   |> postgres.returning(decode.at([0], decode.string))
///   |> postgres.execute(connection)
/// }
/// ```
pub const schema_fingerprint_sql =
  "WITH RECURSIVE saved AS MATERIALIZED (
  SELECT
    current_setting('search_path') AS search_path,
    current_setting('TimeZone') AS time_zone,
    current_setting('DateStyle') AS date_style,
    current_setting('IntervalStyle') AS interval_style,
    current_setting('extra_float_digits') AS extra_float_digits,
    current_setting('quote_all_identifiers') AS quote_all_identifiers,
    current_setting('bytea_output') AS bytea_output,
    current_setting('standard_conforming_strings') AS standard_conforming_strings,
    current_setting('lc_monetary') AS lc_monetary
),
pinned AS MATERIALIZED (
  SELECT concat(
    set_config('search_path', 'pg_catalog', true),
    set_config('TimeZone', 'UTC', true),
    set_config('DateStyle', 'ISO, YMD', true),
    set_config('IntervalStyle', 'postgres', true),
    set_config('extra_float_digits', '1', true),
    set_config('quote_all_identifiers', 'off', true),
    set_config('bytea_output', 'hex', true),
    set_config('standard_conforming_strings', 'on', true),
    set_config('lc_monetary', 'C', true)
  ) AS settings
  FROM saved
),
requested AS (
  SELECT DISTINCT name FROM unnest($1::text[]) AS name
),
roots AS (
  SELECT requested.name, class.oid
  FROM requested
  LEFT JOIN (
    pg_class AS class
    JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
  ) ON quote_ident(namespace.nspname) || '.' || quote_ident(class.relname)
    = requested.name
),
relations AS (
  SELECT oid FROM roots WHERE oid IS NOT NULL
  UNION
  SELECT inherits.inhrelid
  FROM pg_inherits AS inherits
  JOIN relations ON inherits.inhparent = relations.oid
),
relation_set AS (
  SELECT DISTINCT oid FROM relations
),
named AS (
  SELECT class.*,
    quote_ident(namespace.nspname) || '.' || quote_ident(class.relname)
      AS qualified
  FROM relation_set
  JOIN pg_class AS class ON class.oid = relation_set.oid
  JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
),
columns AS (
  SELECT named.qualified, attribute.*,
    row_number() OVER (
      PARTITION BY attribute.attrelid ORDER BY attribute.attnum
    ) AS position
  FROM named
  JOIN pg_attribute AS attribute ON attribute.attrelid = named.oid
  WHERE attribute.attnum > 0 AND NOT attribute.attisdropped
),
types AS (
  SELECT atttypid AS oid FROM columns
  UNION
  SELECT inner_type.oid
  FROM types
  JOIN pg_type AS type ON type.oid = types.oid
  LEFT JOIN pg_attribute AS field
    ON type.typtype = 'c' AND field.attrelid = type.typrelid
    AND field.attnum > 0 AND NOT field.attisdropped
  LEFT JOIN pg_range AS range ON range.rngtypid = type.oid
  LEFT JOIN pg_range AS multirange ON multirange.rngmultitypid = type.oid
  CROSS JOIN LATERAL unnest(ARRAY[
    CASE WHEN type.typtype = 'd' THEN type.typbasetype END,
    CASE WHEN type.typcategory = 'A' THEN type.typelem END,
    field.atttypid,
    range.rngsubtype,
    multirange.rngtypid
  ]) AS inner_type (oid)
  WHERE inner_type.oid IS NOT NULL AND inner_type.oid <> 0
),
type_set AS (
  SELECT DISTINCT oid FROM types
),
user_types AS (
  SELECT type.*, format_type(type.oid, NULL) AS qualified
  FROM type_set
  JOIN pg_type AS type ON type.oid = type_set.oid
),
lines AS (
  SELECT roots.name || ' missing' AS line
  FROM roots WHERE roots.oid IS NULL
  UNION ALL
  SELECT named.qualified || ' relation kind=' || named.relkind::text
    || ' row_security=' || named.relrowsecurity
    || ' force_row_security=' || named.relforcerowsecurity
    || ' before_row_triggers=' || EXISTS (
      SELECT FROM pg_trigger AS trigger
      WHERE trigger.tgrelid = named.oid AND NOT trigger.tgisinternal
        AND trigger.tgtype & 3 = 3
    )
    || ' instead_row_triggers=' || EXISTS (
      SELECT FROM pg_trigger AS trigger
      WHERE trigger.tgrelid = named.oid AND NOT trigger.tgisinternal
        AND trigger.tgtype & 65 = 65
    )
    || ' check_option=' || coalesce((
      SELECT option.option_value
      FROM pg_options_to_table(named.reloptions) AS option
      WHERE option.option_name = 'check_option'
    ), '')
    || ' partition_key=' || coalesce(pg_get_partkeydef(named.oid), '')
    || ' partition_bound='
    || coalesce(pg_get_expr(named.relpartbound, named.oid), '')
  FROM named
  UNION ALL
  SELECT named.qualified || ' view definition=' || pg_get_viewdef(named.oid)
  FROM named
  WHERE named.relkind IN ('v', 'm')
  UNION ALL
  SELECT named.qualified || ' inherits '
    || quote_ident(namespace.nspname) || '.' || quote_ident(parent.relname)
  FROM named
  JOIN pg_inherits AS inherits ON inherits.inhrelid = named.oid
  JOIN pg_class AS parent ON parent.oid = inherits.inhparent
  JOIN pg_namespace AS namespace ON namespace.oid = parent.relnamespace
  UNION ALL
  SELECT columns.qualified || ' column ' || quote_ident(columns.attname)
    || ' position=' || columns.position
    || ' type=' || format_type(columns.atttypid, columns.atttypmod)
    || ' not_null=' || columns.attnotnull
    || ' has_default=' || columns.atthasdef
    || ' identity=' || columns.attidentity::text
    || ' generated=' || columns.attgenerated::text
    || ' generation=' || coalesce((
      SELECT pg_get_expr(generation.adbin, generation.adrelid)
      FROM pg_attrdef AS generation
      WHERE generation.adrelid = columns.attrelid
        AND generation.adnum = columns.attnum
        AND columns.attgenerated <> ''
    ), '')
  FROM columns
  UNION ALL
  SELECT named.qualified || ' constraint '
    || quote_ident(constraint_row.conname)
    || ' type=' || constraint_row.contype::text
    || ' validated=' || constraint_row.convalidated
    || ' definition=' || pg_get_constraintdef(constraint_row.oid)
  FROM named
  JOIN pg_constraint AS constraint_row ON constraint_row.conrelid = named.oid
  UNION ALL
  SELECT named.qualified || ' index ' || quote_ident(index_class.relname)
    || ' unique=' || index_row.indisunique
    || ' valid=' || index_row.indisvalid
    || ' definition=' || pg_get_indexdef(index_row.indexrelid)
  FROM named
  JOIN pg_index AS index_row ON index_row.indrelid = named.oid
  JOIN pg_class AS index_class ON index_class.oid = index_row.indexrelid
  UNION ALL
  SELECT named.qualified || ' rule ' || quote_ident(rule.rulename)
    || ' enabled=' || rule.ev_enabled::text
    || ' definition=' || pg_get_ruledef(rule.oid)
  FROM named
  JOIN pg_rewrite AS rule ON rule.ev_class = named.oid
  WHERE rule.rulename <> '_RETURN'
  UNION ALL
  SELECT named.qualified || ' policy ' || quote_ident(policy.polname)
    || ' command=' || policy.polcmd::text
    || ' permissive=' || policy.polpermissive
    || ' roles=' || (
      SELECT string_agg(roles.name, ',' ORDER BY roles.name COLLATE \"C\")
      FROM (
        SELECT CASE WHEN role_oid = 0 THEN 'public'
          ELSE quote_ident(pg_get_userbyid(role_oid)) END AS name
        FROM unnest(policy.polroles) AS role_oid
      ) AS roles
    )
    || ' using=' || coalesce(pg_get_expr(policy.polqual, policy.polrelid), '')
    || ' with_check='
    || coalesce(pg_get_expr(policy.polwithcheck, policy.polrelid), '')
  FROM named
  JOIN pg_policy AS policy ON policy.polrelid = named.oid
  UNION ALL
  SELECT user_types.qualified || ' domain base='
    || format_type(user_types.typbasetype, user_types.typtypmod)
    || ' not_null=' || user_types.typnotnull
  FROM user_types
  WHERE user_types.typtype = 'd'
  UNION ALL
  SELECT user_types.qualified || ' domain_constraint '
    || quote_ident(constraint_row.conname)
    || ' type=' || constraint_row.contype::text
    || ' validated=' || constraint_row.convalidated
    || ' definition=' || pg_get_constraintdef(constraint_row.oid)
  FROM user_types
  JOIN pg_constraint AS constraint_row
    ON constraint_row.contypid = user_types.oid
  UNION ALL
  SELECT user_types.qualified || ' enum labels=' || (
      SELECT string_agg(
        quote_literal(enum.enumlabel), ',' ORDER BY enum.enumsortorder
      )
      FROM pg_enum AS enum WHERE enum.enumtypid = user_types.oid
    )
  FROM user_types
  WHERE user_types.typtype = 'e'
  UNION ALL
  SELECT user_types.qualified || ' field ' || quote_ident(field.attname)
    || ' position=' || row_number() OVER (
      PARTITION BY field.attrelid ORDER BY field.attnum
    )
    || ' type=' || format_type(field.atttypid, field.atttypmod)
  FROM user_types
  JOIN pg_attribute AS field ON field.attrelid = user_types.typrelid
  WHERE user_types.typtype = 'c' AND field.attnum > 0
    AND NOT field.attisdropped
  UNION ALL
  SELECT user_types.qualified || ' range subtype='
    || format_type(range.rngsubtype, NULL)
  FROM user_types
  JOIN pg_range AS range ON range.rngtypid = user_types.oid
)
SELECT CASE
  WHEN concat(
    set_config('search_path', saved.search_path, true),
    set_config('TimeZone', saved.time_zone, true),
    set_config('DateStyle', saved.date_style, true),
    set_config('IntervalStyle', saved.interval_style, true),
    set_config('extra_float_digits', saved.extra_float_digits, true),
    set_config('quote_all_identifiers', saved.quote_all_identifiers, true),
    set_config('bytea_output', saved.bytea_output, true),
    set_config(
      'standard_conforming_strings', saved.standard_conforming_strings, true
    ),
    set_config('lc_monetary', saved.lc_monetary, true)
  ) IS NULL THEN NULL
  ELSE fingerprint.text
END
FROM saved
CROSS JOIN pinned
CROSS JOIN LATERAL (
  SELECT coalesce(
    string_agg(lines.line, chr(10) ORDER BY lines.line COLLATE \"C\"), ''
  ) AS text
  FROM lines
  WHERE pinned.settings IS NOT NULL
) AS fingerprint"

/// Get the schema fingerprint of tables
///
/// Runs `schema_fingerprint_sql` and gives the SHA-256 hash of its text.
/// The fingerprint changes when a fact that dream_model reads from the
/// catalog changes: see `schema_fingerprint_sql` for the list. It does not
/// change when only OIDs or the settings of the connection change.
///
/// Write each table as `schema.table`, as
/// `quote_ident(schema) || '.' || quote_ident(table)` writes it, for
/// example `public.users` or `public."Order"`. A table that does not
/// exist gives a fingerprint too: a different one.
///
/// ## Parameters
///
/// - `connection`: The connection from `connect` or `from_url`
/// - `tables`: The tables, each as `schema.table`
///
/// ## Returns
///
/// - `Ok(fingerprint)`: 64 lowercase hexadecimal digits
/// - `Error(QueryError)`: The query failed
///
/// ## Example
///
/// ### Get the fingerprint of the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_schema_fingerprint.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
///
/// pub fn users_fingerprint(
///   connection: postgres.Connection,
///   schema: String,
/// ) -> Result(String, postgres.QueryError) {
///   postgres.schema_fingerprint(connection, [schema <> ".users"])
/// }
/// ```
pub fn schema_fingerprint(
  connection: Connection,
  tables: List(String),
) -> Result(String, QueryError) {
  schema_fingerprint_sql
  |> query
  |> parameter(array(text, tables))
  |> returning(decode.at([0], decode.string))
  |> execute(connection)
  // The query always gives exactly one row.
  |> result.map(fn(returned) { sha256_hex(string.concat(returned.rows)) })
}

@external(erlang, "dream_postgres_schema_ffi", "sha256_hex")
fn sha256_hex(text: String) -> String

/// Check that the schema still matches the generated modules
///
/// The types of a generated module are true only for the schema that
/// dream_model generated it from. Call this function right after the pool
/// starts, with the fingerprint of each generated module. It computes the
/// fingerprint of the tables of each module with `schema_fingerprint`, and
/// compares it with the expected one.
///
/// ## Parameters
///
/// - `connection`: The connection from `connect` or `from_url`
/// - `expected`: The fingerprint of each generated module
///
/// ## Returns
///
/// - `Ok(Nil)`: Each module matches the schema
/// - `Error(SchemaChanged(mismatches))`: The modules of `mismatches` do
///   not match. Regenerate them with dream_model.
/// - `Error(SchemaUnreadable(module, error))`: The fingerprint query of
///   `module` failed. The check stops at that module.
///
/// ## See Also
///
/// - `format_schema_check_error`: a message for the error
///
/// ## Example
///
/// ### Check the generated modules at startup <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_check_schema.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/result
///
/// pub fn check_models(
///   connection: postgres.Connection,
///   models: List(postgres.SchemaFingerprint),
/// ) -> Result(Nil, String) {
///   postgres.check_schema(connection, models)
///   |> result.map_error(postgres.format_schema_check_error)
/// }
/// ```
pub fn check_schema(
  connection: Connection,
  expected: List(SchemaFingerprint),
) -> Result(Nil, SchemaCheckError) {
  use mismatches <- result.try(find_mismatches(connection, expected, []))
  case mismatches {
    [] -> Ok(Nil)
    _ -> Error(SchemaChanged(mismatches))
  }
}

fn find_mismatches(
  connection: Connection,
  remaining: List(SchemaFingerprint),
  found: List(SchemaMismatch),
) -> Result(List(SchemaMismatch), SchemaCheckError) {
  case remaining {
    [] -> Ok(list.reverse(found))
    [fingerprint, ..rest] -> {
      use hash <- result.try(
        schema_fingerprint(connection, fingerprint.tables)
        |> result.map_error(SchemaUnreadable(fingerprint.module, _)),
      )
      find_mismatches(connection, rest, add_mismatch(found, fingerprint, hash))
    }
  }
}

fn add_mismatch(
  found: List(SchemaMismatch),
  fingerprint: SchemaFingerprint,
  hash: String,
) -> List(SchemaMismatch) {
  case hash == fingerprint.hash {
    True -> found
    False -> [
      SchemaMismatch(
        module: fingerprint.module,
        tables: fingerprint.tables,
        expected: fingerprint.hash,
        found: hash,
      ),
      ..found
    ]
  }
}

/// Format a schema check error as a message
///
/// `SchemaChanged` gives a message that names each module and its tables,
/// and tells you to regenerate the modules with dream_model.
/// `SchemaUnreadable` gives a message that names the module and the query
/// error.
///
/// ## Parameters
///
/// - `error`: The error from `check_schema`
///
/// ## Returns
///
/// The message, one line for each module.
///
/// ## Example
///
/// ### Check the generated modules at startup <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_check_schema.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import gleam/result
///
/// pub fn check_models(
///   connection: postgres.Connection,
///   models: List(postgres.SchemaFingerprint),
/// ) -> Result(Nil, String) {
///   postgres.check_schema(connection, models)
///   |> result.map_error(postgres.format_schema_check_error)
/// }
/// ```
pub fn format_schema_check_error(error: SchemaCheckError) -> String {
  case error {
    SchemaChanged(mismatches) ->
      "The database schema changed after dream_model generated these modules. Regenerate them with dream_model:\n"
      <> string.join(list.map(mismatches, format_mismatch), "\n")
    SchemaUnreadable(module, query_error) ->
      "The schema fingerprint query of "
      <> module
      <> " failed: "
      <> string.inspect(query_error)
  }
}

fn format_mismatch(mismatch: SchemaMismatch) -> String {
  "- "
  <> mismatch.module
  <> " ("
  <> string.join(mismatch.tables, ", ")
  <> "): expected fingerprint "
  <> mismatch.expected
  <> ", found "
  <> mismatch.found
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
      |> dream_postgres_client.ip_version(dream_postgres_client.Ipv6)
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
  Ok(dream_postgres_client.ssl(config, ssl))
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
  dream_postgres_client.Config(
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

// The rules of `dream_postgres_client.url_config` in dream_postgres_client,
// which are the rules of libpq: a CA file makes `require` check the chain, as
// `verify-ca` does, and `sslrootcert=system` needs `verify-full`.
// `apply_ssl_mode` let only the four modes of `ssl_modes` through, so the last
// two branches are `verify-full`.
fn resolve_ssl(
  current: dream_postgres_client.Ssl,
  settings: SslSettings,
) -> Result(dream_postgres_client.Ssl, UrlError) {
  case settings.mode, settings.root_certificate {
    option.None, option.None -> Ok(current)
    option.Some("verify-full"), option.Some("system")
    | option.None, option.Some("system")
    -> Ok(dream_postgres_client.SslVerified)
    option.Some(mode), option.Some("system") ->
      Error(SslRootCertSystemNeedsVerifyFull(mode))
    option.None, option.Some(_path) -> Error(SslRootCertWithoutSslMode)
    option.Some("disable"), _ -> Ok(dream_postgres_client.SslDisabled)
    option.Some("require"), option.None ->
      Ok(dream_postgres_client.SslUnverified)
    option.Some("require"), option.Some(path)
    | option.Some("verify-ca"), option.Some(path)
    -> Ok(dream_postgres_client.SslVerifiedChainOnlyCaFile(path))
    option.Some("verify-ca"), option.None ->
      Ok(dream_postgres_client.SslVerifiedChainOnly)
    option.Some(_verify_full), option.None ->
      Ok(dream_postgres_client.SslVerified)
    option.Some(_verify_full), option.Some(path) ->
      Ok(dream_postgres_client.SslVerifiedCaFile(path))
  }
}
