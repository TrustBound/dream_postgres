//// Test fixtures that start connection processes on the driver servers:
//// the connection config, a started connection, a text query, a
//// connection through a test proxy with a control connection beside it, a
//// connection with a control connection beside it, one act that several
//// tests check, the backend process IDs, a suspended connection process,
//// the mailbox and the memory of a connection process, callers in their
//// own processes, and a connection under a supervisor.
////
//// Each fixture that can fail gives a `Result` with a text error, so a
//// setup of dream_test reports the failure as a failed setup. The hooks
//// are for `dream_test/unit_context`: a describe gets its first context
//// from `connection_setup` or `proxied_setup`, each test starts its own
//// connection in `before_each` and stops it in `after_each`. The shared
//// servers keep a connection open until it ends, so every start has a
//// stop.

import dream_postgres/driver/cell.{type Cell, CommandResult, Text}
import dream_postgres/driver/connection.{start, stop, supervised}
import dream_postgres/driver/connection/backoff.{Backoff}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{
  type ConnectionEvent, Connected, LoginRefused, ReconnectFailed, Reconnected,
}
import dream_postgres/driver/connection/extended_query.{run}
import dream_postgres/driver/connection/outcome.{type Outcome, Outcome}
import dream_postgres/driver/connection/request_failure.{type SimpleQueryError}
import dream_postgres/driver/connection/settings.{
  type ConnectionConfig, type StatementCaching, CacheStatements,
  ConnectionConfig,
}
import dream_postgres/driver/connection/simple_query.{run_simple_query}
import dream_postgres/driver/connection/statement as connection_statement
import dream_postgres/driver/connection/status.{
  server_parameter, transaction_status,
}
import dream_postgres/driver/login.{ServerRejectedLogin}
import dream_postgres/driver/login/login_config.{
  type ChannelBindingSetting, type LoginConfig, type Password,
  PreferChannelBinding, RequireChannelBinding,
}
import dream_postgres/driver/message.{type ProtocolVersion, Protocol30}
import dream_postgres/driver/statement_cache.{default_limit}
import dream_postgres/driver/transport.{
  type Address, type Tls, NoTls, TransportConfig, address,
}
import dream_test/context.{type Context}
import driver/proxy.{type Proxy, inject, start_proxy, stop_proxy}
import driver/servers.{type Server}
import fixtures/backoff_strategies.{capped_delay}
import fixtures/identity_sink.{identity_sink}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

// Configs ---------------------------------------------------------------------

/// The config of a connection to localhost on `port` as `user`, over plain
/// TCP, with a first reconnect delay of 10 milliseconds and no events.
pub fn user_config(
  port: Int,
  user: String,
  password: String,
) -> Result(ConnectionConfig, String) {
  use server_address <- try(server_address(port))
  use login <- try(login_config(user, password, [], Protocol30))
  Ok(ConnectionConfig(
    transport: TransportConfig(server_address, NoTls, 5000, 500),
    login:,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(10, 60_000, capped_delay),
    events: None,
    notifications: None,
    notices: None,
    statements: CacheStatements(default_limit),
  ))
}

/// The config of a connection to localhost on `port` as `dream`.
pub fn connection_config(port: Int) -> Result(ConnectionConfig, String) {
  user_config(port, "dream", servers.password)
}

/// The config of a connection as `dream` that sets the server parameter
/// `application_name`, so a control connection can find its session in
/// `pg_stat_activity`.
pub fn application_config(
  port: Int,
  application_name: String,
) -> Result(ConnectionConfig, String) {
  parameter_config(port, "application_name", application_name)
}

/// The config of a connection as `dream` that sends the startup parameter
/// `name` with `value`.
pub fn parameter_config(
  port: Int,
  name: String,
  value: String,
) -> Result(ConnectionConfig, String) {
  parameters_config(port, [#(name, value)])
}

/// The config of a connection as `dream` that sends the startup
/// parameters `parameters`, in their order.
pub fn parameters_config(
  port: Int,
  parameters: List(#(String, String)),
) -> Result(ConnectionConfig, String) {
  login_settings_config(
    port,
    servers.database,
    login_config.password(servers.password),
    parameters,
  )
}

/// The config of a connection as `dream` to the database `database`.
pub fn database_config(
  port: Int,
  database: String,
) -> Result(ConnectionConfig, String) {
  login_settings_config(
    port,
    database,
    login_config.password(servers.password),
    [],
  )
}

/// The config of a connection as `dream` whose password comes from a
/// function.
pub fn password_function_config(port: Int) -> Result(ConnectionConfig, String) {
  login_settings_config(
    port,
    servers.database,
    login_config.password_function(fn() { servers.password }),
    [],
  )
}

/// The config of a connection as `dream` to `host` on `port`.
pub fn host_config(
  host: String,
  port: Int,
) -> Result(ConnectionConfig, String) {
  use config <- try(connection_config(port))
  use host_address <- try(
    address(host, port)
    |> map_error(fn(error) { "could not build the address: " <> inspect(error) }),
  )
  Ok(
    ConnectionConfig(
      ..config,
      transport: TransportConfig(..config.transport, address: host_address),
    ),
  )
}

fn login_settings_config(
  port: Int,
  database: String,
  password: Password,
  parameters: List(#(String, String)),
) -> Result(ConnectionConfig, String) {
  use config <- try(connection_config(port))
  use login <- try(login_settings(
    "dream",
    database,
    password,
    parameters,
    Protocol30,
  ))
  Ok(ConnectionConfig(..config, login:))
}

/// The config of a connection as `dream` that asks for the protocol
/// version `protocol_version`.
pub fn protocol_config(
  port: Int,
  protocol_version: ProtocolVersion,
) -> Result(ConnectionConfig, String) {
  use config <- try(connection_config(port))
  use login <- try(login_config("dream", servers.password, [], protocol_version))
  Ok(ConnectionConfig(..config, login:))
}

/// The config with its events sent to `events`, and a first reconnect
/// delay of `first_delay` milliseconds.
pub fn watched_config(
  config: ConnectionConfig,
  events: Subject(ConnectionEvent),
  first_delay: Int,
) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    reconnect: Backoff(first_delay, 60_000, capped_delay),
    events: Some(identity_sink(events)),
  )
}

/// The config with the TLS setting `tls`.
pub fn tls_config(config: ConnectionConfig, tls: Tls) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    transport: TransportConfig(..config.transport, tls:),
  )
}

