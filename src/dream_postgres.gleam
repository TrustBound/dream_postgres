//// A PostgreSQL client: a pool of connections, queries with codecs that
//// are checked against the server before each run, and transactions as a
//// pipe of steps.
////
//// ### Create a post <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/posts.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres.{
////   type Connection, type PostgresError, type Row, column, named, one, parameter,
////   query, row,
//// }
//// import dream_postgres/codec.{int, text}
////
//// pub type Post {
////   Post(id: Int, user_id: Int, title: String)
//// }
////
//// /// Reads the columns id, user_id and title, in this order, into a Post.
//// pub fn post_row() -> Row(Post) {
////   use id <- column(int)
////   use user_id <- column(int)
////   use title <- column(text)
////   row(Post(id:, user_id:, title:))
//// }
////
//// pub fn create(
////   connection: Connection,
////   user_id: Int,
////   title: String,
//// ) -> Result(Post, Error(PostgresError)) {
////   "INSERT INTO posts (user_id, title) VALUES ($1, $2)
//// RETURNING id, user_id, title"
////   |> query
////   |> named("post.create")
////   |> parameter(int, user_id)
////   |> parameter(text, title)
////   |> one(post_row(), connection)
//// }
//// ```

import dream_errors.{type Error, Unavailable}
import dream_postgres/codec.{type Codec}
import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection as driver_connection
import dream_postgres/driver/listener
import dream_postgres/driver/login
import dream_postgres/driver/message
import dream_postgres/driver/pool.{type Pool}
import dream_postgres/driver/sink
import dream_postgres/driver/transport
import dream_postgres/error.{
  type Reason, type ServerError, type Severity, type UrlFault, CommitRolledBack,
  DirectNegotiationNeedsRequiredTls, InterceptorFailed, InvalidConfig,
  InvalidDatabaseUrl, OptionsInNestedTransaction,
  RootCertificateNeedsCertificateCheck, SystemRootCertificateNeedsVerifyFull,
  UnexpectedCommitAnswer,
}
import dream_postgres/interceptor.{
  type Answer, type Interceptor, type Outcome, type Request, CopyFromAnswer,
  CopyToAnswer, Request, Script, ScriptAnswer, StatementAnswer,
}
import dream_postgres/internal/cell.{type CommandResult, type ServerReport}
import dream_postgres/internal/copy
import dream_postgres/internal/copy_request
import dream_postgres/internal/database_url.{
  type DatabaseUrl, type RootCertificate, type SslMode, DefaultRootCertificate,
  RootCertificateFile, SystemRootCertificate,
}
import dream_postgres/internal/driver_executor
import dream_postgres/internal/query as internal_query
import dream_postgres/internal/replay.{type Replay}
import dream_postgres/internal/row_reader
import dream_postgres/internal/runner.{type LowestLayer}
import dream_postgres/recorder.{type Recorder}
import dream_postgres/secrets.{type Secrets}
import dream_postgres/sql_state.{type SqlState}
import dream_postgres/transaction.{type HasSteps, type Isolation, type NoSteps}
import gleam/erlang/process.{type Monitor, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string

// --- Types ----------------------------------------------------------------------

/// Everything that is known about a failure of dream_postgres. See
/// `dream_postgres/error`.
pub type PostgresError =
  error.PostgresError

/// A query: the SQL, its parameters, and an optional name.
pub type Query =
  internal_query.Query

/// How to read one row of a result into a value.
pub type Row(a) =
  row_reader.Row(a)

/// A connection to PostgreSQL: a pool, or the one connection that a
/// transaction or `with_connection` holds. Every query function takes it.
pub opaque type Connection {
  /// Each call holds a connection of the pool for its run. The pool
  /// carries the settings, so a handle made from a name has them too.
  /// `added_interceptors` run after the interceptors of the config.
  Pooled(pool: Pool(Settings), added_interceptors: List(Interceptor))
  /// One connection, held for a callback.
  OneConnection(held: HeldConnection, transaction_level: TransactionLevel)
  /// The connection of a recorder in playback mode, with no database:
  /// after the interceptors, the replay answers each request.
  Replayed(
    replay: Replay,
    interceptors: List(Interceptor),
    secrets: Secrets,
    recorder: Recorder,
  )
}

/// The settings that each call on a pool needs. The pool carries them.
pub opaque type Settings {
  Settings(
    host: String,
    port: Int,
    query_timeout_milliseconds: Int,
    checkout_timeout_milliseconds: Int,
    interceptors: List(Interceptor),
    /// The interceptors that run after all others, also after the
    /// interceptors that `with_interceptor` adds: the interceptor of a
    /// recorder in record mode.
    lowest_interceptors: List(Interceptor),
    secrets: Secrets,
    /// The recorder of the pool, which `stop` stops.
    recorder: Option(Recorder),
    /// What answers each request of a pool with no database: the replay of
    /// a recorder in playback mode under a supervisor.
    replay: Option(Replay),
  )
}

/// One wait before a connection tries to connect again.
pub type ReconnectStep {
  ReconnectStep(
    /// The number of failed attempts so far: 0 for the first wait.
    attempt: Int,
    /// The first delay, doubled for each failed attempt, up to the longest
    /// delay.
    capped_delay_milliseconds: Int,
    /// The wait before the previous attempt: 0 for the first wait.
    previous_wait_milliseconds: Int,
  )
}

/// The default reconnect strategy, "full jitter": a random wait from 0 to
/// the capped delay of the step. Connections that lost the server at the
/// same moment then come back at different moments.
pub fn full_jitter(step: ReconnectStep) -> Int {
  driver_connection.full_jitter(driver_connection.BackoffStep(
    attempt: step.attempt,
    capped_delay_milliseconds: step.capped_delay_milliseconds,
    previous_wait_milliseconds: step.previous_wait_milliseconds,
  ))
}

/// One connection, held for a callback: what answers its requests, and
/// the interceptors that each request goes through first.
type HeldConnection {
  HeldConnection(session: Session, interceptors: List(Interceptor))
}

/// What answers the requests of a held connection.
type Session {
  /// A connection of a pool, with the settings of the pool.
  DatabaseSession(
    connection: driver_connection.Connection,
    catalog: Catalog,
    settings: Settings,
  )
  /// A connection with no database.
  ReplaySession(replay: Replay, secrets: Secrets)
}

type TransactionLevel {
  /// No transaction is open on the connection.
  NoTransaction
  /// A transaction is open, inside `savepoints` savepoints of nested
  /// transactions.
  InTransaction(savepoints: Int)
}

// --- Config ---------------------------------------------------------------------

/// The settings of a pool. Build one with `default_config` and the
/// functions that set one field each.
///
/// ### Start a pool of 15 connections <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_app_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, database, default_config, host, password,
///   pool_size, start, user,
/// }
///
/// pub fn start_app_pool(
///   app_password: String,
/// ) -> Result(Connection, Error(PostgresError)) {
///   default_config()
///   |> host("localhost")
///   |> database("app")
///   |> user("app")
///   |> password(app_password)
///   |> pool_size(15)
///   |> start
/// }
/// ```
pub opaque type Config {
  Config(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    pool_size: Int,
    query_timeout_milliseconds: Int,
    checkout_timeout_milliseconds: Int,
    interceptors: List(Interceptor),
    secrets: Secrets,
    recorder: Option(Recorder),
    reconnect_first_delay_milliseconds: Int,
    reconnect_longest_delay_milliseconds: Int,
    reconnect_strategy: fn(ReconnectStep) -> Int,
    tls: Tls,
    statement_cache: StatementCache,
    notices: Option(Subject(ServerNotice)),
    pool_events: Option(Subject(PoolEvent)),
    connect_timeout_milliseconds: Int,
    setup_timeout_milliseconds: Int,
    cancel_timeout_milliseconds: Int,
    health_check_interval_milliseconds: Int,
    return_rollback_timeout_milliseconds: Int,
  )
}

/// The default config: host `localhost`, port 5432, database `postgres`,
/// user `postgres`, no password, 10 connections, 5 seconds for each query
/// and for each wait for a free connection, reconnects with full jitter
/// from 100 ms up to 10 seconds, TLS that checks the certificate of the
/// server against the authorities of the system and the host name, a
/// cache of 512 prepared statements on each connection, no subject for
/// notices or pool events, 5 seconds for each connect, 10 seconds for
/// each setup, 2 seconds for each cancel, 30 seconds between health
/// checks, and 5 seconds for the rollback when a call gives back a
/// connection.
///
/// ### Start a pool on a host <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_pool_on.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, default_config, host, start,
/// }
///
/// pub fn start_pool_on(
///   server_host: String,
/// ) -> Result(Connection, Error(PostgresError)) {
///   default_config()
///   |> host(server_host)
///   |> start
/// }
/// ```
pub fn default_config() -> Config {
  Config(
    host: "localhost",
    port: 5432,
    database: "postgres",
    user: "postgres",
    password: None,
    pool_size: 10,
    query_timeout_milliseconds: 5000,
    checkout_timeout_milliseconds: 5000,
    interceptors: [],
    secrets: secrets.new(),
    recorder: None,
    reconnect_first_delay_milliseconds: 100,
    reconnect_longest_delay_milliseconds: 10_000,
    reconnect_strategy: full_jitter,
    tls: TlsRequired(
      check: CheckAuthorityAndHost(SystemAuthorities),
      direct: False,
    ),
    statement_cache: CacheStatements(limit: 512),
    notices: None,
    pool_events: None,
    connect_timeout_milliseconds: 5000,
    setup_timeout_milliseconds: 10_000,
    cancel_timeout_milliseconds: 2000,
    health_check_interval_milliseconds: 30_000,
    return_rollback_timeout_milliseconds: 5000,
  )
}

/// Sets the host name or the IP address of the server.
pub fn host(config: Config, host: String) -> Config {
  Config(..config, host:)
}

/// Sets the port of the server.
pub fn port(config: Config, port: Int) -> Config {
  Config(..config, port:)
}

/// Sets the database.
pub fn database(config: Config, database: String) -> Config {
  Config(..config, database:)
}

/// Sets the database user.
pub fn user(config: Config, user: String) -> Config {
  Config(..config, user:)
}

/// Sets the password of the user.
pub fn password(config: Config, password: String) -> Config {
  Config(..config, password: Some(password))
}

/// Sets the number of connections of the pool.
pub fn pool_size(config: Config, pool_size: Int) -> Config {
  Config(..config, pool_size:)
}

/// Sets the longest time that one query, or one command of a
/// transaction, may take.
pub fn query_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, query_timeout_milliseconds: milliseconds)
}

/// Sets the longest time that a call waits for a free connection.
pub fn checkout_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, checkout_timeout_milliseconds: milliseconds)
}

