//// Test fixtures that start pools on the driver servers: the pool config,
//// a started pool with a control connection beside it, a pool through a
//// test proxy, a pool that another process owns, a pool under a name and a
//// supervisor, callers that hold a connection in their own processes, the
//// processes inside a pool, and waits that ask again instead of a sleep.
////
//// Each fixture that can fail gives a `Result` with a text error, so a
//// setup of dream_test reports the failure as a failed setup. The hooks
//// are for `dream_test/unit_context`: a describe gets its first context
//// from `pool_session_setup` or `proxied_pool_setup`, each test starts its
//// own pool in `before_each` and stops it in `after_each`. A pool keeps its
//// connections open on the shared servers until it stops, so every start
//// has a stop.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionEvent, type Outcome, type ScriptError, Backoff,
  Connected, ConnectionConfig, Disconnected, ReconnectFailed, run_script, stop,
  transaction_status,
}
import dream_postgres/driver/pool.{
  type HoldError, type Pool, type PoolConfig, type PoolEvent, type PoolMessage,
  type PoolStatus, MemberFree, PoolConfig,
}
import dream_postgres/internal/cell.{type TransactionStatus}
import dream_test/context.{type Context}
import driver/proxy.{type Proxy, start_proxy, stop_proxy}
import driver/server_connection.{
  type ActOutcome, act_setup, advisory_lock_sql, backend_pid, connection_config,
  pid_of, query_text, run_control_script, start_connection, user_config,
}
import driver/servers.{type Server}
import fixtures/backoff_strategies.{capped_delay}
import fixtures/identity_sink.{identity_sink}
import gleam/bool
import gleam/erlang/process.{
  type Down, type ExitMessage, type ExitReason, type Name, type Pid,
  type Subject,
}
import gleam/int.{to_string}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor.{type Started}
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result.{flatten, map_error, replace, try}
import gleam/string.{inspect}

// Configs ---------------------------------------------------------------------

/// The settings of a pool of connections with `connection`, with no health
/// check in the time of a test, and deadlines of 5 seconds.
pub fn pool_config(connection: connection.ConnectionConfig) -> PoolConfig(Nil) {
  PoolConfig(
    connection:,
    health_check_interval_milliseconds: 60_000,
    health_check_deadline_milliseconds: 5000,
    rollback_deadline_milliseconds: 5000,
    shutdown_deadline_milliseconds: 5000,
    events: None,
    attachment: Nil,
  )
}

/// The settings of a pool of connections as `dream` to localhost on
/// `port`.
pub fn dream_pool_config(port: Int) -> Result(PoolConfig(Nil), String) {
  connection_config(port) |> result.map(pool_config)
}

/// The settings of a pool of connections as `user` with `password` to
/// localhost on `port`.
pub fn user_pool_config(
  port: Int,
  user: String,
  password: String,
) -> Result(PoolConfig(Nil), String) {
  user_config(port, user, password) |> result.map(pool_config)
}

/// The config with a health check every `interval` milliseconds, whose
/// query may take `deadline` milliseconds.
pub fn health_check_config(
  config: PoolConfig(attachment),
  interval: Int,
  deadline: Int,
) -> PoolConfig(attachment) {
  PoolConfig(
    ..config,
    health_check_interval_milliseconds: interval,
    health_check_deadline_milliseconds: deadline,
  )
}

/// The config with a rollback deadline of `deadline` milliseconds.
pub fn rollback_deadline_config(
  config: PoolConfig(attachment),
  deadline: Int,
) -> PoolConfig(attachment) {
  PoolConfig(..config, rollback_deadline_milliseconds: deadline)
}

/// The config of connections that connect again only after a test.
pub fn slow_reconnect_config(
  config: PoolConfig(attachment),
) -> PoolConfig(attachment) {
  PoolConfig(
    ..config,
    connection: ConnectionConfig(
      ..config.connection,
      reconnect: Backoff(60_000, 60_000, capped_delay),
    ),
  )
}

fn watched_pool_config(
  config: PoolConfig(attachment),
  events: Subject(ConnectionEvent),
  pool_events: Subject(PoolEvent),
) -> PoolConfig(attachment) {
  PoolConfig(
    ..config,
    connection: ConnectionConfig(
      ..config.connection,
      events: Some(identity_sink(events)),
    ),
    events: Some(identity_sink(pool_events)),
  )
}