/// The config with a send timeout of `milliseconds`.
pub fn send_timeout_config(
  config: ConnectionConfig,
  milliseconds: Int,
) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    transport: TransportConfig(
      ..config.transport,
      send_timeout_milliseconds: milliseconds,
    ),
  )
}

/// The config with the statement caching `caching`.
pub fn caching_config(
  config: ConnectionConfig,
  caching: StatementCaching,
) -> ConnectionConfig {
  ConnectionConfig(..config, statements: caching)
}

/// The config with a setup timeout of `milliseconds`.
pub fn setup_timeout_config(
  config: ConnectionConfig,
  milliseconds: Int,
) -> ConnectionConfig {
  ConnectionConfig(..config, setup_timeout_milliseconds: milliseconds)
}

/// The config with a cancel timeout of `milliseconds`.
pub fn cancel_timeout_config(
  config: ConnectionConfig,
  milliseconds: Int,
) -> ConnectionConfig {
  ConnectionConfig(..config, cancel_timeout_milliseconds: milliseconds)
}

fn server_address(port: Int) -> Result(Address, String) {
  address("localhost", port)
  |> map_error(fn(error) { "could not build the address: " <> inspect(error) })
}

/// The config of a connection to localhost on `port` as `dream`, over plain
/// TCP, whose login requires channel binding.
pub fn required_binding_config(port: Int) -> Result(ConnectionConfig, String) {
  use config <- try(connection_config(port))
  use login <- try(login_settings_with(
    "dream",
    servers.database,
    login_config.password(servers.password),
    [],
    Protocol30,
    RequireChannelBinding,
  ))
  Ok(ConnectionConfig(..config, login:))
}