/// Sets the longest time in milliseconds of each TCP connect, TLS answer
/// and TLS handshake of a new connection. The default is 5000. A value
/// below 1 is `InvalidConfig` at `start` and at `supervised`.
pub fn connect_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, connect_timeout_milliseconds: milliseconds)
}

/// Sets the longest time in milliseconds of one setup of a new
/// connection: the TCP connect, TLS and the login together. The default
/// is 10_000. A value below 1 is `InvalidConfig` at `start` and at
/// `supervised`.
pub fn setup_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, setup_timeout_milliseconds: milliseconds)
}

/// Sets the longest time in milliseconds of the cancel after a query
/// timeout. When the cancel takes longer, the pool closes and replaces
/// the connection. The default is 2000. A value below 1 is
/// `InvalidConfig` at `start` and at `supervised`.
pub fn cancel_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, cancel_timeout_milliseconds: milliseconds)
}

/// Sets the time in milliseconds between two health checks of a
/// connection that was free and unused for the whole interval. The
/// default is 30_000. A value below 1 is `InvalidConfig` at `start` and
/// at `supervised`.
pub fn health_check_interval(config: Config, milliseconds: Int) -> Config {
  Config(..config, health_check_interval_milliseconds: milliseconds)
}

/// Sets the longest time in milliseconds of the `ROLLBACK` that the pool
/// sends when a call gives back a connection with a transaction open.
/// When the rollback takes longer, the pool replaces the connection. The
/// default is 5000. A value below 1 is `InvalidConfig` at `start` and at
/// `supervised`.
pub fn return_rollback_timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, return_rollback_timeout_milliseconds: milliseconds)
}

/// Sets the delays of the reconnect backoff: the delay of the first
/// attempt, doubled for each attempt after it up to the longest delay.
pub fn reconnect_delays(
  config: Config,
  first_delay_milliseconds first: Int,
  longest_delay_milliseconds longest: Int,
) -> Config {
  Config(
    ..config,
    reconnect_first_delay_milliseconds: first,
    reconnect_longest_delay_milliseconds: longest,
  )
}

/// Sets how long a connection waits before each attempt to connect again.
/// The function gets the step and gives the wait in milliseconds; the
/// wait is kept between 0 and the longest delay. The default is
/// `full_jitter`.
pub fn reconnect_strategy(
  config: Config,
  strategy: fn(ReconnectStep) -> Int,
) -> Config {
  Config(..config, reconnect_strategy: strategy)
}

/// Adds an interceptor after the ones added before. Each query and script
/// of the pool, also in a transaction, goes through the interceptors in
/// the order they were added. See `dream_postgres/interceptor`.
///
/// ### Add two interceptors to the config <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_tagged_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type Connection, type PostgresError, intercept, start,
/// }
/// import snippets/request_tagging.{log_slow_queries, tag_with_app_name}
///
/// pub fn start_tagged_pool(
///   config: Config,
/// ) -> Result(Connection, Error(PostgresError)) {
///   config
///   |> intercept(tag_with_app_name)
///   |> intercept(log_slow_queries)
///   |> start
/// }
/// ```
pub fn intercept(config: Config, added_interceptor: Interceptor) -> Config {
  Config(
    ..config,
    interceptors: list.append(config.interceptors, [added_interceptor]),
  )
}

/// Sets the secrets of the config. They apply to each copy of a request
/// that leaves the process: the recording of a recorder, the SQL of a
/// `PostgresError`, and the text of the trace span of each statement. The
/// database and the app always get the real values. See
/// `dream_postgres/secrets`.
///
/// ### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres.{type Config, intercept, secrets}
/// import dream_postgres/codec.{text}
/// import dream_postgres/secrets
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The config of the app, shared by the app and its tests. `server` holds
/// /// the settings of the server of each run.
/// pub fn app_config(server: Config) -> Config {
///   server
///   |> intercept(tag_with_app_name)
///   |> secrets(
///     secrets.new()
///     |> secrets.text("sk_live_", with: "sk_test_")
///     |> secrets.column("token", text, with: "token-redacted"),
///   )
/// }
/// ```
pub fn secrets(config: Config, declared: Secrets) -> Config {
  Config(..config, secrets: declared)
}

/// Attaches a started recorder: `start` and `supervised` then make the
/// connection of the recorder's mode. In `Record` mode it is a pool with
/// the recorder after all other interceptors. In `Playback` mode it has no
/// database: `start` gives a connection that the recording answers, and
/// `supervised` gives a pool under the name that starts no connection and
/// answers from the recording. In `Passthrough` mode it is a pool, and
/// nothing is saved. `stop` of the connection stops the recorder.
///
/// ### Connect the code under test to its recording <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/run_create_api_key.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type Config, type PostgresError, record, start, stop}
/// import dream_postgres/recorder.{type Recorder}
/// import gleam/result
/// import snippets/app_config.{app_config}
/// import snippets/create_api_key.{type ApiKey, create_api_key}
/// import snippets/with_api_keys_table.{with_api_keys_table}
///
/// /// One run of the test: in `Record` mode on the database of the app
/// /// config, in `Playback` mode on the recording alone.
/// pub fn run_create_api_key(
///   server: Config,
///   test_recorder: Recorder,
///   owner: Int,
/// ) -> Result(ApiKey, Error(PostgresError)) {
///   use connection <- result.try(
///     app_config(server)
///     |> record(test_recorder)
///     |> start,
///   )
///   let created =
///     with_api_keys_table(connection, create_api_key(_, owner, "s3cret"))
///   stop(connection)
///   created
/// }
/// ```
pub fn record(config: Config, test_recorder: Recorder) -> Config {
  Config(..config, recorder: Some(test_recorder))
}

/// How a connection uses TLS.
pub type Tls {
  /// No TLS: the connection is plain TCP. Use it only on a network that
  /// nobody else can read.
  TlsOff
  /// TLS when the server has it, and plain TCP when the server refuses
  /// it. The certificate of the server is not checked, so this keeps out
  /// a reader of the network, and not a server that pretends to be the
  /// right one.
  TlsPreferred
  /// TLS, or no connection. `check` says how the certificate of the
  /// server is checked. With `direct`, the connection starts TLS at once,
  /// as PostgreSQL 17 and later can, and does not ask the server first.
  TlsRequired(check: CertificateCheck, direct: Bool)
}

/// How a connection checks the certificate of the server.
pub type CertificateCheck {
  /// No check: any certificate is taken. Only the traffic is encrypted.
  NoCertificateCheck
  /// The certificate must come from one of the authorities.
  CheckAuthority(authorities: Authorities)
  /// The certificate must come from one of the authorities, and name the
  /// host of the config.
  CheckAuthorityAndHost(authorities: Authorities)
}

/// The certificate authorities that a connection trusts.
pub type Authorities {
  /// The authorities of the operating system.
  SystemAuthorities
  /// The authorities in a PEM file.
  AuthorityFile(path: String)
  /// The authorities as DER certificates.
  AuthorityCertificates(certificates: List(BitArray))
}

/// Sets how each connection uses TLS. The default is `TlsRequired` with
/// `CheckAuthorityAndHost(SystemAuthorities)`, so a server with no TLS or
/// with a certificate that the system does not trust gives no
/// connection.
///
/// ### Trust a private certificate authority <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_pool_with_private_authority.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, AuthorityFile, CheckAuthorityAndHost,
///   TlsRequired, default_config, host, start, tls,
/// }
///
/// pub fn start_pool_with_private_authority(
///   server_host: String,
/// ) -> Result(Connection, Error(PostgresError)) {
///   default_config()
///   |> host(server_host)
///   |> tls(TlsRequired(
///     check: CheckAuthorityAndHost(AuthorityFile("/etc/ssl/database-ca.crt")),
///     direct: False,
///   ))
///   |> start
/// }
/// ```
pub fn tls(config: Config, tls: Tls) -> Config {
  Config(..config, tls:)
}

/// The config of a `postgres://` or `postgresql://` URL, read as libpq
/// reads it:
/// `postgresql://user:password@host:port/database?sslmode=verify-full`.
///
/// The user, the password and the database are percent-decoded. An IPv6
/// host goes in square brackets. A part that the URL does not give keeps
/// the value of `default_config`, except the database: with no database,
/// the database is the user, as in libpq. The URL must name a host: with
/// no host, libpq uses a Unix socket, which dream_postgres does not have.
/// With no `sslmode`, the TLS is
/// the TLS of `default_config`, which is `verify-full`.
///
/// The query parameters are the ones of libpq that a config has a setting
/// for:
///
/// - `sslmode`: `disable` gives `TlsOff`, `prefer` gives `TlsPreferred`,
///   `require` gives `TlsRequired` with `NoCertificateCheck`, `verify-ca`
///   gives `CheckAuthority`, and `verify-full` gives
///   `CheckAuthorityAndHost`. `allow` is not supported.
/// - `sslrootcert`: the PEM file of the authorities, or `system` for the
///   authorities of the operating system, which needs `verify-full`. With
///   a file, `require` checks the authority, as in libpq.
/// - `sslnegotiation`: `postgres`, or `direct` for a TLS start with no
///   request first, which needs `require` or a stronger mode.
///
/// Any other parameter, such as `connect_timeout`, more than one host, no
/// host, a Unix socket directory as the host, or a port outside 1 to 65535
/// gives
/// `InvalidConfig(InvalidDatabaseUrl(fault))` of kind `Invalid`. No fault
/// and no message holds the password.
///
/// ### Start a pool from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/database_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, config_from_url, pool_size, start,
/// }
/// import gleam/result
///
/// /// Starts a pool of 4 connections from a database URL, such as
/// /// `postgresql://app:secret@db.example.com:5432/app?sslmode=verify-full`.
/// pub fn connect_with_url(
///   database_url: String,
/// ) -> Result(Connection, Error(PostgresError)) {
///   use config <- result.try(config_from_url(database_url))
///   config
///   |> pool_size(4)
///   |> start
/// }
/// ```
pub fn config_from_url(url: String) -> Result(Config, Error(PostgresError)) {
  database_url.parse(url)
  |> result.try(config_of_url)
  |> result.map_error(fn(fault) {
    failure_with_no_query(InvalidConfig(InvalidDatabaseUrl(fault:)))
  })
}

fn config_of_url(url: DatabaseUrl) -> Result(Config, UrlFault) {
  use url_tls <- result.try(tls_of_url(url))
  let default = default_config()
  let url_user = option.unwrap(url.user, default.user)
  Ok(
    Config(
      ..default,
      host: option.unwrap(url.host, default.host),
      port: option.unwrap(url.port, default.port),
      user: url_user,
      password: url.password,
      database: option.unwrap(url.database, url_user),
      tls: url_tls,
    ),
  )
}