// Started pools ---------------------------------------------------------------

/// Starts a pool of `size` connections with `config`.
pub fn start_pool(
  config: PoolConfig(attachment),
  size: Int,
) -> Result(Pool(attachment), String) {
  pool.start(config, size)
  |> map_error(fn(error) { "could not start a pool: " <> inspect(error) })
}

/// Stops the pool with a deadline of 1 second for its holds. A pool that
/// stopped already stays stopped.
pub fn stop_pool(pool: Pool(attachment)) -> Result(Nil, String) {
  Ok(pool.stop(pool, 1000))
}

/// A pool, the events of its connections, a control connection straight
/// to the server, and an advisory lock key that no other test uses.
pub type PoolSession {
  PoolSession(
    pool: Pool(Nil),
    control: Connection,
    events: Subject(ConnectionEvent),
    /// The events of the pool's members.
    pool_events: Subject(PoolEvent),
    lock_key: Int,
  )
}

/// Starts a pool of `size` connections with `config`, with its events sent
/// to a new subject, and a control connection to `server`.
pub fn start_pool_session(
  server: Server,
  config: Result(PoolConfig(Nil), String),
  size: Int,
) -> Result(PoolSession, String) {
  use config <- try(config)
  let events = process.new_subject()
  let pool_events = process.new_subject()
  use started <- try(start_pool(
    watched_pool_config(config, events, pool_events),
    size,
  ))
  {
    use control <- try(start_connection(server.port))
    let lock_key = unique_lock_key()
    Ok(PoolSession(pool: started, control:, events:, pool_events:, lock_key:))
  }
  |> map_error(stop_pool_after_error(started, _))
}

/// Stops the pool and gives `error`: for a setup that fails after it
/// started the pool.
pub fn stop_pool_after_error(pool: Pool(attachment), error: String) -> String {
  pool.stop(pool, 1000)
  error
}

/// Stops the pool and the control connection. A teardown for `after_each`
/// and for the context setup.
pub fn stop_pool_session(session: PoolSession) -> Result(Nil, String) {
  pool.stop(session.pool, 1000)
  Ok(stop(session.control))
}

@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_lock_key() -> Int

/// The context of a describe whose tests each get a pool: one pool of one
/// connection to `server` for the tree, which gives the context its first
/// value. `start_test_pool` gives each test its own.
///
/// ```gleam
/// describe("pool", pool_session_setup(first_driver_server), [
///   before_each(start_test_pool(first_driver_server, 1)),
///   after_each(stop_pool_session),
///   it("gives its status", fn(session: PoolSession) {
///     pool.status(session.pool)
///     |> should
///     |> be_ok
///     |> or_fail_with("Expected the status")
///   }),
/// ])
/// ```
pub fn pool_session_setup(server: Server) -> Context(PoolSession) {
  context.setup(
    setup: fn() {
      start_pool_session(server, dream_pool_config(server.port), 1)
    },
    teardown: stop_pool_session,
  )
}

/// A `before_each` hook that starts a pool of `size` connections as
/// `dream` to `server` for the test.
pub fn start_test_pool(
  server: Server,
  size: Int,
) -> fn(PoolSession) -> Result(PoolSession, String) {
  start_test_pool_configured(server, dream_pool_config(server.port), size)
}

/// A `before_each` hook that starts a pool of `size` connections with
/// `config` for the test, with a control connection to `server`.
pub fn start_test_pool_configured(
  server: Server,
  config: Result(PoolConfig(Nil), String),
  size: Int,
) -> fn(PoolSession) -> Result(PoolSession, String) {
  fn(_tree_session) { start_pool_session(server, config, size) }
}

// Pools through a proxy -------------------------------------------------------

/// A pool of one connection through a test proxy, the events of its
/// connections, a control connection straight to the server, and an
/// advisory lock key that no other test uses. The proxy serves one client
/// after the other, so the pool has one connection.
pub type ProxiedPool {
  ProxiedPool(
    pool: Pool(Nil),
    proxy: Proxy,
    /// The port of the proxy, which the pool's connections connect to.
    proxy_port: Int,
    control: Connection,
    events: Subject(ConnectionEvent),
    pool_events: Subject(PoolEvent),
    lock_key: Int,
  )
}