fn login_config(
  user: String,
  password: String,
  parameters: List(#(String, String)),
  protocol_version: ProtocolVersion,
) -> Result(LoginConfig, String) {
  login_settings(
    user,
    servers.database,
    login_config.password(password),
    parameters,
    protocol_version,
  )
}

fn login_settings(
  user: String,
  database: String,
  password: Password,
  parameters: List(#(String, String)),
  protocol_version: ProtocolVersion,
) -> Result(LoginConfig, String) {
  login_settings_with(
    user,
    database,
    password,
    parameters,
    protocol_version,
    PreferChannelBinding,
  )
}

fn login_settings_with(
  user: String,
  database: String,
  password: Password,
  parameters: List(#(String, String)),
  protocol_version: ProtocolVersion,
  channel_binding: ChannelBindingSetting,
) -> Result(LoginConfig, String) {
  login_config.new(
    user:,
    database:,
    password:,
    parameters:,
    channel_binding:,
    protocol_version:,
  )
  |> map_error(fn(error) {
    "could not build the login config: " <> inspect(error)
  })
}

// Started connections ---------------------------------------------------------

/// Starts a connection as `dream` to localhost on `port`.
pub fn start_connection(port: Int) -> Result(Connection, String) {
  connection_config(port) |> try(start_configured)
}

/// Starts a connection with `config`.
pub fn start_configured(
  config: ConnectionConfig,
) -> Result(Connection, String) {
  start(config)
  |> map_error(fn(error) { "could not start a connection: " <> inspect(error) })
}

/// Starts a connection whose events go to `events`, and takes its first
/// event, which must be `Connected`, so the test reads only the events
/// after it.
pub fn start_watched(
  config: ConnectionConfig,
  events: Subject(ConnectionEvent),
) -> Result(Connection, String) {
  use connection <- try(start_configured(config))
  case next_event(events) {
    Ok(Connected) -> Ok(connection)
    other -> {
      stop(connection)
      Error("expected Connected first, got " <> inspect(other))
    }
  }
}

/// Stops the connection. A teardown for `after_each` and for the context
/// setup. A connection that stopped already stays stopped.
pub fn stop_connection(connection: Connection) -> Result(Nil, String) {
  Ok(stop(connection))
}

/// Runs `sql` on the connection, for a step that prepares the state of a
/// test.
pub fn run_control_simple_query(
  connection: Connection,
  sql: String,
) -> Result(Nil, String) {
  run_simple_query(connection, connection_statement.statement(sql), 5000)
  |> replace(Nil)
  |> map_error(fn(error) { "could not run " <> sql <> ": " <> inspect(error) })
}

// Hooks for a describe whose context is a connection --------------------------

/// The context of a describe whose tests each get a connection: one
/// connection to `server` for the tree, which gives the context its first
/// value. `start_test_connection` gives each test its own.
///
/// ```gleam
/// describe("connection", connection_setup(first_driver_server), [
///   before_each(start_test_connection(first_driver_server)),
///   after_each(stop_connection),
///   it("runs a simple query", fn(connection) {
///     run_simple_query(connection, connection_statement.statement("SELECT 1"), 5000)
///     |> should
///     |> be_ok
///     |> or_fail_with("Expected the outcome")
///   }),
/// ])
/// ```
pub fn connection_setup(server: Server) -> Context(Connection) {
  context.setup(
    setup: fn() { start_connection(server.port) },
    teardown: stop_connection,
  )
}

/// A `before_each` hook that starts a connection to `server` for the test.
/// The connection in the context it gets stays as it is.
pub fn start_test_connection(
  server: Server,
) -> fn(Connection) -> Result(Connection, String) {
  fn(_tree_connection) { start_connection(server.port) }
}

/// A `before_each` hook that starts a connection with `config` for the
/// test.
pub fn start_test_configured(
  config: Result(ConnectionConfig, String),
) -> fn(Connection) -> Result(Connection, String) {
  fn(_tree_connection) { try(config, start_configured) }
}

/// A `before_each` hook that starts a connection to `server` with the
/// statement caching `caching` for the test.
pub fn start_test_caching(
  server: Server,
  caching: StatementCaching,
) -> fn(Connection) -> Result(Connection, String) {
  start_test_configured(
    connection_config(server.port) |> result.map(caching_config(_, caching)),
  )
}

/// A hook that runs `step` on its context and keeps the context. The setup
/// fails with the error of the step.
pub fn setup_step(
  step: fn(context) -> Result(a, String),
) -> fn(context) -> Result(context, String) {
  fn(context) { step(context) |> replace(context) }
}

/// A hook that runs the simple query `sql`, which must work.
pub fn run_setup_simple_query(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  setup_step(run_control_simple_query(_, sql))
}

/// A hook that runs the statement `sql` with no parameters, which must
/// work.
pub fn run_setup_statement(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  setup_step(fn(connection) {
    run(connection, connection_statement.statement(sql), [], [], 5000)
    |> map_error(fn(error) { "could not run " <> sql <> ": " <> inspect(error) })
  })
}

/// A hook that runs the simple query `sql`, which must fail: for a test of the
/// state after a failure. The setup fails when the simple query works.
pub fn run_failing_simple_query(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  fn(connection) {
    run_simple_query(connection, connection_statement.statement(sql), 5000)
    |> require_failure(connection, sql)
  }
}

/// A hook that runs the statement `sql` with no parameters, which must
/// fail. The setup fails when the statement works.
pub fn run_failing_statement(
  sql: String,
) -> fn(Connection) -> Result(Connection, String) {
  run_failing_statement_within(sql, 5000)
}

/// A hook that runs the statement `sql` with no parameters and a deadline
/// of `deadline` milliseconds, which must fail, for example because it
/// passes its deadline. The setup fails when the statement works.
pub fn run_failing_statement_within(
  sql: String,
  deadline: Int,
) -> fn(Connection) -> Result(Connection, String) {
  fn(connection) {
    run(connection, connection_statement.statement(sql), [], [], deadline)
    |> require_failure(connection, sql)
  }
}

/// A hook that runs the statement `sql` with `parameters`, which must
/// fail. The setup fails when the statement works.
pub fn run_failing_statement_with_parameters(
  sql: String,
  parameters: List(Cell),
) -> fn(Connection) -> Result(Connection, String) {
  fn(connection) {
    run(connection, connection_statement.statement(sql), parameters, [], 5000)
    |> require_failure(connection, sql)
  }
}

/// Keeps `context` when `answer` is an error, and gives a setup error when
/// it is not: for a hook whose step must fail.
pub fn require_failure(
  answer: Result(a, error),
  context: context,
  sql: String,
) -> Result(context, String) {
  case answer {
    Error(_expected) -> Ok(context)
    Ok(value) ->
      Error("expected " <> sql <> " to fail, it gave " <> inspect(value))
  }
}

// Connections through a proxy -------------------------------------------------

/// A connection through a test proxy, with its events, a control
/// connection straight to the server, and an advisory lock key that no
/// other test uses.
pub type ProxiedConnection {
  ProxiedConnection(
    connection: Connection,
    control: Connection,
    proxy: Proxy,
    events: Subject(ConnectionEvent),
    lock_key: Int,
  )
}

/// Starts a connection to `server` through a new proxy, with a first
/// reconnect delay of `first_delay` milliseconds, and a control connection.
pub fn start_proxied(
  server: Server,
  first_delay: Int,
) -> Result(ProxiedConnection, String) {
  start_proxied_with_caching(
    server,
    first_delay,
    CacheStatements(default_limit),
  )
}

/// Starts a connection to `server` through a new proxy, as `start_proxied`
/// does, with the statement caching `caching`.
pub fn start_proxied_with_caching(
  server: Server,
  first_delay: Int,
  caching: StatementCaching,
) -> Result(ProxiedConnection, String) {
  start_proxied_configured(server, first_delay, caching_config(_, caching))
}

/// Starts a connection to `server` through a new proxy, as `start_proxied`
/// does, with the TLS setting `tls` between the connection and the proxy.
pub fn start_proxied_with_tls(
  server: Server,
  first_delay: Int,
  tls: Tls,
) -> Result(ProxiedConnection, String) {
  start_proxied_configured(server, first_delay, tls_config(_, tls))
}

fn start_proxied_configured(
  server: Server,
  first_delay: Int,
  configure: fn(ConnectionConfig) -> ConnectionConfig,
) -> Result(ProxiedConnection, String) {
  use #(port, proxy) <- try(start_proxy(server.port))
  start_through_proxy(server, first_delay, configure, port, proxy)
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn start_through_proxy(
  server: Server,
  first_delay: Int,
  configure: fn(ConnectionConfig) -> ConnectionConfig,
  port: Int,
  proxy: Proxy,
) -> Result(ProxiedConnection, String) {
  let events = process.new_subject()
  use config <- try(connection_config(port))
  use connection <- try(start_watched(
    config
      |> watched_config(events, first_delay)
      |> configure,
    events,
  ))
  use control <- try(
    start_connection(server.port) |> map_error(stop_after_error(connection, _)),
  )
  let lock_key = unique_lock_key()
  Ok(ProxiedConnection(connection:, control:, proxy:, events:, lock_key:))
}

/// Stops the connection and gives `error`: for a setup that fails after it
/// started the connection.
pub fn stop_after_error(connection: Connection, error: String) -> String {
  stop(connection)
  error
}

/// Stops the connection, the proxy and the control connection. A teardown for
/// `after_each` and for the context setup.
pub fn stop_proxied(proxied: ProxiedConnection) -> Result(Nil, String) {
  Ok(stop_both(proxied))
}

fn stop_both(proxied: ProxiedConnection) -> Nil {
  stop(proxied.connection)
  stop_proxy(proxied.proxy)
  stop(proxied.control)
}

@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_lock_key() -> Int

/// The context of a describe whose tests each get a proxied connection:
/// one for the tree, which gives the context its first value.
/// `start_test_proxied` gives each test its own.
pub fn proxied_setup(
  server: Server,
  first_delay: Int,
) -> Context(ProxiedConnection) {
  context.setup(
    setup: fn() { start_proxied(server, first_delay) },
    teardown: stop_proxied,
  )
}

/// A `before_each` hook that starts a proxied connection for the test.
pub fn start_test_proxied(
  server: Server,
  first_delay: Int,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(_tree_proxied) { start_proxied(server, first_delay) }
}

/// A `before_each` hook that starts a proxied connection with the statement
/// caching `caching` for the test.
pub fn start_test_proxied_with_caching(
  server: Server,
  first_delay: Int,
  caching: StatementCaching,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(_tree_proxied) { start_proxied_with_caching(server, first_delay, caching) }
}

/// A `before_each` hook that starts a proxied connection with the TLS
/// setting `tls` for the test.
pub fn start_test_proxied_with_tls(
  server: Server,
  first_delay: Int,
  tls: Tls,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(_tree_proxied) { start_proxied_with_tls(server, first_delay, tls) }
}

/// A hook that runs the simple query `sql` on the proxied connection, which must
/// work.
pub fn run_proxied_setup_simple_query(
  sql: String,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  setup_step(fn(proxied: ProxiedConnection) {
    run_control_simple_query(proxied.connection, sql)
  })
}

/// A hook that runs the connection hook `hook` on the proxied connection,
/// for example `run_failing_statement(sql)`.
pub fn on_proxied_connection(
  hook: fn(Connection) -> Result(Connection, String),
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  setup_step(fn(proxied: ProxiedConnection) { hook(proxied.connection) })
}

/// A hook that waits for the event `Reconnected` of the proxied
/// connection.
pub fn wait_for_proxied_reconnect(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  wait_for_reconnect(proxied.events) |> replace(proxied)
}

/// What an act gave, with the proxied connection that it ran on.
pub type ProxiedOutcome(outcome) {
  ProxiedOutcome(proxied: ProxiedConnection, outcome: outcome)
}

/// The context of a describe whose tests each check one value of one
/// shared act: the setup starts a proxied connection and runs `act` on it
/// once, and the teardown stops the connection. Use it when the act waits
/// in real time, so the wait happens once.
///
/// ```gleam
/// describe("a late answer", proxied_act_setup(first_driver_server, 60_000, run_late), [
///   it("gives DeadlinePassed", fn(shared) {
///     shared.outcome.late
///     |> should
///     |> be_error
///     |> or_fail_with("Expected DeadlinePassed")
///   }),
/// ])
/// ```
pub fn proxied_act_setup(
  server: Server,
  first_delay: Int,
  act: fn(ProxiedConnection) -> Result(outcome, String),
) -> Context(ProxiedOutcome(outcome)) {
  context.setup(
    setup: fn() { start_proxied(server, first_delay) |> try(run_act(_, act)) },
    teardown: stop_proxied_outcome,
  )
}

fn run_act(
  proxied: ProxiedConnection,
  act: fn(ProxiedConnection) -> Result(outcome, String),
) -> Result(ProxiedOutcome(outcome), String) {
  act(proxied)
  |> result.map(ProxiedOutcome(proxied, _))
  |> map_error(fn(error) {
    stop_both(proxied)
    error
  })
}

fn stop_proxied_outcome(
  shared: ProxiedOutcome(outcome),
) -> Result(Nil, String) {
  stop_proxied(shared.proxied)
}

/// Takes the advisory lock `proxied.lock_key` on the control connection. A
/// hook: the stop of the control connection gives the lock back.
pub fn hold_advisory_lock(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  run_control_simple_query(proxied.control, advisory_lock_sql(proxied.lock_key))
  |> replace(proxied)
}

/// Gives back the advisory lock `proxied.lock_key` of the control
/// connection.
pub fn release_advisory_lock(
  proxied: ProxiedConnection,
) -> Result(Nil, String) {
  run_control_simple_query(
    proxied.control,
    "SELECT pg_advisory_unlock(" <> to_string(proxied.lock_key) <> ")",
  )
}

/// The call that waits for the advisory lock `proxied.lock_key` on the
/// proxied connection, for `start_caller`.
pub fn lock_request(
  proxied: ProxiedConnection,
) -> fn() -> Result(List(Outcome), SimpleQueryError) {
  fn() {
    run_simple_query(
      proxied.connection,
      connection_statement.statement(advisory_lock_sql(proxied.lock_key)),
      5000,
    )
  }
}

/// A hook that runs the simple query `sql` on the control connection, which
/// must work.
pub fn run_control_setup_simple_query(
  sql: String,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  setup_step(fn(proxied: ProxiedConnection) {
    run_control_simple_query(proxied.control, sql)
  })
}

/// The SQL that waits for the advisory lock `key`.
pub fn advisory_lock_sql(key: Int) -> String {
  "SELECT pg_advisory_lock(" <> to_string(key) <> ")"
}

/// A hook that ends the backend of the proxied connection from the control
/// connection, and waits for the event of the loss.
pub fn terminate_session(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  use pid <- try(backend_pid(proxied.connection))
  use _terminated <- try(terminate_backend(proxied.control, pid))
  wait_for_event(proxied)
}

/// A hook that breaks the proxied connection with `breaking`, and waits
/// for the event of the loss.
pub fn break_session(
  breaking: fn(Proxy) -> Nil,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(proxied: ProxiedConnection) {
    breaking(proxied.proxy)
    wait_for_event(proxied)
  }
}

fn wait_for_event(
  proxied: ProxiedConnection,
) -> Result(ProxiedConnection, String) {
  next_event(proxied.events)
  |> replace(proxied)
  |> map_error(fn(_timeout) { "no event within 5 seconds" })
}

/// A hook that sends `bytes` to the client as if the server sent them, and
/// waits until the server parameter `name` is `value`.
pub fn inject_and_wait_for_parameter(
  bytes: BitArray,
  name: String,
  value: String,
) -> fn(ProxiedConnection) -> Result(ProxiedConnection, String) {
  fn(proxied: ProxiedConnection) {
    inject(proxied.proxy, bytes)
    wait_for_parameter(proxied.connection, name, value) |> replace(proxied)
  }
}

// One act for several tests ---------------------------------------------------

/// What an act gave, with what the setup started for it.
pub type ActOutcome(started, outcome) {
  ActOutcome(started: started, outcome: outcome)
}

/// The context of a describe whose tests each check one value of one
/// shared act: `start` starts what the act needs, `act` runs once on it,
/// and the teardown gives it to `stop`. Use it when the act waits in real
/// time, so the wait happens once. When the act fails, the setup stops
/// what it started and fails with the error of the act.
pub fn act_setup(
  start start: fn() -> Result(started, String),
  stop stop: fn(started) -> Result(Nil, String),
  act act: fn(started) -> Result(outcome, String),
) -> Context(ActOutcome(started, outcome)) {
  context.setup(
    setup: fn() { start() |> try(run_shared_act(_, stop, act)) },
    teardown: fn(shared: ActOutcome(started, outcome)) { stop(shared.started) },
  )
}

fn run_shared_act(
  started: started,
  stop: fn(started) -> Result(Nil, String),
  act: fn(started) -> Result(outcome, String),
) -> Result(ActOutcome(started, outcome), String) {
  act(started)
  |> result.map(ActOutcome(started, _))
  |> result.try_recover(fn(error) {
    stop(started) |> try(fn(_stopped) { Error(error) })
  })
}

/// An `act_setup` whose act runs on a new connection to `server`.
///
/// ```gleam
/// describe("a late COPY", connection_act_setup(first_driver_server, copy_late), [
///   it("gives DeadlinePassed", fn(shared: ActOutcome(Connection, LateCopy)) {
///     shared.outcome.copied
///     |> should
///     |> be_error
///     |> or_fail_with("Expected DeadlinePassed")
///   }),
/// ])
/// ```
pub fn connection_act_setup(
  server: Server,
  act: fn(Connection) -> Result(outcome, String),
) -> Context(ActOutcome(Connection, outcome)) {
  act_setup(
    start: fn() { start_connection(server.port) },
    stop: stop_connection,
    act:,
  )
}

/// An `act_setup` whose act runs on a new connection to `server` with a
/// setup timeout and a cancel timeout of 100 milliseconds each. A caller
/// of it waits 200 milliseconds past the deadline of its request.
pub fn short_wait_act_setup(
  server: Server,
  act: fn(Connection) -> Result(outcome, String),
) -> Context(ActOutcome(Connection, outcome)) {
  act_setup(
    start: fn() { start_short_wait(server) },
    stop: stop_connection,
    act:,
  )
}

/// Starts a connection to `server` with a setup timeout and a cancel
/// timeout of 100 milliseconds each.
pub fn start_short_wait(server: Server) -> Result(Connection, String) {
  connection_config(server.port)
  |> result.map(setup_timeout_config(_, 100))
  |> result.map(cancel_timeout_config(_, 100))
  |> try(start_configured)
}

/// An `act_setup` whose act runs on a new connection to `server` that ran
/// `BEGIN`, so the act runs inside a transaction.
pub fn transaction_act_setup(
  server: Server,
  act: fn(Connection) -> Result(outcome, String),
) -> Context(ActOutcome(Connection, outcome)) {
  act_setup(
    start: fn() { start_in_transaction(server) },
    stop: stop_connection,
    act:,
  )
}

/// Starts a connection to `server` and runs `BEGIN` on it.
pub fn start_in_transaction(server: Server) -> Result(Connection, String) {
  use connection <- try(start_connection(server.port))
  run_control_simple_query(connection, "BEGIN")
  |> replace(connection)
  |> map_error(stop_after_error(connection, _))
}

// A connection with a control connection ---------------------------------------

/// A connection straight to the server, its backend process ID, and a
/// control connection beside it.
pub type ControlledConnection {
  ControlledConnection(
    connection: Connection,
    backend_pid: String,
    control: Connection,
  )
}

/// Starts a connection to `server`, asks for its backend process ID, and
/// starts a control connection.
pub fn start_controlled(
  server: Server,
) -> Result(ControlledConnection, String) {
  use connection <- try(start_connection(server.port))
  {
    use backend_pid <- try(backend_pid(connection))
    use control <- try(start_connection(server.port))
    Ok(ControlledConnection(connection:, backend_pid:, control:))
  }
  |> map_error(stop_after_error(connection, _))
}

/// Stops the connection and the control connection. A teardown for
/// `after_each` and for the context setup.
pub fn stop_controlled(
  controlled: ControlledConnection,
) -> Result(Nil, String) {
  stop(controlled.connection)
  Ok(stop(controlled.control))
}

/// The context of a describe whose tests each get a controlled connection:
/// one for the tree, which gives the context its first value.
/// `start_test_controlled` gives each test its own.
pub fn controlled_setup(server: Server) -> Context(ControlledConnection) {
  context.setup(
    setup: fn() { start_controlled(server) },
    teardown: stop_controlled,
  )
}

/// A `before_each` hook that starts a controlled connection for the test.
pub fn start_test_controlled(
  server: Server,
) -> fn(ControlledConnection) -> Result(ControlledConnection, String) {
  fn(_tree_controlled) { start_controlled(server) }
}

/// A hook that runs the simple query `sql` on the controlled connection, which
/// must work.
pub fn run_controlled_setup_simple_query(
  sql: String,
) -> fn(ControlledConnection) -> Result(ControlledConnection, String) {
  setup_step(fn(controlled: ControlledConnection) {
    run_control_simple_query(controlled.connection, sql)
  })
}

/// An `act_setup` whose act runs on a new controlled connection to
/// `server`.
pub fn controlled_act_setup(
  server: Server,
  act: fn(ControlledConnection) -> Result(outcome, String),
) -> Context(ActOutcome(ControlledConnection, outcome)) {
  act_setup(
    start: fn() { start_controlled(server) },
    stop: stop_controlled,
    act:,
  )
}

// Events ----------------------------------------------------------------------

/// The next event, or `Error(Nil)` after 5 seconds.
pub fn next_event(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  process.receive(events, 5000)
}

/// Waits for the event `Reconnected`, and drops the events before it.
pub fn wait_for_reconnect(
  events: Subject(ConnectionEvent),
) -> Result(Nil, String) {
  case next_event(events) {
    Ok(Reconnected) -> Ok(Nil)
    Ok(_other) -> wait_for_reconnect(events)
    Error(Nil) -> Error("no reconnect within 5 seconds")
  }
}

/// The next event that is not a reconnect refused with 28P01.
pub fn next_event_after_refused_reconnects(
  events: Subject(ConnectionEvent),
) -> Result(ConnectionEvent, Nil) {
  case next_event(events) {
    Ok(ReconnectFailed(LoginRefused(ServerRejectedLogin(report))))
      if report.code == "28P01"
    -> next_event_after_refused_reconnects(events)
    other -> other
  }
}

// Backends --------------------------------------------------------------------

/// The backend process ID of the connection, as text.
pub fn backend_pid(connection: Connection) -> Result(String, String) {
  query_text(connection, "SELECT pg_backend_pid()::text")
}

/// The one text cell that `sql` gives on the connection.
pub fn query_text(
  connection: Connection,
  sql: String,
) -> Result(String, String) {
  run_simple_query(connection, connection_statement.statement(sql), 5000)
  |> single_text
}

/// The backend process ID of the session that waits for the advisory lock
/// `key`, as text.
pub fn lock_waiter_pid(
  control: Connection,
  key: Int,
) -> Result(String, String) {
  query_text(control, lock_waiters(key, "pid::text"))
}

fn single_text(
  answer: Result(List(Outcome), SimpleQueryError),
) -> Result(String, String) {
  case answer {
    Ok([Outcome(result: CommandResult(rows: [[Text(bytes)]], ..), ..)]) ->
      bit_array.to_string(bytes)
      |> map_error(fn(_nil) { "expected UTF-8 text" })
    other -> Error("expected one text cell: " <> inspect(other))
  }
}

/// Ends the backend of `pid` from the control connection. The server sends
/// it the FATAL error 57P01, then closes its socket.
pub fn terminate_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, String) {
  run_control_simple_query(
    control,
    "SELECT pg_terminate_backend(" <> pid <> ")",
  )
}

/// Sends the connection process a message that is not about its socket.
@external(erlang, "driver_connection_test_ffi", "send_stray_message")
pub fn send_stray_message(connection: Connection) -> Nil

/// Suspends the connection process, so it answers no request until
/// `resume_connection`.
pub fn suspend_connection(connection: Connection) -> Nil {
  suspend(pid_of(connection))
}

/// Resumes a connection process that `suspend_connection` suspended.
pub fn resume_connection(connection: Connection) -> Nil {
  resume(pid_of(connection))
}

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "sys", "resume")
fn resume(pid: Pid) -> Nil

/// The process of a connection.
@external(erlang, "driver_connection_test_ffi", "pid_of")
pub fn pid_of(connection: Connection) -> Pid

/// The memory of a process, with the binaries it references, and the
/// length of its mailbox.
@external(erlang, "driver_copy_test_ffi", "memory_of")
pub fn memory_of(pid: Pid) -> Result(#(Int, Int), String)

/// Sends a process a DOWN message of a monitor that it never made.
@external(erlang, "driver_copy_test_ffi", "send_stray_down")
pub fn send_stray_down(pid: Pid) -> Nil

/// The bytes of the ErrorResponse that a server sends when an
/// administrator ends the session: FATAL, 57P01.
pub fn fatal_error_bytes() -> BitArray {
  let body = <<
    "SFATAL":utf8, 0, "VFATAL":utf8, 0, "C57P01":utf8, 0,
    "Mterminating connection due to administrator command":utf8, 0, 0,
  >>
  <<"E", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

// Waiting without a sleep -----------------------------------------------------

/// Waits until a message with one of the tags waits in the mailbox of
/// `pid`, for example `request`, `copy_call` or `tcp`. It looks again each
/// time, at most `attempts` times: no sleep.
@external(erlang, "driver_copy_test_ffi", "wait_for_message")
pub fn wait_for_message(
  pid: Pid,
  tags: List(String),
  attempts: Int,
) -> Result(Nil, String)

/// Waits until at least `length` messages wait in the mailbox of `pid`.
@external(erlang, "driver_copy_test_ffi", "wait_for_mailbox_length")
pub fn wait_for_mailbox_length(
  pid: Pid,
  length: Int,
  attempts: Int,
) -> Result(Nil, String)

/// Waits until the reset of the peer reached the TCP socket of `pid`.
@external(erlang, "driver_copy_test_ffi", "wait_for_reset")
pub fn wait_for_reset(pid: Pid, attempts: Int) -> Result(Nil, String)

/// Waits until the backend `pid` is idle. It asks the control connection
/// again each time: no sleep.
pub fn wait_for_idle_backend(
  control: Connection,
  pid: String,
) -> Result(Nil, String) {
  let sql = "SELECT state FROM pg_stat_activity WHERE pid = " <> pid
  wait_for_text(control, sql, "idle", 1_000_000)
}

fn wait_for_text(
  control: Connection,
  sql: String,
  text: String,
  attempts: Int,
) -> Result(Nil, String) {
  case query_text(control, sql), attempts {
    Ok(answer), _ if answer == text -> Ok(Nil)
    _other, 0 -> Error("the answer to " <> sql <> " did not become " <> text)
    _other, _ -> wait_for_text(control, sql, text, attempts - 1)
  }
}

/// Waits until one session of the server waits for the advisory lock
/// `key`. It asks the control connection again each time: no sleep.
pub fn wait_for_lock_waiter(
  control: Connection,
  key: Int,
) -> Result(Nil, String) {
  wait_for_one(control, lock_waiters(key, "count(*)::text"), 5000)
}

/// Waits until one session of the server waits for a lock on `table`.
pub fn wait_for_table_waiter(
  control: Connection,
  table: String,
) -> Result(Nil, String) {
  let sql =
    "SELECT count(*)::text FROM pg_locks WHERE locktype = 'relation' AND NOT granted AND relation = '"
    <> table
    <> "'::regclass"
  wait_for_one(control, sql, 5000)
}

fn lock_waiters(key: Int, column: String) -> String {
  "SELECT "
  <> column
  <> " FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid = "
  <> to_string(key)
}

fn wait_for_one(
  control: Connection,
  sql: String,
  attempts: Int,
) -> Result(Nil, String) {
  case
    run_simple_query(control, connection_statement.statement(sql), 5000),
    attempts
  {
    Ok([Outcome(result: CommandResult(rows: [[Text(<<"1">>)]], ..), ..)]), _ ->
      Ok(Nil)
    Error(error), _ -> Error("could not ask for waiters: " <> inspect(error))
    _, 0 -> Error("no session waited: " <> sql)
    _, _ -> wait_for_one(control, sql, attempts - 1)
  }
}

/// Asks for the server parameter `name` until it is `value`. A snapshot
/// request comes after the bytes that came before it, so once the value is
/// there, the process handled all of them. No sleep.
pub fn wait_for_parameter(
  connection: Connection,
  name: String,
  value: String,
) -> Result(Nil, String) {
  wait_for_value(connection, name, value, 5000)
}

fn wait_for_value(
  connection: Connection,
  name: String,
  value: String,
  attempts: Int,
) -> Result(Nil, String) {
  case server_parameter(connection, name) == Ok(Some(value)), attempts {
    True, _ -> Ok(Nil)
    False, 0 -> Error("the parameter " <> name <> " did not become " <> value)
    False, _ -> wait_for_value(connection, name, value, attempts - 1)
  }
}

/// Asks for the transaction status `count` times more, so a request that
/// a caller sent before has reached the connection process. No sleep.
pub fn ask_transaction_status(
  connection: Connection,
  count: Int,
) -> Result(Nil, String) {
  case transaction_status(connection), count {
    Error(error), _ ->
      Error("could not ask for the transaction status: " <> inspect(error))
    Ok(_status), 0 -> Ok(Nil)
    Ok(_status), _ -> ask_transaction_status(connection, count - 1)
  }
}

// Callers in their own processes ----------------------------------------------

/// A process that makes one call and sends its answer back.
pub type Caller(answer) {
  Caller(answers: Subject(answer), pid: Pid)
}

/// Starts a process, not linked to the test, that makes `call` and sends
/// the answer back.
pub fn start_caller(call: fn() -> answer) -> Caller(answer) {
  let answers = process.new_subject()
  let pid = process.spawn_unlinked(fn() { process.send(answers, call()) })
  Caller(answers:, pid:)
}

/// Starts a process, not linked to the test, that makes `call` and sends
/// the answer back, and waits until the call is about to start. An error
/// after 5 seconds.
pub fn start_announced_caller(
  call: fn() -> answer,
) -> Result(Caller(answer), String) {
  let calling = process.new_subject()
  let caller = start_caller(fn() { announce_and_call(call, calling) })
  process.receive(calling, 5000)
  |> replace(caller)
  |> map_error(fn(_timeout) { "the caller did not start within 5 seconds" })
}

fn announce_and_call(call: fn() -> answer, calling: Subject(Nil)) -> answer {
  process.send(calling, Nil)
  call()
}

/// The answer of the caller, or an error after 5 seconds.
pub fn caller_answer(caller: Caller(answer)) -> Result(answer, String) {
  process.receive(caller.answers, 5000)
  |> map_error(fn(_timeout) { "the caller gave no answer within 5 seconds" })
}

/// The outcomes of a caller of a simple query, with an error when the caller
/// gave no answer or the simple query failed: for a step of a setup.
pub fn caller_outcomes(
  caller: Caller(Result(List(Outcome), SimpleQueryError)),
) -> Result(List(Outcome), String) {
  use answer <- try(caller_answer(caller))
  answer
  |> map_error(fn(error) {
    "the caller's simple query failed: " <> inspect(error)
  })
}

/// Makes `start` in a process that traps exits and then ends, and gives
/// what `start` gave. A supervisor that fails to start does not take the
/// process down before it answers, and what `start` linked to the process
/// sees it end.
pub fn start_in_ended_owner(start: fn() -> answer) -> Result(answer, String) {
  let answers = process.new_subject()
  process.spawn_unlinked(fn() { owner_body(start, answers) })
  process.receive(answers, 5000)
  |> map_error(fn(_timeout) { "the owner gave no answer within 5 seconds" })
}

fn owner_body(start: fn() -> answer, answers: Subject(answer)) -> Nil {
  process.trap_exits(True)
  process.send(answers, start())
}

// Supervised connections -------------------------------------------------------

/// Starts a supervisor with one connection of `config` as its child, and
/// gives the process of the supervisor. `stop_supervisor` stops it.
pub fn start_supervised_connection(
  config: Result(ConnectionConfig, String),
) -> Result(Pid, String) {
  use settings <- try(config)
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervised(settings))
  |> static_supervisor.start
  |> result.map(fn(started) { started.pid })
  |> map_error(fn(error) { "could not start a supervisor: " <> inspect(error) })
}

/// The context of a describe whose tests each check a supervisor with
/// one connection of `config` as its child. The teardown stops it.
pub fn supervised_connection_setup(
  config: Result(ConnectionConfig, String),
) -> Context(Pid) {
  context.setup(
    setup: fn() { start_supervised_connection(config) },
    teardown: stop_supervisor,
  )
}

/// Stops a supervisor that `start_supervised_connection` started, and its
/// connection, and waits until the supervisor is down. A teardown for the
/// context setup.
pub fn stop_supervisor(supervisor: Pid) -> Result(Nil, String) {
  Ok(stop_process(supervisor))
}

@external(erlang, "driver_parity_ffi", "stop_process")
fn stop_process(pid: Pid) -> Nil