fn tls_of_url(url: DatabaseUrl) -> Result(Tls, UrlFault) {
  use checked_tls <- result.try(certificate_tls(
    url.ssl_mode,
    url.root_certificate,
  ))
  negotiated_tls(checked_tls, url.direct_negotiation)
}

// The TLS of an `sslmode` and an `sslrootcert`, as libpq uses them.
fn certificate_tls(
  mode: SslMode,
  root_certificate: RootCertificate,
) -> Result(Tls, UrlFault) {
  case mode, root_certificate {
    database_url.Disable, DefaultRootCertificate -> Ok(TlsOff)
    database_url.Prefer, DefaultRootCertificate -> Ok(TlsPreferred)
    database_url.Require, DefaultRootCertificate ->
      Ok(required_tls(NoCertificateCheck))
    database_url.VerifyCa, DefaultRootCertificate ->
      Ok(required_tls(CheckAuthority(SystemAuthorities)))
    database_url.Require, RootCertificateFile(path:)
    | database_url.VerifyCa, RootCertificateFile(path:)
    -> Ok(required_tls(CheckAuthority(AuthorityFile(path))))
    database_url.VerifyFull, DefaultRootCertificate
    | database_url.VerifyFull, SystemRootCertificate
    -> Ok(required_tls(CheckAuthorityAndHost(SystemAuthorities)))
    database_url.VerifyFull, RootCertificateFile(path:) ->
      Ok(required_tls(CheckAuthorityAndHost(AuthorityFile(path))))
    database_url.Disable, RootCertificateFile(..) ->
      Error(RootCertificateNeedsCertificateCheck(mode: "disable"))
    database_url.Prefer, RootCertificateFile(..) ->
      Error(RootCertificateNeedsCertificateCheck(mode: "prefer"))
    database_url.Disable, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "disable"))
    database_url.Prefer, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "prefer"))
    database_url.Require, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "require"))
    database_url.VerifyCa, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "verify-ca"))
  }
}

fn required_tls(check: CertificateCheck) -> Tls {
  TlsRequired(check:, direct: False)
}

// `sslnegotiation=direct` starts TLS at once, so it needs TLS that is
// required. Only `disable` gives `TlsOff`, and only `prefer` gives
// `TlsPreferred`.
fn negotiated_tls(tls: Tls, direct: Bool) -> Result(Tls, UrlFault) {
  case tls, direct {
    TlsRequired(check:, ..), _ -> Ok(TlsRequired(check:, direct:))
    TlsOff, False | TlsPreferred, False -> Ok(tls)
    TlsOff, True -> Error(DirectNegotiationNeedsRequiredTls(mode: "disable"))
    TlsPreferred, True ->
      Error(DirectNegotiationNeedsRequiredTls(mode: "prefer"))
  }
}

/// How each connection keeps its prepared statements.
pub type StatementCache {
  /// Each statement is prepared one time under a name, and runs again by
  /// that name. Each connection keeps at most `limit` statements, and
  /// closes the one used least recently to make space.
  CacheStatements(limit: Int)
  /// Each statement is prepared again for each run, with no name. Use it
  /// behind a pooler such as PgBouncer in transaction mode, where the next
  /// transaction can run on another server session.
  NoStatementCache
}

/// Sets how each connection keeps its prepared statements. The default is
/// `CacheStatements(512)`.
///
/// ### Prepare each statement again for each run <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_pool_without_statement_cache.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type Connection, type PostgresError, NoStatementCache, start,
///   statement_cache,
/// }
///
/// pub fn start_pool_without_statement_cache(
///   config: Config,
/// ) -> Result(Connection, Error(PostgresError)) {
///   config
///   |> statement_cache(NoStatementCache)
///   |> start
/// }
/// ```
pub fn statement_cache(
  config: Config,
  statement_cache: StatementCache,
) -> Config {
  Config(..config, statement_cache:)
}

