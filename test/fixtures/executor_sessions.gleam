//// The sessions of the driver executor tests: one driver connection and
//// one type catalog for each driver server, and the version that a group
//// of tests runs on. Start them with `start` and stop them with `stop` in
//// the lifecycle hooks of a suite, and pick the version of a group with
//// `choose_version` in its `before_all`.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection.{
  type Connection, Backoff, ConnectionConfig,
}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message
import dream_postgres/driver/transport.{NoTls, TransportConfig}
import driver/servers.{type Server, driver_servers}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

/// One connection and one type catalog for one driver server.
pub type ExecutorSession {
  ExecutorSession(version: Int, connection: Connection, catalog: Catalog)
}

/// The session of each driver server, and the version that the tests of a
/// group run on.
pub type ExecutorSessions {
  ExecutorSessions(sessions: List(ExecutorSession), version: Int)
}

/// The deadline of each query of an executor test.
pub const deadline_milliseconds = 5000

/// Starts one session on each driver server. When one cannot start, the
/// others stop again. No version is chosen yet.
///
/// ## Example
///
/// ```gleam
/// context.setup(executor_sessions.start, teardown: executor_sessions.stop)
/// ```
pub fn start() -> Result(ExecutorSessions, String) {
  let started = list.map(driver_servers(), start_session)
  case result.all(started) {
    Ok(sessions) -> Ok(ExecutorSessions(sessions:, version: 0))
    Error(reason) -> {
      started |> result.values |> list.each(stop_session)
      Error(reason)
    }
  }
}

/// Stops the connection and the catalog of each session.
///
/// ## Example
///
/// ```gleam
/// context.setup(executor_sessions.start, teardown: executor_sessions.stop)
/// ```
pub fn stop(sessions: ExecutorSessions) -> Result(Nil, String) {
  list.each(sessions.sessions, stop_session)
  Ok(Nil)
}

/// A `before_all` hook that makes `version` the version of the tests of a
/// group. The hook fails when no session has that version.
///
/// ## Example
///
/// ```gleam
/// group("PostgreSQL 16", [before_all(executor_sessions.choose_version(16))])
/// ```
pub fn choose_version(
  version: Int,
) -> fn(ExecutorSessions) -> Result(ExecutorSessions, String) {
  fn(sessions: ExecutorSessions) {
    let chosen_sessions = ExecutorSessions(..sessions, version:)
    chosen(chosen_sessions) |> result.replace(chosen_sessions)
  }
}

/// The session of the chosen version.
///
/// ## Example
///
/// ```gleam
/// executor_sessions.chosen(sessions)
/// // -> Ok(ExecutorSession(version: 16, ..))
/// ```
pub fn chosen(sessions: ExecutorSessions) -> Result(ExecutorSession, String) {
  list.find(sessions.sessions, fn(session) {
    session.version == sessions.version
  })
  |> result.replace_error(
    "no executor session for PostgreSQL " <> int.to_string(sessions.version),
  )
}

fn stop_session(session: ExecutorSession) -> Nil {
  connection.stop(session.connection)
  catalog.stop(session.catalog)
}

fn start_session(server: Server) -> Result(ExecutorSession, String) {
  use address <- result.try(
    transport.address("localhost", server.port)
    |> result.map_error(string.inspect),
  )
  use login_config <- result.try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password(servers.password),
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: message.Protocol30,
    )
    |> result.map_error(string.inspect),
  )
  use started <- result.try(
    connection.start(ConnectionConfig(
      transport: TransportConfig(address, NoTls, 5000, 500),
      login: login_config,
      setup_timeout_milliseconds: 5000,
      cancel_timeout_milliseconds: 2000,
      reconnect: Backoff(10, 60_000, connection.full_jitter),
      events: None,
      notifications: None,
      notices: None,
      statements: connection.CacheStatements(limit: 512),
    ))
    |> result.map_error(string.inspect),
  )
  case catalog.start(None) {
    Ok(started_catalog) ->
      Ok(ExecutorSession(
        version: server.version,
        connection: started,
        catalog: started_catalog,
      ))
    Error(start_error) -> {
      connection.stop(started)
      Error(string.inspect(start_error))
    }
  }
}
