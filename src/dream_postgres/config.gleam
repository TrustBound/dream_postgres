//// The config of a pool: the server, the login, the sizes and times of the
//// pool, TLS, the statement cache, the interceptors, the secrets, a
//// recorder, and the subjects for notices and pool events. Build one with
//// `default_config` and the functions that set one field each, then give it
//// to `pool.start` or `pool.supervised`.

import dream_errors.{type Error}
import dream_postgres/driver/cell.{type ServerReport}
import dream_postgres/driver/connection/backoff as connection_backoff
import dream_postgres/driver/connection/settings as connection_settings
import dream_postgres/driver/login/login_config
import dream_postgres/driver/message
import dream_postgres/driver/pool/pool_event
import dream_postgres/driver/pool/pool_settings.{type PoolConfig}
import dream_postgres/driver/sink
import dream_postgres/driver/transport
import dream_postgres/error.{type PostgresError, type Severity, InvalidConfig}
import dream_postgres/error/failure.{failure, failure_with_no_query}
import dream_postgres/interceptor.{type Interceptor}
import dream_postgres/pool/connection_state
import dream_postgres/query/driver_executor
import dream_postgres/reconnect.{type ReconnectStep, ReconnectStep, full_jitter}
import dream_postgres/recorder.{type Recorder}
import dream_postgres/recorder/replay.{type Replay}
import dream_postgres/secrets.{type Secrets}
import dream_postgres/sql_state.{type SqlState}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The settings of a pool. Build one with `default_config` and the
/// functions that set one field each.
///
/// ### Start a pool of 15 connections <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_app_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/config.{
///   database, default_config, host, password, pool_size, user,
/// }
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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
/// import dream_postgres/config.{default_config, host}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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

/// Adds an interceptor after the ones added before. Each query and `run_sql` call
/// of the pool, also in a transaction, goes through the interceptors in
/// the order they were added. See `dream_postgres/interceptor`.
///
/// ### Add two interceptors to the config <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_tagged_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/config.{type Config, intercept}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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
/// import dream_postgres/codecs.{text}
/// import dream_postgres/config.{type Config, intercept, secrets}
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
/// import dream_postgres/config.{type Config, record}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{start, stop}
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
/// import dream_postgres/config.{
///   AuthorityFile, CheckAuthorityAndHost, TlsRequired, default_config, host, tls,
/// }
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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
/// import dream_postgres/config.{type Config, NoStatementCache, statement_cache}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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
/// import dream_postgres/config.{type Config, type ServerNotice, notices}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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
/// import dream_postgres/config.{type Config, type PoolEvent, pool_events}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start}
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

/// The settings that each call on a pool needs. The pool carries them.
pub type Settings =
  connection_state.Settings

/// The most connections the pool of the config holds.
@internal
pub fn connection_count(config: Config) -> Int {
  config.pool_size
}