/// A notice of the server, such as a `NOTICE` or a `WARNING` that a
/// statement raised. It has the fields of `error.ServerError`.
pub type ServerNotice {
  ServerNotice(
    severity: Severity,
    sql_state: SqlState,
    message: String,
    detail: Option(String),
    hint: Option(String),
    /// A 1-based character position in the query text.
    position: Option(Int),
    internal_position: Option(Int),
    internal_query: Option(String),
    /// The call stack of the notice, for example the function that raised
    /// it.
    context: Option(String),
    schema: Option(String),
    table: Option(String),
    column: Option(String),
    data_type: Option(String),
    constraint: Option(String),
    file: Option(String),
    line: Option(Int),
    routine: Option(String),
    /// The severity in the server's language.
    localized_severity: String,
    /// Any field that this record does not name, with its type byte.
    other_fields: List(#(Int, String)),
  )
}

/// Sends each notice of each connection of the pool to the subject, as it
/// arrives: the notices of the statements, and the notices that come
/// between them. A notice that came before the pool stopped reaches the
/// subject before `stop` returns.
///
/// ### Send the notices to a subject <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_pool_with_notices.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type Connection, type PostgresError, type ServerNotice, notices,
///   start,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// pub fn start_pool_with_notices(
///   config: Config,
///   notice_subject: Subject(ServerNotice),
/// ) -> Result(Connection, Error(PostgresError)) {
///   config
///   |> notices(notice_subject)
///   |> start
/// }
/// ```
pub fn notices(config: Config, subject: Subject(ServerNotice)) -> Config {
  Config(..config, notices: Some(subject))
}

/// What the pool does with its connections. Each event names the slot of
/// the connection: its place in the pool, from 0.
pub type PoolEvent {
  /// The connection of the slot connected and logged in.
  Connected(slot: Int)
  /// The connection of the slot lost its session. It connects again.
  Disconnected(slot: Int, reason: Error(PostgresError))
  /// The connection of the slot connected and logged in again after a
  /// loss.
  Reconnected(slot: Int)
  /// A connect or a reconnect of the slot failed.
  ConnectFailed(slot: Int, error: Error(PostgresError))
  /// The pool stops the connection process of the slot, after a failed
  /// rollback or health check, or after the process exited, and starts a
  /// new one.
  Replacing(slot: Int)
  /// The connection of the slot is free for the next call.
  Free(slot: Int)
  /// A call found no free connection, and waits with `count` calls.
  Waiting(count: Int)
  /// A call holds the connection of the slot.
  Held(slot: Int)
  /// The call that held the connection of the slot ended.
  Returned(slot: Int)
  /// The pool gave a call no connection.
  Refused(error: Error(PostgresError))
  /// The pool started to stop.
  Stopping
}

/// Sends each event of the pool to the subject, in the order the pool
/// changed. An event that came before the pool stopped reaches the
/// subject before `stop` returns.
///
/// ### Send the pool events to a subject <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_pool_with_events.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type Connection, type PoolEvent, type PostgresError, pool_events,
///   start,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// pub fn start_pool_with_events(
///   config: Config,
///   event_subject: Subject(PoolEvent),
/// ) -> Result(Connection, Error(PostgresError)) {
///   config
///   |> pool_events(event_subject)
///   |> start
/// }
/// ```
pub fn pool_events(config: Config, subject: Subject(PoolEvent)) -> Config {
  Config(..config, pool_events: Some(subject))
}

// --- Start and stop -------------------------------------------------------------

/// Checks the config and starts the pool, linked to the calling process.
/// The connections connect in the background: a server that does not
/// answer shows as an error of the first query. For a pool under a
/// supervisor, use `supervised`.
pub fn start(config: Config) -> Result(Connection, Error(PostgresError)) {
  use _checked <- result.try(check_times(config))
  case recorder_attachment(config) {
    recorder.RecordingPool(interceptor:) -> start_pool(config, [interceptor])
    recorder.PlainPool -> start_pool(config, [])
    recorder.NoPool(replay:, recorder: test_recorder) ->
      Ok(Replayed(
        replay:,
        interceptors: config.interceptors,
        secrets: config.secrets,
        recorder: test_recorder,
      ))
  }
}

// Refuses a time setting below 1 millisecond, before anything starts.
fn check_times(config: Config) -> Result(Nil, Error(PostgresError)) {
  use <- refuse_below_one(
    config.connect_timeout_milliseconds,
    error.InvalidConnectTimeout,
  )
  use <- refuse_below_one(
    config.setup_timeout_milliseconds,
    error.InvalidSetupTimeout,
  )
  use <- refuse_below_one(
    config.cancel_timeout_milliseconds,
    error.InvalidCancelTimeout,
  )
  use <- refuse_below_one(
    config.health_check_interval_milliseconds,
    error.InvalidHealthCheckInterval,
  )
  use <- refuse_below_one(
    config.return_rollback_timeout_milliseconds,
    error.InvalidReturnRollbackTimeout,
  )
  Ok(Nil)
}

fn refuse_below_one(
  milliseconds: Int,
  fault: fn(Int) -> error.ConfigFault,
  next: fn() -> Result(Nil, Error(PostgresError)),
) -> Result(Nil, Error(PostgresError)) {
  case milliseconds < 1 {
    True -> Error(failure_with_no_query(InvalidConfig(fault(milliseconds))))
    False -> next()
  }
}

// How the recorder of the config, if any, takes part in the connection.
fn recorder_attachment(config: Config) -> recorder.Attachment {
  config.recorder
  |> option.map(recorder.attachment(_, config.secrets))
  |> option.unwrap(recorder.PlainPool)
}

fn start_pool(
  config: Config,
  lowest_interceptors: List(Interceptor),
) -> Result(Connection, Error(PostgresError)) {
  use checked <- result.try(pool_config(config, lowest_interceptors, None))
  pool.start(checked, config.pool_size)
  |> result.map(Pooled(_, added_interceptors: []))
  |> result.map_error(fn(start_error) {
    failure_with_no_query(driver_executor.start_error_reason(start_error))
  })
}

/// The name of a pool that runs under a supervisor. Make it one time when
/// the program starts, with `process.new_name("database")`: each name is
/// an atom.
pub type PoolName =
  process.Name(pool.PoolMessage(Settings))

/// The child specification of a pool under the app's supervisor, under
/// the name. After a restart the new pool takes the same name, so a
/// `named_connection` of it keeps working. The config is checked here,
/// so a wrong config is an error before the supervisor starts.
///
/// ### Start a pool under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/supervised_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type PoolName, type PostgresError, named_connection, one, query,
///   single, supervised,
/// }
/// import dream_postgres/codec.{text}
/// import dream_postgres/error.{describe}
/// import gleam/otp/actor
/// import gleam/otp/static_supervisor.{type Supervisor}
/// import gleam/result
///
/// /// Starts the app's supervisor with the pool under it. The pool runs
/// /// under `pool_name`, also after a restart.
/// pub fn start_supervisor(
///   config: Config,
///   pool_name: PoolName,
/// ) -> Result(actor.Started(Supervisor), String) {
///   use pool_child <- result.try(
///     supervised(config, name: pool_name)
///     |> result.map_error(describe),
///   )
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(pool_child)
///   |> static_supervisor.start
///   |> result.replace_error("the supervisor did not start")
/// }
///
/// /// Any process can reach the pool by its name.
/// pub fn current_database(
///   pool_name: PoolName,
/// ) -> Result(String, Error(PostgresError)) {
///   "SELECT current_database()"
///   |> query
///   |> one(single(text), named_connection(pool_name))
/// }
/// ```
pub fn supervised(
  config: Config,
  name name: PoolName,
) -> Result(ChildSpecification(Connection), Error(PostgresError)) {
  use _checked <- result.try(check_times(config))
  case recorder_attachment(config) {
    recorder.RecordingPool(interceptor:) ->
      pool_config(config, [interceptor], None)
      |> result.map(pool.supervised(_, config.pool_size, name))
    recorder.PlainPool ->
      pool_config(config, [], None)
      |> result.map(pool.supervised(_, config.pool_size, name))
    recorder.NoPool(replay:, ..) ->
      pool_config(config, [], Some(replay))
      |> result.map(pool.supervised_without_database(_, name))
  }
  |> result.map(supervision.map_data(_, Pooled(_, added_interceptors: [])))
}

/// The connection of the pool that runs under the name. It holds only the
/// name, so it stays valid when the supervisor restarts the pool. While
/// no pool runs under the name, each call fails with `PoolStopped`.
pub fn named_connection(name: PoolName) -> Connection {
  Pooled(pool.from_name(name), added_interceptors: [])
}

fn pool_config(
  config: Config,
  lowest_interceptors: List(Interceptor),
  replay: Option(Replay),
) -> Result(pool.PoolConfig(Settings), Error(PostgresError)) {
  Settings(
    host: config.host,
    port: config.port,
    query_timeout_milliseconds: config.query_timeout_milliseconds,
    checkout_timeout_milliseconds: config.checkout_timeout_milliseconds,
    interceptors: config.interceptors,
    lowest_interceptors:,
    secrets: config.secrets,
    recorder: config.recorder,
    replay:,
  )
  |> driver_pool_config(config, _)
}

/// The config of the driver pool for the config, with `attachment` as the
/// data of each connection.
@internal
pub fn driver_pool_config(
  config: Config,
  attachment: attachment,
) -> Result(pool.PoolConfig(attachment), Error(PostgresError)) {
  use address <- result.try(
    transport.address(config.host, config.port)
    |> result.map_error(fn(address_error) {
      failure_with_no_query(
        error.InvalidConfig(driver_executor.address_fault(address_error)),
      )
    }),
  )
  use login_config <- result.try(
    login.new(
      user: config.user,
      database: config.database,
      password: login_password(config.password),
      parameters: [],
      channel_binding: login.PreferChannelBinding,
      protocol_version: message.Protocol30,
    )
    |> result.map_error(fn(config_error) {
      failure_with_no_query(
        error.InvalidConfig(driver_executor.login_config_fault(config_error)),
      )
    }),
  )
  Ok(pool.PoolConfig(
    connection: driver_connection.ConnectionConfig(
      transport: transport.TransportConfig(
        address:,
        tls: transport_tls(config.tls),
        connect_timeout_milliseconds: config.connect_timeout_milliseconds,
        send_timeout_milliseconds: 5000,
      ),
      login: login_config,
      setup_timeout_milliseconds: config.setup_timeout_milliseconds,
      cancel_timeout_milliseconds: config.cancel_timeout_milliseconds,
      reconnect: driver_connection.Backoff(
        first_delay_milliseconds: config.reconnect_first_delay_milliseconds,
        longest_delay_milliseconds: config.reconnect_longest_delay_milliseconds,
        strategy: reconnect_strategy_of(config),
      ),
      events: None,
      notifications: None,
      notices: option.map(config.notices, sink.to(_, server_notice)),
      statements: statement_caching(config.statement_cache),
    ),
    health_check_interval_milliseconds: config.health_check_interval_milliseconds,
    health_check_deadline_milliseconds: 5000,
    rollback_deadline_milliseconds: config.return_rollback_timeout_milliseconds,
    shutdown_deadline_milliseconds: 5000,
    events: option.map(
      config.pool_events,
      sink.to(_, pool_event(_, config.host, config.port)),
    ),
    attachment:,
  ))
}

/// The TLS setting of the driver for the TLS of the config.
@internal
pub fn transport_tls(tls: Tls) -> transport.Tls {
  case tls {
    TlsOff -> transport.NoTls
    TlsPreferred -> transport.PreferTls
    TlsRequired(check:, direct:) ->
      transport.RequireTls(certificate_check(check), negotiation(direct))
  }
}

fn certificate_check(check: CertificateCheck) -> transport.CertificateCheck {
  case check {
    NoCertificateCheck -> transport.NoCertificateCheck
    CheckAuthority(authorities:) ->
      transport.CheckAuthority(transport_authorities(authorities))
    CheckAuthorityAndHost(authorities:) ->
      transport.CheckAuthorityAndHost(transport_authorities(authorities))
  }
}

fn transport_authorities(authorities: Authorities) -> transport.Authorities {
  case authorities {
    SystemAuthorities -> transport.SystemAuthorities
    AuthorityFile(path:) -> transport.AuthorityFile(path:)
    AuthorityCertificates(certificates:) ->
      transport.AuthorityCertificates(certificates:)
  }
}

fn negotiation(direct: Bool) -> transport.TlsNegotiation {
  case direct {
    True -> transport.DirectNegotiation
    False -> transport.PostgresNegotiation
  }
}

/// The statement setting of the driver for the statement cache of the
/// config.
@internal
pub fn statement_caching(
  statement_cache: StatementCache,
) -> driver_connection.StatementCaching {
  case statement_cache {
    CacheStatements(limit:) -> driver_connection.CacheStatements(limit:)
    NoStatementCache -> driver_connection.UnnamedStatements
  }
}

/// The notice of the client for a notice report of the driver.
@internal
pub fn server_notice(report: ServerReport) -> ServerNotice {
  let error.ServerError(
    severity:,
    sql_state:,
    message:,
    detail:,
    hint:,
    position:,
    internal_position:,
    internal_query:,
    context:,
    schema:,
    table:,
    column:,
    data_type:,
    constraint:,
    file:,
    line:,
    routine:,
    localized_severity:,
    other_fields:,
  ) = error.server_error_from_report(report)
  ServerNotice(
    severity:,
    sql_state:,
    message:,
    detail:,
    hint:,
    position:,
    internal_position:,
    internal_query:,
    context:,
    schema:,
    table:,
    column:,
    data_type:,
    constraint:,
    file:,
    line:,
    routine:,
    localized_severity:,
    other_fields:,
  )
}

/// The pool event of the client for a pool event of the driver. `host`
/// and `port` are the server of the pool, for a connect error.
@internal
pub fn pool_event(event: pool.PoolEvent, host: String, port: Int) -> PoolEvent {
  case event {
    pool.MemberConnected(slot:) -> Connected(slot:)
    pool.MemberDisconnected(slot:, error: end) ->
      Disconnected(
        slot:,
        reason: failure(None, None, driver_executor.connection_end_reason(end)),
      )
    pool.MemberReconnected(slot:) -> Reconnected(slot:)
    pool.MemberConnectFailed(slot:, error: connect_error) ->
      ConnectFailed(
        slot:,
        error: failure(
          None,
          None,
          error.ConnectFailed(driver_executor.connect_failure(
            connect_error,
            host,
            port,
          )),
        ),
      )
    pool.MemberReplacing(slot:) -> Replacing(slot:)
    pool.MemberFree(slot:) -> Free(slot:)
    pool.HoldWaiting(waiting:) -> Waiting(count: waiting)
    pool.MemberHeld(slot:) -> Held(slot:)
    pool.MemberReturned(slot:) -> Returned(slot:)
    pool.HoldRefused(error: hold_error) ->
      Refused(error: failure(
        None,
        None,
        driver_executor.checkout_error_reason(hold_error, host, port),
      ))
    pool.PoolStopping -> Stopping
  }
}

fn reconnect_strategy_of(
  config: Config,
) -> fn(driver_connection.BackoffStep) -> Int {
  fn(step: driver_connection.BackoffStep) {
    config.reconnect_strategy(ReconnectStep(
      attempt: step.attempt,
      capped_delay_milliseconds: step.capped_delay_milliseconds,
      previous_wait_milliseconds: step.previous_wait_milliseconds,
    ))
  }
}

fn login_password(password: Option(String)) -> login.Password {
  case password {
    Some(text) -> login.password(text)
    None -> login.no_password()
  }
}

fn failure_with_no_query(reason: Reason) -> Error(PostgresError) {
  failure(None, None, reason)
}

/// Stops the pool and closes its connections, then stops the recorder of
/// the config, if any. The holds that run get at most 5 seconds to
/// finish. A held connection belongs to its pool, so `stop` of one does
/// nothing.
pub fn stop(connection: Connection) -> Nil {
  case connection {
    Pooled(pool:, added_interceptors: _) -> {
      let pool_recorder =
        pool.attachment(pool)
        |> option.from_result
        |> option.then(fn(settings) { settings.recorder })
      pool.stop(pool, 5000)
      stop_recorder(pool_recorder)
    }
    OneConnection(..) -> Nil
    Replayed(recorder: test_recorder, ..) -> recorder.stop(test_recorder)
  }
}

fn stop_recorder(pool_recorder: Option(Recorder)) -> Nil {
  case pool_recorder {
    Some(test_recorder) -> recorder.stop(test_recorder)
    None -> Nil
  }
}

// --- Queries --------------------------------------------------------------------

/// A query of the SQL, with no parameters yet.
pub fn query(sql: String) -> Query {
  internal_query.query(sql)
}

/// Adds the next parameter: the first call gives `$1`, the next `$2`.
pub fn parameter(query: Query, codec: Codec(a), value: a) -> Query {
  internal_query.parameter(query, codec, value)
}

/// Adds the next parameter as `parameter` does, and marks it secret, for
/// a value such as a password or a token. A live run sends it as any other
/// parameter. A recorder never saves its value: the recording keeps only
/// its codec, and playback takes any value with that codec at that
/// position. `string.inspect` of the request that an interceptor gets
/// shows the parameter as `Secret`, never its value.
///
/// ### Check a password against its hash <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/password_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, named, one, parameter, query,
///   secret_parameter, single,
/// }
/// import dream_postgres/codec.{bool, text}
///
/// /// Checks a password against its stored SHA-256 hash in hex. The password
/// /// is a secret parameter, so a recording of this query never holds it.
/// pub fn password_matches(
///   connection: Connection,
///   password: String,
///   stored_hash: String,
/// ) -> Result(Bool, Error(PostgresError)) {
///   "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
///   |> query
///   |> named("password.matches")
///   |> secret_parameter(text, password)
///   |> parameter(text, stored_hash)
///   |> one(single(bool), connection)
/// }
/// ```
pub fn secret_parameter(query: Query, codec: Codec(a), value: a) -> Query {
  internal_query.secret_parameter(query, codec, value)
}

/// Gives the query a name, which errors and logs show with the SQL.
pub fn named(query: Query, name: String) -> Query {
  internal_query.named(query, name)
}

/// Reads the next column with the codec. A reader that uses `column` reads
/// every column, in order.
pub fn column(codec: Codec(a), next: fn(a) -> Row(b)) -> Row(b) {
  row_reader.column(codec, next)
}

/// Reads the column at a position. Positions count from 1, like `$1`.
pub fn column_at(
  position: Int,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  row_reader.column_at(position, codec, next)
}

/// Reads the column with this name. The name must belong to one column
/// only.
pub fn column_named(
  name: String,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  row_reader.column_named(name, codec, next)
}

/// The value of a row, after its columns are read.
pub fn row(value: a) -> Row(a) {
  row_reader.row(value)
}

/// Reads a result of one column with the codec.
pub fn single(codec: Codec(a)) -> Row(a) {
  row_reader.single(codec)
}

/// Runs a query and reads every row.
pub fn all(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(List(a), Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.all(query, reader, executor, interceptors)
}

/// Runs a query that gives exactly one row, and reads it. No row is
/// `NotFound`, and more than one row is `Failed`.
pub fn one(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(a, Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.one(query, reader, executor, interceptors)
}

/// Runs a query that gives at most one row, and reads it. More than one
/// row is `Failed`.
pub fn maybe_one(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(Option(a), Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.maybe_one(query, reader, executor, interceptors)
}

/// Runs a command and gives the row count of its tag, for example 3 for
/// `UPDATE 3`.
pub fn affected(
  query: Query,
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.affected(query, executor, interceptors)
}

// --- The boot check -------------------------------------------------------------

/// A query and how its rows are read, for `verify`. Make one with
/// `checked` for a query whose rows are read, or `checked_command` for a
/// command whose rows are not read.
pub opaque type QueryCheck {
  QueryCheck(check: fn(runner.Executor) -> Result(Nil, Error(PostgresError)))
}

/// The check of a query whose rows `reader` reads, as `all`, `one` and
/// `maybe_one` read them.
///
/// The check uses the codecs of the parameters, not their values: a query
/// that is built only for the check gives each parameter
/// `codec.placeholder` of its codec.
///
/// ### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres.{
///   type QueryCheck, checked, checked_command, column, named, parameter, query,
///   row,
/// }
/// import dream_postgres/codec.{int, placeholder, text}
///
/// /// The checks of the queries of the user module. A check uses the codec of
/// /// each parameter, not its value, so each value is a placeholder.
/// pub fn queries() -> List(QueryCheck) {
///   [
///     query("SELECT id, email FROM users WHERE id = $1")
///       |> named("user.find")
///       |> parameter(int, placeholder(int))
///       |> checked({
///         use id <- column(int)
///         use email <- column(text)
///         row(#(id, email))
///       }),
///     query("DELETE FROM users WHERE id = $1")
///       |> named("user.delete")
///       |> parameter(int, placeholder(int))
///       |> checked_command,
///   ]
/// }
/// ```
pub fn checked(query: Query, reader: Row(a)) -> QueryCheck {
  QueryCheck(check: runner.check_rows(query, reader, _))
}

/// The check of a command whose rows are not read, as `affected` runs it.
///
/// ### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres.{
///   type QueryCheck, checked, checked_command, column, named, parameter, query,
///   row,
/// }
/// import dream_postgres/codec.{int, placeholder, text}
///
/// /// The checks of the queries of the user module. A check uses the codec of
/// /// each parameter, not its value, so each value is a placeholder.
/// pub fn queries() -> List(QueryCheck) {
///   [
///     query("SELECT id, email FROM users WHERE id = $1")
///       |> named("user.find")
///       |> parameter(int, placeholder(int))
///       |> checked({
///         use id <- column(int)
///         use email <- column(text)
///         row(#(id, email))
///       }),
///     query("DELETE FROM users WHERE id = $1")
///       |> named("user.delete")
///       |> parameter(int, placeholder(int))
///       |> checked_command,
///   ]
/// }
/// ```
pub fn checked_command(query: Query) -> QueryCheck {
  QueryCheck(check: runner.check_command(query, _))
}

/// Checks each query against the live database, as a run of the query
/// checks it, and runs none of them: the server prepares each query, then
/// its parameters' codecs are checked against the parameter types, and
/// its reader against the number and the types of the columns, enum
/// labels too. Call it at boot, so a query that no longer fits the schema
/// stops the app with a message that names the query and what changed.
///
/// The checks hold one connection for all queries, and go through no
/// interceptor, because no query runs. Each check asks the server, also for
/// a query that the statement cache of the connection holds, so a change
/// of the schema after an earlier run shows too. The error lists one error for each
/// query that fails, in order. When the pool gives no connection, the
/// error lists that one error. A connection with no database, such as the
/// connection of a recorder in playback mode, has no schema to check, so
/// the error lists one `NoDatabaseToVerify` error.
///
/// ### Check the queries at boot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/check_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type Connection, type PostgresError, verify}
/// import snippets/user_checks.{queries}
///
/// /// Checks each query of the app against the database, at boot.
/// pub fn check_database(
///   connection: Connection,
/// ) -> Result(Nil, List(Error(PostgresError))) {
///   verify(connection, [queries()])
/// }
/// ```
///
/// A failure reads, for example, `user.find: column 2 (email) is int4, and
/// the query reads it with the text codec`.
pub fn verify(
  connection: Connection,
  checks: List(List(QueryCheck)),
) -> Result(Nil, List(Error(PostgresError))) {
  case hold(connection, check_on_held(_, list.flatten(checks))) {
    Ok(outcome) -> outcome
    Error(reason) -> Error([failure(None, None, reason)])
  }
}

fn check_on_held(
  held: HeldConnection,
  checks: List(QueryCheck),
) -> Result(Nil, List(Error(PostgresError))) {
  case lowest_layer(held.session) {
    runner.DatabaseLayer(executor:) -> check_each(checks, executor)
    runner.AnsweringLayer(..) ->
      Error([failure(None, None, error.NoDatabaseToVerify)])
  }
}

fn check_each(
  checks: List(QueryCheck),
  executor: runner.Executor,
) -> Result(Nil, List(Error(PostgresError))) {
  let #(_passed, failures) =
    checks
    |> list.map(fn(query_check) { query_check.check(executor) })
    |> result.partition
  case failures {
    [] -> Ok(Nil)
    _ -> Error(list.reverse(failures))
  }
}

/// Stores rows in a table with one binary `COPY ... FROM STDIN`, and gives
/// the number of rows stored. It is the fastest way to load many rows.
///
/// `table` and each name of `columns` are quoted as PostgreSQL
/// identifiers, so each is the exact name: `"Users"` is not `"users"`, and
/// a dot is part of the name. A table of another schema than the search
/// path finds is not reachable by name.
///
/// `write` gives the fields of a row, one for each column in order, with
/// `codec.field`. Before the COPY starts, the types of the columns come
/// from the server and the first row is checked against them like the
/// parameters of a query, so a codec that does not take its column's type
/// fails with `ParameterTypeMismatch` and sends nothing. A binary COPY
/// needs codecs in the binary format, so a value of `codec.custom` fails
/// with `CopyNeedsBinaryCodec`. When any row fails, the COPY ends with no
/// row stored.
///
/// ### Store users with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/copy_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, type Row, column, copy_from, row, table,
/// }
/// import dream_postgres/codec.{type Field, field, int, nullable, text}
/// import gleam/option.{type Option}
///
/// pub type User {
///   User(id: Int, email: Option(String))
/// }
///
/// /// Reads the columns id and email, in this order, into a User.
/// pub fn user_row() -> Row(User) {
///   use id <- column(int)
///   use email <- column(nullable(text))
///   row(User(id:, email:))
/// }
///
/// /// The fields of a user for `copy_from`, in the order of the columns.
/// pub fn user_fields(user: User) -> List(Field) {
///   [field(int, user.id), field(nullable(text), user.email)]
/// }
///
/// pub fn load_users(
///   connection: Connection,
///   users: List(User),
/// ) -> Result(Int, Error(PostgresError)) {
///   copy_from(
///     connection,
///     into: table("users"),
///     columns: ["id", "email"],
///     rows: users,
///     write: user_fields,
///   )
/// }
/// ```
pub fn copy_from(
  connection: Connection,
  into table: Table,
  columns columns: List(String),
  rows rows: List(a),
  write write: fn(a) -> List(codec.Field),
) -> Result(Int, Error(PostgresError)) {
  hold(connection, fn(held) {
    copy.copy_from(
      chain_of(held),
      copy_from_end(held.session),
      table,
      columns,
      rows,
      write,
    )
  })
  |> result.flatten
  |> result.map_error(failure(None, Some(copy.copy_from_sql(table, columns)), _))
  |> result.map_error(secret_free_error(connection, _))
}

/// The table that `copy_from` stores its rows in.
pub type Table =
  copy_request.Table

/// A table found through the search path, such as `table("users")`. The
/// name is one identifier: a dot in it is part of the name, not a schema.
pub fn table(name: String) -> Table {
  copy_request.table(name)
}

/// A table in a schema, such as `table_in_schema("billing", "invoices")`.
/// The schema and the name are each quoted on their own.
pub fn table_in_schema(schema: String, name: String) -> Table {
  copy_request.table_in_schema(schema, name)
}

/// Reads the rows of a query with one binary `COPY (...) TO STDOUT`, and
/// folds over them: `with` takes the value so far and each row in order,
/// starting `from` the first value. The rows are read one at a time, so
/// the whole result is never in memory.
///
/// The query is prepared first, and the reader is checked against its
/// columns as for `all`. PostgreSQL takes no parameters in a COPY, so a
/// query with parameters fails with `CopyQueryHasParameters` and sends
/// nothing. A binary COPY needs codecs in the binary format, so a reader
/// that reads with `codec.custom` fails with `CopyNeedsBinaryCodec`. A row
/// that the reader cannot read stops the COPY with its reason.
///
/// ### Read every user with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/export_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{type Connection, type PostgresError, copy_to, query}
/// import gleam/list
/// import gleam/result
/// import snippets/copy_users.{type User, user_row}
///
/// pub fn export_users(
///   connection: Connection,
/// ) -> Result(List(User), Error(PostgresError)) {
///   copy_to(
///     connection,
///     query("SELECT id, email FROM users ORDER BY id"),
///     read: user_row(),
///     from: [],
///     with: list.prepend,
///   )
///   |> result.map(list.reverse)
/// }
/// ```
pub fn copy_to(
  connection: Connection,
  query: Query,
  read reader: Row(a),
  from initial: accumulator,
  with fold: fn(accumulator, a) -> accumulator,
) -> Result(accumulator, Error(PostgresError)) {
  hold(connection, fn(held) {
    copy.copy_to(
      chain_of(held),
      copy_to_end(held.session),
      query,
      reader,
      initial,
      fold,
    )
  })
  |> result.flatten
  |> result.map_error(failure(
    internal_query.name(query),
    Some(internal_query.sql(query)),
    _,
  ))
  |> result.map_error(secret_free_error(connection, _))
}

fn with_executor(
  connection: Connection,
  query: Query,
  body: fn(LowestLayer, List(Interceptor)) -> Result(a, Error(PostgresError)),
) -> Result(a, Error(PostgresError)) {
  hold(connection, fn(held) { body(lowest_layer(held.session), chain_of(held)) })
  |> result.map_error(failure(
    internal_query.name(query),
    Some(internal_query.sql(query)),
    _,
  ))
  |> result.flatten
  |> result.map_error(secret_free_error(connection, _))
}

// The error with the text secrets of the connection replaced in its SQL.
// When no pool runs under the name of a connection, its secrets are not
// known, so the error keeps no SQL.
fn secret_free_error(
  connection: Connection,
  failed: Error(PostgresError),
) -> Error(PostgresError) {
  let secret_free_sql = case connection_secrets(connection) {
    Ok(known) -> option.map(_, secrets.replace_text(known, _))
    Error(pool.PoolNotRunning) -> fn(_sql) { None }
  }
  dream_errors.map_cause(failed, fn(cause) {
    error.PostgresError(..cause, sql: secret_free_sql(cause.sql))
  })
}

fn connection_secrets(
  connection: Connection,
) -> Result(Secrets, pool.PoolNotRunning) {
  case connection {
    Pooled(pool:, ..) ->
      pool.attachment(pool) |> result.map(fn(settings) { settings.secrets })
    OneConnection(held:, ..) -> Ok(session_secrets(held.session))
    Replayed(secrets: replay_secrets, ..) -> Ok(replay_secrets)
  }
}

fn session_secrets(session: Session) -> Secrets {
  case session {
    DatabaseSession(settings:, ..) -> settings.secrets
    ReplaySession(secrets: replay_secrets, ..) -> replay_secrets
  }
}

// The interceptors of a held connection, then its lowest interceptors.
fn chain_of(held: HeldConnection) -> List(Interceptor) {
  case held.session {
    DatabaseSession(settings:, ..) ->
      list.append(held.interceptors, settings.lowest_interceptors)
    ReplaySession(..) -> held.interceptors
  }
}

fn lowest_layer(session: Session) -> LowestLayer {
  case session {
    DatabaseSession(connection:, catalog:, settings:) ->
      runner.DatabaseLayer(driver_executor.executor(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      ))
    ReplaySession(replay:, ..) -> runner.AnsweringLayer(replay.answer)
  }
}

fn copy_from_end(session: Session) -> fn(Request) -> Outcome {
  case session {
    DatabaseSession(connection:, catalog:, settings:) ->
      copy.copy_from_database(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      )
    ReplaySession(replay:, ..) -> replay.answer
  }
}

fn copy_to_end(session: Session) -> fn(Request) -> Outcome {
  case session {
    DatabaseSession(connection:, catalog:, settings:) ->
      copy.copy_to_database(
        connection,
        catalog,
        endpoint_of(settings),
        settings.secrets,
        settings.query_timeout_milliseconds,
      )
    ReplaySession(replay:, ..) -> replay.answer
  }
}

fn endpoint_of(settings: Settings) -> driver_executor.Endpoint {
  driver_executor.Endpoint(host: settings.host, port: settings.port)
}

/// Holds one connection for the callback: a connection of the pool, or
/// the connection that is held already. The error is why the pool gave no
/// connection.
fn hold(
  connection: Connection,
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  case connection {
    Pooled(pool:, added_interceptors:) ->
      hold_pooled(pool, added_interceptors, callback)
    OneConnection(held:, transaction_level: _) -> Ok(callback(held))
    Replayed(replay:, interceptors:, secrets: replay_secrets, ..) ->
      Ok(
        callback(HeldConnection(
          session: ReplaySession(replay:, secrets: replay_secrets),
          interceptors:,
        )),
      )
  }
}

// The settings and the catalog are read from the pool one time for each
// call. Both fail only when no pool runs. The interceptors that were added
// to the connection run after the interceptors of the config.
fn hold_pooled(
  pool: Pool(Settings),
  added_interceptors: List(Interceptor),
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  use settings <- result.try(
    pool.attachment(pool) |> result.replace_error(error.PoolStopped),
  )
  let interceptors = list.append(settings.interceptors, added_interceptors)
  case settings.replay {
    Some(replay) ->
      Ok(
        callback(HeldConnection(
          session: ReplaySession(replay:, secrets: settings.secrets),
          interceptors:,
        )),
      )
    None -> hold_database(pool, settings, interceptors, callback)
  }
}

// Holds a connection of a pool that has a database.
fn hold_database(
  pool: Pool(Settings),
  settings: Settings,
  interceptors: List(Interceptor),
  callback: fn(HeldConnection) -> a,
) -> Result(a, Reason) {
  use catalog <- result.try(
    pool.catalog(pool) |> result.replace_error(error.PoolStopped),
  )
  pool.hold(pool, settings.checkout_timeout_milliseconds, fn(held_connection) {
    callback(HeldConnection(
      session: DatabaseSession(connection: held_connection, catalog:, settings:),
      interceptors:,
    ))
  })
  |> result.map_error(driver_executor.checkout_error_reason(
    _,
    settings.host,
    settings.port,
  ))
}

/// The connection with an interceptor added after its other interceptors.
/// Each query and script on the new connection, also in a transaction,
/// goes through it. The connection that was given does not change. For an
/// interceptor of every connection of a pool, use `intercept` on the
/// config.
///
/// ### Add an interceptor to one call <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/tagged_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Connection, type PostgresError, one, query, single, with_interceptor,
/// }
/// import dream_postgres/codec.{text}
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The SQL text that the server runs, with the tag in front of it.
/// pub fn current_sql(
///   connection: Connection,
/// ) -> Result(String, Error(PostgresError)) {
///   query("SELECT current_query()")
///   |> one(single(text), with_interceptor(connection, tag_with_app_name))
/// }
/// ```
pub fn with_interceptor(
  connection: Connection,
  added_interceptor: Interceptor,
) -> Connection {
  case connection {
    Pooled(pool:, added_interceptors:) ->
      Pooled(
        pool:,
        added_interceptors: list.append(added_interceptors, [added_interceptor]),
      )
    OneConnection(held:, transaction_level:) ->
      OneConnection(
        held: HeldConnection(
          ..held,
          interceptors: list.append(held.interceptors, [added_interceptor]),
        ),
        transaction_level:,
      )
    Replayed(interceptors:, ..) ->
      Replayed(
        ..connection,
        interceptors: list.append(interceptors, [added_interceptor]),
      )
  }
}

/// Holds one connection of the pool for the callback, so that each call
/// in it runs on the same connection: for example a temporary table and
/// the queries on it. On a connection that is held already, the callback
/// gets that connection. A transaction that the callback leaves open is
/// rolled back when the hold ends.
pub fn with_connection(
  connection: Connection,
  callback: fn(Connection) -> a,
) -> Result(a, Error(PostgresError)) {
  case connection {
    Pooled(..) | Replayed(..) ->
      hold(connection, fn(held) { callback(OneConnection(held, NoTransaction)) })
      |> result.map_error(failure(None, None, _))
    OneConnection(..) -> Ok(callback(connection))
  }
}

/// Runs SQL with the simple query protocol, for example several
/// statements at once, or a statement that has no parameters and no
/// result to read. The rows of the statements are not read.
pub fn script(
  sql: String,
  connection: Connection,
) -> Result(Nil, Error(PostgresError)) {
  hold(connection, run_script(_, sql))
  |> result.map_error(failure(None, Some(sql), _))
  |> result.flatten
  |> result.map_error(secret_free_error(connection, _))
  |> result.replace(Nil)
}

// Runs a script through the interceptors, and gives the result of each
// of its statements.
fn run_script(
  held: HeldConnection,
  sql: String,
) -> Result(List(CommandResult), Error(PostgresError)) {
  run_script_with_postgres_error(held, sql)
  |> result.map_error(error.to_dream_error)
}

// Runs a script, and gives its failure as the PostgresError itself, for a
// caller that keeps it whole, such as the rollback of a transaction.
fn run_script_with_postgres_error(
  held: HeldConnection,
  sql: String,
) -> Result(List(CommandResult), PostgresError) {
  runner.intercept(
    chain_of(held),
    Request(sql:, name: None, parameters: [], kind: Script),
    script_answer_from_session(held.session, _),
  )
  |> result.try(script_answer)
  |> result.map_error(fn(reason) {
    error.PostgresError(query_name: None, sql: Some(sql), reason:)
  })
}

// The end of the chain of a script: runs its SQL on the connection, or
// gives the answer of the replay.
fn script_answer_from_session(session: Session, request: Request) -> Outcome {
  case session {
    DatabaseSession(connection:, catalog: _, settings:) ->
      driver_connection.run_script(
        connection,
        driver_executor.statement(request.sql, None, settings.secrets),
        settings.query_timeout_milliseconds,
      )
      |> result.map(fn(outcomes) {
        ScriptAnswer(
          results: list.map(outcomes, fn(outcome) { outcome.result }),
        )
      })
      |> result.map_error(driver_executor.script_error_reason(
        _,
        endpoint_of(settings),
      ))
    ReplaySession(replay:, ..) -> replay.answer(request)
  }
}

fn script_answer(answer: Answer) -> Result(List(CommandResult), Reason) {
  case answer {
    ScriptAnswer(results:) -> Ok(results)
    StatementAnswer(..) | CopyFromAnswer(..) | CopyToAnswer(..) ->
      Error(InterceptorFailed(
        reason: "an interceptor answered a script with the answer of another kind of request",
      ))
  }
}

fn failure(
  query_name: Option(String),
  sql: Option(String),
  reason: Reason,
) -> Error(PostgresError) {
  error.PostgresError(query_name:, sql:, reason:)
  |> error.to_dream_error
}

// --- Transactions ---------------------------------------------------------------

/// A transaction plan: its connection, its options and its steps. Nothing
/// is sent before `commit` or `run`. `value` is the result of the last
/// step, `cause` is the cause of the plan's `dream_errors.Error`, and
/// `steps` is `NoSteps` or `HasSteps`.
pub opaque type Transaction(value, cause, steps) {
  Transaction(
    connection: Connection,
    database: fn(PostgresError) -> cause,
    rollback_also_failed: fn(Error(cause), PostgresError) -> cause,
    isolation: Option(Isolation),
    read_only: Bool,
    body: fn(Connection) -> Result(value, Error(cause)),
  )
}

/// A transaction plan on the connection, with no step yet. It sends
/// nothing. The error of the plan is `dream_errors.Error(cause)`.
///
/// - `database` makes the cause of a database error: a database error
///   keeps its kind (`Retry`, `Conflict`, `Unavailable` and so on), and
///   `database` changes only its cause. `function.identity` keeps the
///   `PostgresError`.
/// - `rollback_also_failed` makes the cause for a failed step whose
///   `ROLLBACK` also failed. It gets the error of the step and the error
///   of the rollback, and the plan gives `Unavailable` with that cause.
///   `transaction.keep_both` joins the two into one `PostgresError`.
///
/// On the connection of a transaction, the plan runs as a savepoint: its
/// failure undoes only its own work.
pub fn transaction(
  connection: Connection,
  database database: fn(PostgresError) -> cause,
  rollback_also_failed rollback_also_failed: fn(Error(cause), PostgresError) ->
    cause,
) -> Transaction(Nil, cause, NoSteps) {
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation: None,
    read_only: False,
    body: fn(_transaction_connection) { Ok(Nil) },
  )
}

/// Adds a database step: a function of the connection of the
/// transaction. The cause of its error goes through `database`, and its
/// value goes to the next `check` or `step_with`.
pub fn step(
  plan: Transaction(before, cause, steps),
  database_step: fn(Connection) -> Result(value, Error(PostgresError)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      use _before <- result.try(body(transaction_connection))
      database_step(transaction_connection)
      |> result.map_error(dream_errors.map_cause(_, database))
    },
  )
}

/// Adds a database step that takes the value of the step before it.
pub fn step_with(
  plan: Transaction(before, cause, HasSteps),
  database_step: fn(Connection, before) -> Result(value, Error(PostgresError)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      use before <- result.try(body(transaction_connection))
      database_step(transaction_connection, before)
      |> result.map_error(dream_errors.map_cause(_, database))
    },
  )
}

/// Adds a rule on the value of the step before it, with the plan's own
/// error type. An error rolls the transaction back.
pub fn check(
  plan: Transaction(before, cause, HasSteps),
  rule: fn(before) -> Result(value, Error(cause)),
) -> Transaction(value, cause, HasSteps) {
  let Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body:,
  ) = plan
  Transaction(
    connection:,
    database:,
    rollback_also_failed:,
    isolation:,
    read_only:,
    body: fn(transaction_connection) {
      result.try(body(transaction_connection), rule)
    },
  )
}