/// Starts a pool of one connection to `server` through a new proxy, with
/// the dream config that `configure` changes, and a control connection.
pub fn start_proxied_pool(
  server: Server,
  configure: fn(PoolConfig(Nil)) -> PoolConfig(Nil),
) -> Result(ProxiedPool, String) {
  use #(port, proxy) <- try(start_proxy(server.port))
  {
    use config <- try(dream_pool_config(port))
    use session <- try(start_pool_session(server, Ok(configure(config)), 1))
    Ok(ProxiedPool(
      pool: session.pool,
      proxy:,
      proxy_port: port,
      control: session.control,
      events: session.events,
      pool_events: session.pool_events,
      lock_key: session.lock_key,
    ))
  }
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

/// Stops the pool, the proxy and the control connection. A teardown for
/// `after_each` and for the context setup.
pub fn stop_proxied_pool(proxied: ProxiedPool) -> Result(Nil, String) {
  pool.stop(proxied.pool, 1000)
  stop_proxy(proxied.proxy)
  Ok(stop(proxied.control))
}

/// The context of a describe whose tests each get a proxied pool: one for
/// the tree, which gives the context its first value.
/// `start_test_proxied_pool` gives each test its own.
pub fn proxied_pool_setup(server: Server) -> Context(ProxiedPool) {
  context.setup(
    setup: fn() { start_proxied_pool(server, unchanged_config) },
    teardown: stop_proxied_pool,
  )
}

/// A `before_each` hook that starts a proxied pool with the dream config
/// for the test.
pub fn start_test_proxied_pool(
  server: Server,
) -> fn(ProxiedPool) -> Result(ProxiedPool, String) {
  start_test_proxied_pool_configured(server, unchanged_config)
}

/// A `before_each` hook that starts a proxied pool with the dream config
/// that `configure` changes for the test.
pub fn start_test_proxied_pool_configured(
  server: Server,
  configure: fn(PoolConfig(Nil)) -> PoolConfig(Nil),
) -> fn(ProxiedPool) -> Result(ProxiedPool, String) {
  fn(_tree_proxied) { start_proxied_pool(server, configure) }
}

/// The config as it is: for a proxied pool with the dream config.
pub fn unchanged_config(
  config: PoolConfig(attachment),
) -> PoolConfig(attachment) {
  config
}

// One act for several tests ---------------------------------------------------

/// An `act_setup` whose act runs on a new pool session of one connection
/// to `server`.
///
/// ```gleam
/// describe("a drain", pool_act_setup(first_driver_server, drain), [
///   it("refuses a checkout", fn(shared: ActOutcome(PoolSession, Drained)) {
///     shared.outcome.refused
///     |> should
///     |> be_error
///     |> be_equal(PoolStopped)
///     |> or_fail_with("Expected PoolStopped")
///   }),
/// ])
/// ```
pub fn pool_act_setup(
  server: Server,
  act: fn(PoolSession) -> Result(outcome, String),
) -> Context(ActOutcome(PoolSession, outcome)) {
  act_setup(
    start: fn() {
      start_pool_session(server, dream_pool_config(server.port), 1)
    },
    stop: stop_pool_session,
    act:,
  )
}

/// An `act_setup` whose act runs on a new proxied pool to `server` with
/// the dream config that `configure` changes.
pub fn proxied_pool_act_setup(
  server: Server,
  configure: fn(PoolConfig(Nil)) -> PoolConfig(Nil),
  act: fn(ProxiedPool) -> Result(outcome, String),
) -> Context(ActOutcome(ProxiedPool, outcome)) {
  act_setup(
    start: fn() { start_proxied_pool(server, configure) },
    stop: stop_proxied_pool,
    act:,
  )
}

// Holds -----------------------------------------------------------------------

/// Holds a connection of the pool for `callback`, with a deadline of 5
/// seconds, and gives what the callback gave.
pub fn hold_connection(
  pool: Pool(attachment),
  callback: fn(Connection) -> Result(value, String),
) -> Result(value, String) {
  pool.hold(pool, 5000, callback)
  |> map_error(fn(error) { "could not hold a connection: " <> inspect(error) })
  |> flatten
}

/// The backend process ID of a connection that the pool hands out.
pub fn held_backend_pid(pool: Pool(attachment)) -> Result(String, String) {
  hold_connection(pool, backend_pid)
}

/// The status of the pool.
pub fn pool_status(pool: Pool(attachment)) -> Result(PoolStatus, String) {
  pool.status(pool)
  |> map_error(fn(error) { "could not ask for the status: " <> inspect(error) })
}

/// The transaction status of a connection that the pool hands out.
pub fn held_transaction_status(
  pool: Pool(attachment),
) -> Result(TransactionStatus, String) {
  hold_connection(pool, connection_status)
}

/// The transaction status of the connection.
pub fn connection_status(
  connection: Connection,
) -> Result(TransactionStatus, String) {
  transaction_status(connection)
  |> map_error(fn(error) {
    "could not ask for the transaction status: " <> inspect(error)
  })
}

/// Begins a transaction, and gives the transaction status after it.
pub fn begin_transaction(
  connection: Connection,
) -> Result(TransactionStatus, String) {
  use _begun <- try(run_control_script(connection, "BEGIN"))
  connection_status(connection)
}

/// Begins a transaction, and gives the backend process ID.
pub fn begin_on_backend(connection: Connection) -> Result(String, String) {
  use _begun <- try(run_control_script(connection, "BEGIN"))
  backend_pid(connection)
}

/// Gives the backend process ID, and stops the connection.
pub fn stop_on_backend(connection: Connection) -> Result(String, String) {
  use pid <- try(backend_pid(connection))
  stop(connection)
  Ok(pid)
}

/// Holds `count` connections of the pool at the same time, and gives what
/// `act` gives with them.
pub fn while_holding(
  pool: Pool(attachment),
  count: Int,
  act: fn(List(Connection)) -> value,
) -> Result(value, String) {
  hold_more(pool, count, [], act)
}

fn hold_more(
  pool: Pool(attachment),
  count: Int,
  held: List(Connection),
  act: fn(List(Connection)) -> value,
) -> Result(value, String) {
  case count {
    0 -> Ok(act(held))
    _ ->
      hold_connection(pool, fn(connection) {
        hold_more(pool, count - 1, [connection, ..held], act)
      })
  }
}

/// Gives the backend process ID, and the server's time after a query on
/// the connection.
pub fn backend_pid_and_time(
  connection: Connection,
) -> Result(#(String, String), String) {
  use pid <- try(backend_pid(connection))
  use time <- try(query_text(connection, "SELECT clock_timestamp()::text"))
  Ok(#(pid, time))
}

/// The callback of a hold that kills the process of its connection, and
/// holds again inside the hold: it gives the backend process IDs of the
/// killed connection and of the one that the pool hands out after it.
pub fn kill_and_hold_again(
  pool: Pool(attachment),
) -> fn(Connection) -> Result(#(String, String), String) {
  fn(connection) {
    use first <- try(backend_pid(connection))
    kill_connection(connection)
    use second <- try(held_backend_pid(pool))
    Ok(#(first, second))
  }
}

/// The call that holds a connection of the pool and gives the one text
/// cell that `sql` gives on it, for `start_caller`.
pub fn query_in_hold(
  pool: Pool(attachment),
  sql: String,
) -> fn() -> Result(String, String) {
  fn() { hold_connection(pool, query_text(_, sql)) }
}

/// The call that holds a connection of the pool and runs the script `sql`
/// on it, for `start_caller`.
pub fn script_in_hold(
  pool: Pool(attachment),
  sql: String,
) -> fn() -> Result(Result(List(Outcome), ScriptError), HoldError) {
  fn() { pool.hold(pool, 5000, run_script(_, connection.statement(sql), 5000)) }
}

/// The callback of a hold that stops the pool of `handle` with a deadline
/// of 20 milliseconds, and gives `"stopped"`.
pub fn stop_pool_inside(handle: Pool(attachment)) -> fn(Connection) -> String {
  fn(_connection) {
    pool.stop(handle, 20)
    "stopped"
  }
}

// A caller that holds a connection --------------------------------------------

/// A process, not linked to the test, that holds a connection of a pool
/// until `release_holder` or `kill_holder`, or 10 seconds at most, with
/// what `prepare` gave on the connection.
pub type Holder(prepared) {
  Holder(
    prepared: prepared,
    release: Subject(Nil),
    answer: Subject(Result(Result(Nil, Nil), HoldError)),
    pid: Pid,
  )
}

/// Starts a holder of a connection of the pool, runs `prepare` on the
/// connection, and waits until it did. An error after 5 seconds.
pub fn start_holder(
  pool: Pool(attachment),
  prepare: fn(Connection) -> prepared,
) -> Result(Holder(prepared), String) {
  let ready = process.new_subject()
  let answer = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(answer, pool.hold(pool, 5000, keep_held(_, prepare, ready)))
    })
  process.receive(ready, 5000)
  |> result.map(fn(held) { Holder(held.0, held.1, answer, pid) })
  |> map_error(fn(_timeout) {
    process.kill(pid)
    "the holder got no connection within 5 seconds"
  })
}

fn keep_held(
  connection: Connection,
  prepare: fn(Connection) -> prepared,
  ready: Subject(#(prepared, Subject(Nil))),
) -> Result(Nil, Nil) {
  let release = process.new_subject()
  process.send(ready, #(prepare(connection), release))
  process.receive(release, 10_000)
}

/// Starts a holder of a connection of the pool that does nothing with the
/// connection.
pub fn start_idle_holder(
  pool: Pool(attachment),
) -> Result(Holder(Nil), String) {
  start_holder(pool, fn(_connection) { Nil })
}

/// Ends the hold of the holder, and waits until the hold ended.
pub fn release_holder(holder: Holder(prepared)) -> Result(Nil, String) {
  process.send(holder.release, Nil)
  case process.receive(holder.answer, 5000) {
    Ok(Ok(Ok(Nil))) -> Ok(Nil)
    other -> {
      process.kill(holder.pid)
      Error("the holder did not end its hold: " <> inspect(other))
    }
  }
}

/// Kills the holder, as a caller that exits during its hold, and gives
/// what `prepare` gave.
pub fn kill_holder(holder: Holder(prepared)) -> prepared {
  process.kill(holder.pid)
  holder.prepared
}

/// Holds a connection in a holder, begins a transaction on it, and kills
/// the holder. A hook; it fails when the transaction did not begin.
pub fn exit_holder_in_transaction(
  session: PoolSession,
) -> Result(PoolSession, String) {
  use holder <- try(start_holder(session.pool, begin_transaction))
  kill_holder(holder) |> replace(session)
}

/// A hook that holds a connection, begins a transaction, and ends the hold
/// with the transaction open.
pub fn leave_transaction_open(
  session: PoolSession,
) -> Result(PoolSession, String) {
  hold_connection(session.pool, begin_on_backend) |> replace(session)
}

/// A hook that takes the advisory lock `session.lock_key` on the control
/// connection. The stop of the control connection gives the lock back.
pub fn hold_pool_lock(session: PoolSession) -> Result(PoolSession, String) {
  run_control_script(session.control, advisory_lock_sql(session.lock_key))
  |> replace(session)
}

/// Gives back the advisory lock `session.lock_key` of the control
/// connection.
pub fn release_pool_lock(session: PoolSession) -> Result(Nil, String) {
  run_control_script(
    session.control,
    "SELECT pg_advisory_unlock(" <> to_string(session.lock_key) <> ")",
  )
}

// A pool that another process owns ---------------------------------------------

/// A pool that a process, not linked to the test, started and owns, and
/// the subject that ends the owner. The owner ends after 10 seconds at
/// most.
pub type OwnedPool {
  OwnedPool(pool: Pool(Nil), owner: Subject(Nil))
}

/// Starts a pool of `size` connections with `config` in a new owner
/// process. An error after 5 seconds.
pub fn start_owned_pool(
  config: PoolConfig(Nil),
  size: Int,
) -> Result(OwnedPool, String) {
  let started = process.new_subject()
  process.spawn_unlinked(fn() { own_pool(config, size, started) })
  process.receive(started, 5000)
  |> map_error(fn(_timeout) { "the owner gave no pool within 5 seconds" })
  |> flatten
}

fn own_pool(
  config: PoolConfig(Nil),
  size: Int,
  started: Subject(Result(OwnedPool, String)),
) -> Result(Nil, Nil) {
  let owner = process.new_subject()
  process.send(
    started,
    start_pool(config, size) |> result.map(OwnedPool(_, owner)),
  )
  process.receive(owner, 10_000)
}

/// Ends the owner of the pool, so the pool stops with it.
pub fn end_owner(owned: OwnedPool) -> Nil {
  process.send(owned.owner, Nil)
}

/// Starts a pool of one connection with `config` in a process that traps
/// exits, kills the supervisor of the pool's members, and gives the exit
/// reason of the pool. An error after 5 seconds.
pub fn exit_after_supervisor_kill(
  config: PoolConfig(attachment),
) -> Result(ExitReason, String) {
  let exits = process.new_subject()
  process.spawn_unlinked(fn() { kill_supervisor(config, exits) })
  process.receive(exits, 5000)
  |> map_error(fn(_timeout) { "the owner gave no exit within 5 seconds" })
  |> flatten
}

fn kill_supervisor(
  config: PoolConfig(attachment),
  exits: Subject(Result(ExitReason, String)),
) -> Nil {
  process.trap_exits(True)
  let reason = {
    use started <- try(start_pool(config, 1))
    use supervisor <- try(supervisor_of(started))
    process.kill(supervisor)
    process.new_selector()
    |> process.select_trapped_exits(exit_reason)
    |> process.selector_receive(5000)
    |> map_error(fn(_timeout) { "the pool did not exit within 5 seconds" })
  }
  process.send(exits, reason)
}

fn exit_reason(exit: ExitMessage) -> ExitReason {
  exit.reason
}

// A pool under a name ---------------------------------------------------------

/// A pool under a name and a supervisor, a handle of the name, the config
/// of the pool, the subject that ends the owner of the supervisor, and the
/// supervisor.
pub type NamedPool {
  NamedPool(
    name: Name(PoolMessage(String)),
    handle: Pool(String),
    config: PoolConfig(String),
    owner: Subject(Nil),
    supervisor: Pid,
    /// The events of each pool that the supervisor starts under the name.
    pool_events: Subject(PoolEvent),
  )
}

/// Starts a supervisor of a pool of `size` connections to `server` under
/// a new name, in an owner process that is not linked to the test.
pub fn start_named_pool(
  server: Server,
  size: Int,
) -> Result(NamedPool, String) {
  use config <- try(dream_pool_config(server.port))
  let pool_events = process.new_subject()
  let name = process.new_name("pool_test_named")
  let config =
    PoolConfig(
      ..config,
      events: Some(identity_sink(pool_events)),
      attachment: "the settings of a named pool",
    )
  let started = process.new_subject()
  process.spawn_unlinked(fn() { supervise_pool(config, size, name, started) })
  use #(supervisor, owner) <- try(
    process.receive(started, 5000)
    |> map_error(fn(_timeout) { "the owner gave no supervisor in 5 seconds" })
    |> flatten,
  )
  Ok(NamedPool(
    name:,
    handle: pool.from_name(name),
    config:,
    owner:,
    supervisor:,
    pool_events:,
  ))
}

fn supervise_pool(
  config: PoolConfig(attachment),
  size: Int,
  name: Name(PoolMessage(attachment)),
  started: Subject(Result(#(Pid, Subject(Nil)), String)),
) -> Result(Nil, Nil) {
  process.trap_exits(True)
  let owner = process.new_subject()
  process.send(
    started,
    start_supervised_pool(config, size, name)
      |> result.map(fn(supervisor) { #(supervisor.pid, owner) })
      |> map_error(fn(error) {
        "could not start the supervisor: " <> inspect(error)
      }),
  )
  process.receive(owner, 60_000)
}

/// Starts a supervisor of a pool of `size` connections with `config` under
/// `name`, linked to the process that calls it.
pub fn start_supervised_pool(
  config: PoolConfig(attachment),
  size: Int,
  name: Name(PoolMessage(attachment)),
) -> Result(Started(Supervisor), actor.StartError) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool.supervised(config, size, name))
  |> static_supervisor.start
}

/// Ends the owner of the supervisor, and waits until the supervisor and
/// its pool are down. A teardown for `after_each` and for the context
/// setup.
pub fn stop_named_pool(named: NamedPool) -> Result(Nil, String) {
  let monitor = process.monitor(named.supervisor)
  process.send(named.owner, Nil)
  process.new_selector()
  |> process.select_specific_monitor(monitor, down_reason)
  |> process.selector_receive(20_000)
  |> replace(Nil)
  |> map_error(fn(_timeout) { "the supervisor did not stop in 20 seconds" })
}

/// Stops the named pool and gives `error`: for a setup that fails after it
/// started the pool. A failed stop joins the error.
pub fn stop_named_pool_after_error(named: NamedPool, error: String) -> String {
  case stop_named_pool(named) {
    Ok(Nil) -> error
    Error(stop_error) -> error <> "; " <> stop_error
  }
}

/// The context of a describe whose tests each get a pool under a name: one
/// for the tree, which gives the context its first value.
/// `start_test_named_pool` gives each test its own.
pub fn named_pool_setup(server: Server) -> Context(NamedPool) {
  context.setup(
    setup: fn() { start_named_pool(server, 1) },
    teardown: stop_named_pool,
  )
}

/// A `before_each` hook that starts a pool under a new name for the test.
pub fn start_test_named_pool(
  server: Server,
) -> fn(NamedPool) -> Result(NamedPool, String) {
  fn(_tree_named) { start_named_pool(server, 1) }
}

/// Kills the manager process of the name, and waits until it is down, so
/// the name is free.
pub fn kill_named_manager(
  name: Name(PoolMessage(attachment)),
) -> Result(Nil, String) {
  use pid <- try(
    process.named(name) |> map_error(fn(_nil) { "no process has the name" }),
  )
  kill_and_wait(pid)
}

// The processes inside a pool -------------------------------------------------

/// The supervisor of the members of the pool.
@external(erlang, "pool_test_ffi", "supervisor_of")
pub fn supervisor_of(pool: Pool(attachment)) -> Result(Pid, String)

@external(erlang, "pool_test_ffi", "members_of")
fn pool_members(pool: Pool(attachment)) -> Result(List(Pid), String)

/// Kills the first member process of the pool, and waits until it is
/// down.
pub fn kill_member(pool: Pool(attachment)) -> Result(Nil, String) {
  use members <- try(pool_members(pool))
  use member <- try(
    list.first(members) |> map_error(fn(_nil) { "the pool has no members" }),
  )
  kill_and_wait(member)
}

/// Kills the process of the connection, as a bug would.
pub fn kill_connection(connection: Connection) -> Nil {
  process.kill(pid_of(connection))
}

fn kill_and_wait(pid: Pid) -> Result(Nil, String) {
  let monitor = process.monitor(pid)
  process.kill(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, down_reason)
  |> process.selector_receive(5000)
  |> replace(Nil)
  |> map_error(fn(_timeout) { "the process did not exit within 5 seconds" })
}

fn down_reason(down: Down) -> ExitReason {
  down.reason
}

// Waiting without a sleep -----------------------------------------------------

/// Waits for the pool event `wanted`, and drops the events before it.
pub fn wait_for_pool_event(
  pool_events: Subject(PoolEvent),
  wanted: PoolEvent,
) -> Result(Nil, String) {
  case process.receive(pool_events, 5000) {
    Ok(event) if event == wanted -> Ok(Nil)
    Ok(_other) -> wait_for_pool_event(pool_events, wanted)
    Error(Nil) -> Error("no " <> inspect(wanted) <> " within 5 seconds")
  }
}

/// The next pool event.
pub fn next_pool_event(
  pool_events: Subject(PoolEvent),
) -> Result(PoolEvent, String) {
  process.receive(pool_events, 5000)
  |> map_error(fn(_timeout) { "no pool event within 5 seconds" })
}

/// Waits for the next `Disconnected` event, and drops the others.
pub fn wait_for_disconnect(
  events: Subject(ConnectionEvent),
) -> Result(Nil, String) {
  wait_for_event(events, is_disconnect, "Disconnected")
}

/// Waits for the next `ReconnectFailed` event, and drops the others.
pub fn wait_for_failed_reconnect(
  events: Subject(ConnectionEvent),
) -> Result(Nil, String) {
  wait_for_event(events, is_failed_reconnect, "ReconnectFailed")
}

/// Waits for the next `MemberFree` of `slot`, and drops the other events.
pub fn wait_for_member_free(
  pool_events: Subject(PoolEvent),
  slot: Int,
) -> Result(Nil, String) {
  case process.receive(pool_events, 5000) {
    Ok(MemberFree(free_slot)) if free_slot == slot -> Ok(Nil)
    Ok(_other) -> wait_for_member_free(pool_events, slot)
    Error(Nil) -> Error("no MemberFree within 5 seconds")
  }
}

/// Waits for the next `count` `MemberFree` events, of any slot, and drops
/// the other events.
pub fn wait_for_member_free_count(
  pool_events: Subject(PoolEvent),
  count: Int,
) -> Result(Nil, String) {
  use <- bool.guard(when: count == 0, return: Ok(Nil))
  case process.receive(pool_events, 5000) {
    Ok(MemberFree(..)) -> wait_for_member_free_count(pool_events, count - 1)
    Ok(_other) -> wait_for_member_free_count(pool_events, count)
    Error(Nil) -> Error("no MemberFree within 5 seconds")
  }
}

/// The events of the pool up to and with the next `MemberFree` of
/// `slot`, in their order.
pub fn pool_events_until_free(
  pool_events: Subject(PoolEvent),
  slot: Int,
) -> Result(List(PoolEvent), String) {
  collect_until_free(pool_events, slot, [])
}

fn collect_until_free(
  pool_events: Subject(PoolEvent),
  slot: Int,
  seen: List(PoolEvent),
) -> Result(List(PoolEvent), String) {
  case process.receive(pool_events, 5000) {
    Ok(MemberFree(free_slot)) if free_slot == slot ->
      Ok(list.reverse([MemberFree(free_slot), ..seen]))
    Ok(event) -> collect_until_free(pool_events, slot, [event, ..seen])
    Error(Nil) -> Error("no MemberFree within 5 seconds")
  }
}

/// The connection events up to and with the next `Connected`, in their
/// order.
pub fn connection_events_until_connected(
  events: Subject(ConnectionEvent),
) -> Result(List(ConnectionEvent), String) {
  collect_until_connected(events, [])
}

fn collect_until_connected(
  events: Subject(ConnectionEvent),
  seen: List(ConnectionEvent),
) -> Result(List(ConnectionEvent), String) {
  case process.receive(events, 5000) {
    Ok(Connected) -> Ok(list.reverse([Connected, ..seen]))
    Ok(event) -> collect_until_connected(events, [event, ..seen])
    Error(Nil) -> Error("no Connected within 5 seconds")
  }
}

/// The connection events up to and with the next `Disconnected`, in their
/// order.
pub fn connection_events_until_disconnected(
  events: Subject(ConnectionEvent),
) -> Result(List(ConnectionEvent), String) {
  collect_until_disconnected(events, [])
}

fn collect_until_disconnected(
  events: Subject(ConnectionEvent),
  seen: List(ConnectionEvent),
) -> Result(List(ConnectionEvent), String) {
  case process.receive(events, 5000) {
    Ok(Disconnected(error)) -> Ok(list.reverse([Disconnected(error), ..seen]))
    Ok(event) -> collect_until_disconnected(events, [event, ..seen])
    Error(Nil) -> Error("no Disconnected within 5 seconds")
  }
}

fn is_disconnect(event: ConnectionEvent) -> Bool {
  case event {
    Disconnected(..) -> True
    _other -> False
  }
}

fn is_failed_reconnect(event: ConnectionEvent) -> Bool {
  case event {
    ReconnectFailed(..) -> True
    _other -> False
  }
}

fn wait_for_event(
  events: Subject(ConnectionEvent),
  wanted: fn(ConnectionEvent) -> Bool,
  name: String,
) -> Result(Nil, String) {
  case process.receive(events, 5000) |> result.map(wanted) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> wait_for_event(events, wanted, name)
    Error(_timeout) -> Error("no " <> name <> " within 5 seconds")
  }
}

/// Waits until the last query of the backend `pid` is `wanted`, and gives
/// it. It asks the control connection again each time, at most `attempts`
/// times: no sleep.
pub fn wait_for_last_query(
  control: Connection,
  pid: String,
  wanted: String,
  attempts: Int,
) -> Result(String, String) {
  let sql = "SELECT query FROM pg_stat_activity WHERE pid = " <> pid
  case query_text(control, sql), attempts {
    Ok(query), _ if query == wanted -> Ok(query)
    Error(error), _ -> Error(error)
    Ok(query), 0 -> Error("last query " <> query)
    _query, _ -> wait_for_last_query(control, pid, wanted, attempts - 1)
  }
}