/// Refuses a time setting below 1 millisecond, before anything starts.
@internal
pub fn check_times(config: Config) -> Result(Nil, Error(PostgresError)) {
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

/// How the recorder of the config, if any, takes part in the connection.
@internal
pub fn recorder_attachment(config: Config) -> recorder.Attachment {
  config.recorder
  |> option.map(recorder.attachment(_, config.secrets))
  |> option.unwrap(recorder.PlainPool)
}

/// The settings that each call on the pool of the config needs.
@internal
pub fn pool_settings(
  config: Config,
  lowest_interceptors: List(Interceptor),
  replay: Option(Replay),
) -> Settings {
  connection_state.new_settings(
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
}

/// The config of the driver pool for the config, with its settings as the
/// data of each connection.
@internal
pub fn pool_config(
  config: Config,
  lowest_interceptors: List(Interceptor),
  replay: Option(Replay),
) -> Result(PoolConfig(Settings), Error(PostgresError)) {
  pool_settings(config, lowest_interceptors, replay)
  |> driver_pool_config(config, _)
}

/// The config of the driver pool for the config, with `attachment` as the
/// data of each connection.
@internal
pub fn driver_pool_config(
  config: Config,
  attachment: attachment,
) -> Result(PoolConfig(attachment), Error(PostgresError)) {
  use address <- result.try(address_of(config))
  use login_config <- result.try(login_config_of(config))
  Ok(pool_settings.PoolConfig(
    connection: connection_config_of(config, address, login_config),
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

fn address_of(
  config: Config,
) -> Result(transport.Address, Error(PostgresError)) {
  transport.address(config.host, config.port)
  |> result.map_error(fn(address_error) {
    failure_with_no_query(
      error.InvalidConfig(driver_executor.address_fault(address_error)),
    )
  })
}

fn login_config_of(
  config: Config,
) -> Result(login_config.LoginConfig, Error(PostgresError)) {
  login_config.new(
    user: config.user,
    database: config.database,
    password: login_password(config.password),
    parameters: [],
    channel_binding: login_config.PreferChannelBinding,
    protocol_version: message.Protocol30,
  )
  |> result.map_error(fn(config_error) {
    failure_with_no_query(
      error.InvalidConfig(driver_executor.login_config_fault(config_error)),
    )
  })
}

fn connection_config_of(
  config: Config,
  address: transport.Address,
  login_config: login_config.LoginConfig,
) -> connection_settings.ConnectionConfig {
  connection_settings.ConnectionConfig(
    transport: transport.TransportConfig(
      address:,
      tls: transport_tls(config.tls),
      connect_timeout_milliseconds: config.connect_timeout_milliseconds,
      send_timeout_milliseconds: 5000,
    ),
    login: login_config,
    setup_timeout_milliseconds: config.setup_timeout_milliseconds,
    cancel_timeout_milliseconds: config.cancel_timeout_milliseconds,
    reconnect: connection_backoff.Backoff(
      first_delay_milliseconds: config.reconnect_first_delay_milliseconds,
      longest_delay_milliseconds: config.reconnect_longest_delay_milliseconds,
      strategy: reconnect_strategy_of(config),
    ),
    events: None,
    notifications: None,
    notices: option.map(config.notices, sink.to(_, server_notice)),
    statements: statement_caching(config.statement_cache),
  )
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
) -> connection_settings.StatementCaching {
  case statement_cache {
    CacheStatements(limit:) -> connection_settings.CacheStatements(limit:)
    NoStatementCache -> connection_settings.UnnamedStatements
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
pub fn pool_event(
  event: pool_event.PoolEvent,
  host: String,
  port: Int,
) -> PoolEvent {
  case event {
    pool_event.MemberConnected(slot:) -> Connected(slot:)
    pool_event.MemberDisconnected(slot:, error: end) ->
      Disconnected(
        slot:,
        reason: failure(None, None, driver_executor.connection_end_reason(end)),
      )
    pool_event.MemberReconnected(slot:) -> Reconnected(slot:)
    pool_event.MemberConnectFailed(slot:, error: connect_error) ->
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
    pool_event.MemberReplacing(slot:) -> Replacing(slot:)
    pool_event.MemberFree(slot:) -> Free(slot:)
    pool_event.HoldWaiting(waiting:) -> Waiting(count: waiting)
    pool_event.MemberHeld(slot:) -> Held(slot:)
    pool_event.MemberReturned(slot:) -> Returned(slot:)
    pool_event.HoldRefused(error: hold_error) ->
      Refused(error: failure(
        None,
        None,
        driver_executor.checkout_error_reason(hold_error, host, port),
      ))
    pool_event.PoolStopping -> Stopping
  }
}

fn reconnect_strategy_of(
  config: Config,
) -> fn(connection_backoff.BackoffStep) -> Int {
  fn(step: connection_backoff.BackoffStep) {
    config.reconnect_strategy(ReconnectStep(
      attempt: step.attempt,
      capped_delay_milliseconds: step.capped_delay_milliseconds,
      previous_wait_milliseconds: step.previous_wait_milliseconds,
    ))
  }
}

fn login_password(password: Option(String)) -> login_config.Password {
  case password {
    Some(text) -> login_config.password(text)
    None -> login_config.no_password()
  }
}

/// The default config, with the parts of a database URL. A part that the
/// URL does not give keeps the default, except the database: with no
/// database, the database is the user, as in libpq.
@internal
pub fn config_with_url_parts(
  host host: Option(String),
  port port: Option(Int),
  user user: Option(String),
  password password: Option(String),
  database database: Option(String),
  tls tls: Tls,
) -> Config {
  let default = default_config()
  let url_user = option.unwrap(user, default.user)
  Config(
    ..default,
    host: option.unwrap(host, default.host),
    port: option.unwrap(port, default.port),
    user: url_user,
    password:,
    database: option.unwrap(database, url_user),
    tls:,
  )
}