/// Sets the isolation level of the transaction. A transaction inside a
/// transaction cannot set it, and gives `OptionsInNestedTransaction`.
pub fn isolation(
  plan: Transaction(value, cause, steps),
  isolation: Isolation,
) -> Transaction(value, cause, steps) {
  Transaction(..plan, isolation: Some(isolation))
}

/// Makes the transaction read only: a write in it fails. A transaction
/// inside a transaction cannot set it, and gives
/// `OptionsInNestedTransaction`.
pub fn read_only(
  plan: Transaction(value, cause, steps),
) -> Transaction(value, cause, steps) {
  Transaction(..plan, read_only: True)
}

/// Runs the plan: `BEGIN`, each step in order up to the first error, then
/// `COMMIT`, or `ROLLBACK` after an error. A commit that the server
/// answered with a rollback is `CommitRolledBack`, with the error that
/// failed the transaction. When the `ROLLBACK` after an error also fails,
/// the result is `Unavailable` with the cause that `rollback_also_failed`
/// made from both errors.
pub fn commit(
  plan: Transaction(value, cause, steps),
) -> Result(value, Error(cause)) {
  execute(plan, plan.body)
}

/// Runs the plan with one callback that does all the work with the
/// connection of the transaction. `Ok` commits, and `Error` rolls back. A
/// plan with steps cannot go to `run`.
pub fn run(
  plan: Transaction(Nil, cause, NoSteps),
  callback: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  execute(plan, callback)
}

fn execute(
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  case plan.connection {
    Pooled(..) | Replayed(..) ->
      hold(plan.connection, run_outermost(_, plan, body))
      |> result.map_error(fn(reason) {
        plan_error(plan, failure(None, None, reason))
      })
      |> result.flatten
    OneConnection(held:, transaction_level: NoTransaction) ->
      run_outermost(held, plan, body)
    OneConnection(held:, transaction_level: InTransaction(savepoints:)) ->
      run_nested(held, savepoints, plan, body)
  }
}

// A database error as an error of the plan: the same kind, with the cause
// that `database` makes.
fn plan_error(
  plan: Transaction(planned, cause, steps),
  database_error: Error(PostgresError),
) -> Error(cause) {
  dream_errors.map_cause(database_error, plan.database)
}

fn run_outermost(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  use _begun <- result.try(
    run_script(held, begin_sql(plan)) |> result.map_error(plan_error(plan, _)),
  )
  case body(OneConnection(held, InTransaction(savepoints: 0))) {
    Ok(value) ->
      commit_held(held)
      |> result.replace(value)
      |> result.map_error(plan_error(plan, _))
    Error(step_error) -> undo(held, plan, "ROLLBACK", step_error)
  }
}

fn begin_sql(plan: Transaction(planned, cause, steps)) -> String {
  let modes =
    [
      option.map(plan.isolation, transaction.isolation_sql),
      case plan.read_only {
        True -> Some("READ ONLY")
        False -> None
      },
    ]
    |> option.values
  case modes {
    [] -> "BEGIN"
    _ -> "BEGIN " <> string.join(modes, ", ")
  }
}

// Sends COMMIT. The report of a failed statement clears when the
// transaction ends, so it is read before the COMMIT.
fn commit_held(held: HeldConnection) -> Result(Nil, Error(PostgresError)) {
  use aborted_by <- result.try(aborted_by(held, "COMMIT"))
  use results <- result.try(run_script(held, "COMMIT"))
  results
  |> list.map(fn(command_result) { command_result.tag })
  |> commit_answer(aborted_by)
}

/// What the command tags of the answer to `COMMIT` mean: `COMMIT` is a
/// commit, and `ROLLBACK` is a rollback, with the report of the
/// statement that failed the transaction.
@internal
pub fn commit_answer(
  tags: List(String),
  aborted_by: Option(ServerError),
) -> Result(Nil, Error(PostgresError)) {
  case tags {
    ["COMMIT"] -> Ok(Nil)
    ["ROLLBACK"] -> Error(rolled_back(aborted_by, "COMMIT"))
    _ -> Error(failure(None, Some("COMMIT"), UnexpectedCommitAnswer(tags:)))
  }
}

// The server error that failed the open transaction: from the state of
// the connection, or from the replay.
fn aborted_by(
  held: HeldConnection,
  sql: String,
) -> Result(Option(ServerError), Error(PostgresError)) {
  case held.session {
    DatabaseSession(connection:, ..) ->
      driver_connection.aborted_by(connection)
      |> result.map(option.map(_, error.server_error_from_report))
      |> result.map_error(driver_executor.connection_state_error_reason)
    ReplaySession(replay:, ..) -> replay.aborted_by()
  }
  |> result.map_error(failure(None, Some(sql), _))
}

fn rolled_back(
  aborted_by: Option(ServerError),
  sql: String,
) -> Error(PostgresError) {
  failure(None, Some(sql), CommitRolledBack(cause: aborted_by))
}

// Rolls back after the error of a step, and gives that error. When the
// rollback fails too, it gives `Unavailable` with the cause that
// `rollback_also_failed` makes from both errors, so neither is lost.
fn undo(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  rollback_sql: String,
  step_error: Error(cause),
) -> Result(value, Error(cause)) {
  case run_script_with_postgres_error(held, rollback_sql) {
    Ok(_rolled_back) -> Error(step_error)
    Error(rollback_error) ->
      Error(Unavailable(
        "the rollback after a failed step failed",
        plan.rollback_also_failed(step_error, rollback_error),
      ))
  }
}

fn run_nested(
  held: HeldConnection,
  savepoints: Int,
  plan: Transaction(planned, cause, steps),
  body: fn(Connection) -> Result(value, Error(cause)),
) -> Result(value, Error(cause)) {
  use _no_options <- result.try(case plan.isolation, plan.read_only {
    None, False -> Ok(Nil)
    Some(_), _ | None, True ->
      Error(plan_error(plan, failure(None, None, OptionsInNestedTransaction)))
  })
  let name = savepoint_name(savepoints + 1)
  use _saved <- result.try(
    run_script(held, "SAVEPOINT " <> name)
    |> result.map_error(plan_error(plan, _)),
  )
  case body(OneConnection(held, InTransaction(savepoints: savepoints + 1))) {
    Ok(value) ->
      release_savepoint(held, plan, name)
      |> result.replace(value)
    Error(step_error) -> undo(held, plan, rollback_to_sql(name), step_error)
  }
}

// The name of the savepoint at a depth. It never comes from the app.
fn savepoint_name(depth: Int) -> String {
  "dream_postgres_savepoint_" <> int.to_string(depth)
}

fn rollback_to_sql(name: String) -> String {
  "ROLLBACK TO SAVEPOINT " <> name <> "; RELEASE SAVEPOINT " <> name
}

// Releases the savepoint of a nested transaction that succeeded. When a
// statement in it failed, the savepoint is rolled back instead, so the
// outer transaction can go on, and the result is `CommitRolledBack`.
fn release_savepoint(
  held: HeldConnection,
  plan: Transaction(planned, cause, steps),
  name: String,
) -> Result(Nil, Error(cause)) {
  let release_sql = "RELEASE SAVEPOINT " <> name
  use aborted_by <- result.try(
    aborted_by(held, release_sql) |> result.map_error(plan_error(plan, _)),
  )
  case aborted_by {
    None ->
      run_script(held, release_sql)
      |> result.replace(Nil)
      |> result.map_error(plan_error(plan, _))
    Some(_report) ->
      undo(
        held,
        plan,
        rollback_to_sql(name),
        plan_error(plan, rolled_back(aborted_by, release_sql)),
      )
  }
}

// --- Listeners ------------------------------------------------------------------

/// A listener: one connection of its own, outside the pool, that listens
/// for `NOTIFY` on the channels of its subscriptions. The first
/// subscription of a channel sends `LISTEN`, and when the last one ends,
/// the listener sends `UNLISTEN`. After a loss, the listener connects
/// again and listens again on each channel.
///
/// A listener is two processes: a registry that keeps the subscriptions,
/// and a session that owns the connection. A crash of the session of a
/// supervised listener keeps the subscriptions: each subject gets
/// `NotListening`, then `Listening` when the new session listens. A crash
/// of the registry ends every subscription. See `monitor_listener`.
pub opaque type Listener {
  Listener(listener: listener.Listener)
}

/// One subscription of a subject to a channel. `unlisten` ends it.
pub opaque type Subscription {
  Subscription(subscription: listener.Subscription)
}

/// The name of a listener that runs under a supervisor. Make it one time
/// when the program starts, with `process.new_name("notifications")`:
/// each name is an atom.
pub type ListenerName =
  process.Name(listener.ListenerProcessMessage)

/// What the subject of a subscription gets.
pub type ListenMessage {
  /// A notification on the channel, from the server process with
  /// `process_id`.
  NotificationArrived(channel: String, payload: String, process_id: Int)
  /// The session does not listen on the channel: the connection is not up
  /// yet, or it is lost. `Listening` or `ListenFailed` follows when the
  /// connection is up again. A notification between the two can be lost.
  NotListening
  /// The listener listens on the channel again, after `NotListening`.
  Listening(channel: String)
  /// The `LISTEN` for the channel failed after a reconnect. The listener
  /// tries again after the next reconnect.
  ListenFailed(channel: String, error: Error(PostgresError))
}

/// Starts a listener with the server, the login and the TLS of the
/// config, linked to the calling process. It waits until its connection
/// is up: a server that does not answer gives an error. Each `LISTEN` may
/// take the query timeout of the config. The pool settings of the config
/// do not apply.
///
/// ### Start a listener and listen on a channel <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_for_jobs.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Config, type ListenMessage, type Listener, type PostgresError,
///   type Subscription, listen, start_listener,
/// }
/// import gleam/erlang/process.{type Subject}
/// import gleam/result
///
/// /// Starts a listener and subscribes the subject to the channel `jobs`.
/// pub fn listen_for_jobs(
///   config: Config,
///   jobs: Subject(ListenMessage),
/// ) -> Result(#(Listener, Subscription), Error(PostgresError)) {
///   use listener <- result.try(start_listener(config))
///   use subscription <- result.try(listen(listener, "jobs", jobs))
///   Ok(#(listener, subscription))
/// }
/// ```
pub fn start_listener(
  config: Config,
) -> Result(Listener, Error(PostgresError)) {
  use checked <- result.try(pool_config(config, [], None))
  listener.start(listener.ListenerConfig(
    connection: checked.connection,
    deadline_milliseconds: config.query_timeout_milliseconds,
  ))
  |> result.map(Listener)
  |> result.map_error(fn(start_error) {
    failure_with_no_query(driver_executor.listener_start_error_reason(
      start_error,
      config.host,
      config.port,
    ))
  })
}

/// The child specification of a listener under the app's supervisor,
/// under the name. The start does not wait for the server: until the
/// connection is up, each subject gets `NotListening`. After a restart
/// the new listener takes the same name, so a `named_listener` of it
/// keeps working. The config is checked here, so a wrong config is an
/// error before the supervisor starts. `stop_listener` stops it for good.
///
/// ### Start a listener under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_listener_supervisor.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres.{type Config, type ListenerName, supervised_listener}
/// import dream_postgres/error.{describe}
/// import gleam/otp/actor
/// import gleam/otp/static_supervisor.{type Supervisor}
/// import gleam/result
///
/// /// Starts the app's supervisor with a listener under the name
/// /// `notifications`.
/// pub fn start_listener_supervisor(
///   config: Config,
///   notifications: ListenerName,
/// ) -> Result(actor.Started(Supervisor), String) {
///   use listener_child <- result.try(
///     supervised_listener(config, name: notifications)
///     |> result.map_error(describe),
///   )
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(listener_child)
///   |> static_supervisor.start
///   |> result.replace_error("the supervisor did not start")
/// }
/// ```
pub fn supervised_listener(
  config: Config,
  name name: ListenerName,
) -> Result(ChildSpecification(Listener), Error(PostgresError)) {
  use checked <- result.try(pool_config(config, [], None))
  listener.supervised(
    listener.ListenerConfig(
      connection: checked.connection,
      deadline_milliseconds: config.query_timeout_milliseconds,
    ),
    name,
  )
  |> supervision.map_data(Listener)
  |> Ok
}

/// The listener that runs under the name. It holds only the name, so it
/// stays valid when the supervisor restarts the listener. While no
/// listener runs under the name, `listen` and `unlisten` fail with
/// `ListenerStopped`.
///
/// ### Listen through the name of a listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_by_name.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type ListenMessage, type ListenerName, type PostgresError, type Subscription,
///   listen, named_listener,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// /// Subscribes the subject to `jobs` on the listener that runs under the
/// /// name, as a supervisor starts it.
/// pub fn listen_by_name(
///   notifications: ListenerName,
///   jobs: Subject(ListenMessage),
/// ) -> Result(Subscription, Error(PostgresError)) {
///   listen(named_listener(notifications), "jobs", jobs)
/// }
/// ```
pub fn named_listener(name: ListenerName) -> Listener {
  Listener(listener.from_name(name))
}

/// A monitor of the listener's registry, owned by the calling process.
/// The registry keeps the subscriptions, so when it ends, by a crash or
/// by `stop_listener`, every subscription ends, and the caller gets the
/// `Down` of the monitor. A supervised listener comes back with no
/// subscription: after the `Down`, the app subscribes again through
/// `named_listener`, and monitors again. A crash of the session alone
/// gives no `Down`: the subscriptions stay. No listener that runs is
/// `ListenerStopped`.
///
/// ### Watch for the end of the registry <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/job_events.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type ListenMessage, type ListenerName, type PostgresError, monitor_listener,
///   named_listener,
/// }
/// import gleam/erlang/process.{type Down, type Selector, type Subject}
/// import gleam/result
///
/// pub type JobEvent {
///   JobMessage(message: ListenMessage)
///   /// The registry of the listener ended, and every subscription with it.
///   ListenerEnded(down: Down)
/// }
///
/// /// A selector of the messages of `jobs` and of the end of the listener's
/// /// registry.
/// pub fn job_events(
///   notifications: ListenerName,
///   jobs: Subject(ListenMessage),
/// ) -> Result(Selector(JobEvent), Error(PostgresError)) {
///   use monitor <- result.try(monitor_listener(named_listener(notifications)))
///   process.new_selector()
///   |> process.select_map(jobs, JobMessage)
///   |> process.select_specific_monitor(monitor, ListenerEnded)
///   |> Ok
/// }
/// ```
pub fn monitor_listener(
  listener: Listener,
) -> Result(Monitor, Error(PostgresError)) {
  listener.monitor_registry(listener.listener)
  |> result.map_error(fn(listener_error) {
    failure_with_no_query(driver_executor.listener_error_reason(listener_error))
  })
}

/// Stops the listener and its connection. Its subscribers get no message.
///
/// ### End a subscription and stop the listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/stop_listening.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Listener, type PostgresError, type Subscription, stop_listener, unlisten,
/// }
/// import gleam/result
///
/// /// Ends the subscription, then stops the listener.
/// pub fn stop_listening(
///   listener: Listener,
///   subscription: Subscription,
/// ) -> Result(Nil, Error(PostgresError)) {
///   use Nil <- result.try(unlisten(listener, subscription))
///   stop_listener(listener)
///   Ok(Nil)
/// }
/// ```
pub fn stop_listener(listener: Listener) -> Nil {
  listener.stop(listener.listener)
}

/// Subscribes the subject to the channel. The channel name is exact: `Jobs`
/// and `jobs` are two channels. The subscription ends with `unlisten`, or
/// when the process of the subject ends.
///
/// The result is `Ok` when the session listens on the channel, and also
/// when the connection is not up: then the subject gets `NotListening` at
/// once, and `Listening` when the session listens. A name of more than 63
/// bytes is `ChannelTooLong`, and a subject with no process is
/// `SubscriberHasNoProcess`.
///
/// ### Wait for the next notification <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/next_job.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres.{
///   type ListenMessage, ListenFailed, Listening, NotListening, NotificationArrived,
/// }
/// import gleam/erlang/process.{type Subject}
///
/// /// The payload of the next notification, or `Error(Nil)` when none came
/// /// within 5 seconds. It skips the messages about the listening state.
/// pub fn next_job(jobs: Subject(ListenMessage)) -> Result(String, Nil) {
///   case process.receive(jobs, 5000) {
///     Ok(NotificationArrived(payload:, ..)) -> Ok(payload)
///     Ok(NotListening) | Ok(Listening(..)) | Ok(ListenFailed(..)) ->
///       next_job(jobs)
///     Error(Nil) -> Error(Nil)
///   }
/// }
/// ```
pub fn listen(
  listener: Listener,
  channel: String,
  subject: Subject(ListenMessage),
) -> Result(Subscription, Error(PostgresError)) {
  listener.subscribe(
    listener.listener,
    channel,
    sink.to(subject, listen_message),
  )
  |> result.map(Subscription)
  |> result.map_error(fn(listener_error) {
    failure_with_no_query(driver_executor.listener_error_reason(listener_error))
  })
}

/// Ends the subscription. When it was the last one of its channel, the
/// listener sends `UNLISTEN`.
///
/// ### End a subscription and stop the listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/stop_listening.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres.{
///   type Listener, type PostgresError, type Subscription, stop_listener, unlisten,
/// }
/// import gleam/result
///
/// /// Ends the subscription, then stops the listener.
/// pub fn stop_listening(
///   listener: Listener,
///   subscription: Subscription,
/// ) -> Result(Nil, Error(PostgresError)) {
///   use Nil <- result.try(unlisten(listener, subscription))
///   stop_listener(listener)
///   Ok(Nil)
/// }
/// ```
pub fn unlisten(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, Error(PostgresError)) {
  listener.unsubscribe(listener.listener, subscription.subscription)
  |> result.map_error(fn(unsubscribe_error) {
    failure_with_no_query(driver_executor.unsubscribe_error_reason(
      unsubscribe_error,
    ))
  })
}

/// The listen message of the client for a message of the driver's
/// listener.
@internal
pub fn listen_message(message: listener.ListenerMessage) -> ListenMessage {
  case message {
    listener.NotificationArrived(notification:) ->
      NotificationArrived(
        channel: notification.channel,
        payload: notification.payload,
        process_id: notification.process_id,
      )
    listener.NotListening -> NotListening
    listener.Listening(channel:) -> Listening(channel:)
    listener.ListenFailed(channel:, error: failure) ->
      ListenFailed(
        channel:,
        error: failure_with_no_query(driver_executor.listen_failure_reason(
          failure,
        )),
      )
  }
}
