//// A pool of connection processes, and the holds that callers take on
//// them.
////
//// The pool is one gleam_otp actor, the manager. It starts a supervisor
//// with one member for each connection (see `driver/pool_member`). Each
//// member owns one connection process. The pool hands out connection
//// processes, never sockets: a caller holds one connection for as long as
//// its callback runs, and sends its commands to the connection process
//// itself. The manager never waits for the server.
////
//// A checkout waits in a queue, oldest first, until a connection is free
//// or its deadline passes. While no connection is connected and the last
//// connect failed, a checkout gives that connect error at once, so that a
//// wrong password or a server that is down reaches the caller.
////
//// A hold ends when the callback returns or the caller's process exits.
//// The connection then goes to its member, which rolls back an open
//// transaction, before the pool hands it out again. The members also run a
//// health check on each connection that was free and unused for a whole
//// interval; a connection that was used in the interval proved itself. A
//// connection that fails the rollback or the health check is replaced,
//// and a connection that lost its session is not handed out until it is
//// connected again.
////
//// Each pool keeps all of its state in its own processes: two pools never
//// share state, also when their settings are the same.
////
//// A pool under a supervisor runs under a process name (`supervised`). A
//// handle made from the name with `from_name` holds only the name, so it
//// stays valid when the supervisor starts the pool again. Each call looks
//// the name up and sends to the process it finds, so a call during a
//// restart gives `PoolStopped` and never crashes the caller.
////
//// A hold makes no span of its own: each statement on the held connection
//// has its span, and the OTel semantic conventions give a pool's signals
//// as metrics (`db.client.connection.count`, `.pending_requests`,
//// `.timeouts`, `.wait_time`, `.use_time`; docs/db/database-metrics.md at
//// commit 7c8eb86d04,
//// in development status), not as spans. The pool events and `status` give
//// the numbers that those metrics read.
////
//// This module starts and stops a pool. Its parts live in the modules of
//// `pool/`: the holds of a caller, the checkouts and check ins of the
//// manager, the members, and the closing of the pool.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/pool/holds.{ask}
import dream_postgres/driver/pool/message_loop.{handle_message}
import dream_postgres/driver/pool/pool_failure.{
  type StartError, PoolProcessStartFailed,
}
import dream_postgres/driver/pool/pool_message.{
  type Pool, type PoolMessage, ExitReceived, HealthCheckDue, MemberReported,
  MonitorFired, Pool, StopRequest, request_of,
}
import dream_postgres/driver/pool/pool_settings.{
  type PoolConfig, type Settings, Settings, check_health_check_interval,
  check_settings, setting_refused,
}
import dream_postgres/driver/pool/pool_state.{type State, Serving, State}
import dream_postgres/driver/pool_member.{type MemberReport, MemberConfig}
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/int.{range}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{OneForOne}
import gleam/otp/supervision.{type ChildSpecification, Transient}
import gleam/result.{map_error, try}

// Starting and stopping -------------------------------------------------------

/// Starts a pool, linked to the caller. The connections connect in the
/// background: the pool starts also while the server is down or refuses
/// the login, and a checkout then gives that connect error.
///
/// When the caller's process exits, the pool stops as `stop` does, with
/// the shutdown deadline of the settings.
///
/// ## Parameters
///
/// - `config`: the connection settings and the deadlines
/// - `size`: the number of connections, 1 or more
///
/// ## Returns
///
/// - `Ok(Pool(attachment))`: the pool runs, and its members connect
/// - `Error(StartError)`: a setting is not valid, or the manager did not
///   start
pub fn start(
  config: PoolConfig(attachment),
  size: Int,
) -> Result(Pool(attachment), StartError) {
  use Nil <- try(check_settings(config, size))
  start_manager(config, size, None)
  |> map_error(PoolProcessStartFailed)
  |> result.map(started_pool)
}

/// The pool as a child of a gleam_otp supervisor, with its manager
/// process registered under `name`. When the supervisor starts the pool
/// again, the new manager takes the name, so a handle of `from_name` stays
/// valid. The name must come from `process.new_name`, made once when the
/// program starts.
///
/// ## Parameters
///
/// - `config`: the connection settings and the deadlines
/// - `size`: the number of connections, 1 or more
/// - `name`: the name of the manager process
///
/// ## Returns
///
/// A transient worker child: the supervisor starts it again after an
/// abnormal exit, and not after `stop`. A setting that is not valid fails
/// the start with `InitFailed` and the `StartError` as text. The
/// supervisor's shutdown drains the pool as the exit of its owner does, so
/// the child has the shutdown deadline of the settings and 10 seconds more
/// to close its connections.
pub fn supervised(
  config: PoolConfig(attachment),
  size: Int,
  name: Name(PoolMessage(attachment)),
) -> ChildSpecification(Pool(attachment)) {
  supervision.worker(fn() { start_child(config, size, name) })
  |> supervision.restart(Transient)
  |> supervision.timeout(config.shutdown_deadline_milliseconds + 10_000)
}

fn start_child(
  config: PoolConfig(attachment),
  size: Int,
  name: Name(PoolMessage(attachment)),
) -> Result(actor.Started(Pool(attachment)), actor.StartError) {
  use Nil <- try(check_settings(config, size) |> map_error(setting_refused))
  start_manager(config, size, Some(name)) |> result.map(started_child)
}

/// A pool under a name that has no database, as a child of a gleam_otp
/// supervisor, for a program that runs with no database, for example
/// with recorded answers in place of the server. It is a `supervised`
/// pool of no member: it starts no connection and dials nothing, so the
/// connection settings are not used. `from_name`, `attachment`, `status`
/// and `catalog` work as for any pool: `status` shows no connection, and
/// the catalog is empty. Each `hold` gives `NoDatabase` at once and never
/// waits. The pool tells no member event, and `PoolStopping` when it
/// stops. The supervisor starts it again and shuts it down as it does a
/// pool of `supervised`.
///
/// ## Parameters
///
/// - `config`: the attachment, the events and the deadlines
/// - `name`: the name of the manager process
///
/// ## Returns
///
/// A transient worker child, with the shutdown time of `supervised`. A
/// health check interval below 1 fails the start with `InitFailed` and
/// the `StartError` as text.
pub fn supervised_without_database(
  config: PoolConfig(attachment),
  name: Name(PoolMessage(attachment)),
) -> ChildSpecification(Pool(attachment)) {
  supervision.worker(fn() { start_child_without_database(config, name) })
  |> supervision.restart(Transient)
  |> supervision.timeout(config.shutdown_deadline_milliseconds + 10_000)
}

fn start_child_without_database(
  config: PoolConfig(attachment),
  name: Name(PoolMessage(attachment)),
) -> Result(actor.Started(Pool(attachment)), actor.StartError) {
  use Nil <- try(
    check_health_check_interval(config) |> map_error(setting_refused),
  )
  start_manager_with(config, 0, Some(name), False)
  |> result.map(started_child)
}

fn started_child(
  started: actor.Started(Subject(PoolMessage(attachment))),
) -> actor.Started(Pool(attachment)) {
  actor.Started(pid: started.pid, data: started_pool(started))
}

/// The pool that runs, or will run, under a name. It makes the handle
/// from the name alone, with no call to the pool, so a handle made once
/// stays valid when the supervisor starts the pool again under the name.
///
/// ## Parameters
///
/// - `name`: the name of `supervised`
///
/// ## Returns
///
/// A handle of the pool. While no pool has the name, each call with it
/// gives `PoolStopped`.
pub fn from_name(name: Name(PoolMessage(attachment))) -> Pool(attachment) {
  Pool(subject: process.named_subject(name))
}

fn started_pool(
  started: actor.Started(Subject(PoolMessage(attachment))),
) -> Pool(attachment) {
  Pool(subject: started.data)
}

fn start_manager(
  config: PoolConfig(attachment),
  size: Int,
  name: Option(Name(PoolMessage(attachment))),
) -> Result(actor.Started(Subject(PoolMessage(attachment))), actor.StartError) {
  start_manager_with(config, size, name, True)
}

/// Starts the manager. A manager with no database has `size` 0: it starts
/// no member and dials nothing.
fn start_manager_with(
  config: PoolConfig(attachment),
  size: Int,
  name: Option(Name(PoolMessage(attachment))),
  has_database: Bool,
) -> Result(actor.Started(Subject(PoolMessage(attachment))), actor.StartError) {
  let settings =
    Settings(
      has_database:,
      size:,
      health_check_interval_milliseconds: config.health_check_interval_milliseconds,
      shutdown_deadline_milliseconds: config.shutdown_deadline_milliseconds,
      events: config.events,
      attachment: config.attachment,
    )
  let member_config =
    MemberConfig(
      connection: config.connection,
      health_check_deadline_milliseconds: config.health_check_deadline_milliseconds,
      rollback_deadline_milliseconds: config.rollback_deadline_milliseconds,
    )
  actor.new_with_initialiser(5000, initialise(_, settings, member_config))
  |> actor.on_message(handle_message)
  |> with_name(name)
  |> actor.start
}

fn with_name(
  builder: actor.Builder(
    State(attachment),
    PoolMessage(attachment),
    Subject(PoolMessage(attachment)),
  ),
  name: Option(Name(PoolMessage(attachment))),
) -> actor.Builder(
  State(attachment),
  PoolMessage(attachment),
  Subject(PoolMessage(attachment)),
) {
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
}

/// Starts the pool's catalog, linked to the manager, and the supervisor of
/// the members, with one member for each slot. The catalog starts from its
/// child specification, because its start gives the process ID that the
/// manager needs to know the catalog's exit.
fn initialise(
  subject: Subject(PoolMessage(attachment)),
  settings: Settings(attachment),
  member_config: pool_member.MemberConfig,
) -> Result(
  actor.Initialised(
    State(attachment),
    PoolMessage(attachment),
    Subject(PoolMessage(attachment)),
  ),
  String,
) {
  process.trap_exits(True)
  use catalog <- try(
    catalog.supervised(None).start()
    |> result.replace_error("the catalog did not start"),
  )
  let reports = process.new_subject()
  let supervisor =
    range(0, settings.size, static_supervisor.new(OneForOne), fn(builder, slot) {
      add_member(builder, slot, member_config, reports)
    })
    |> static_supervisor.start
  supervisor
  |> result.map(initialised(_, catalog, subject, settings, reports))
  |> result.replace_error("the supervisor of the members did not start")
}

fn add_member(
  builder: static_supervisor.Builder,
  slot: Int,
  member_config: pool_member.MemberConfig,
  reports: Subject(MemberReport),
) -> static_supervisor.Builder {
  static_supervisor.add(
    builder,
    pool_member.supervised(slot, member_config, reports),
  )
}

fn initialised(
  supervisor: actor.Started(static_supervisor.Supervisor),
  catalog: actor.Started(Catalog),
  subject: Subject(PoolMessage(attachment)),
  settings: Settings(attachment),
  reports: Subject(MemberReport),
) -> actor.Initialised(
  State(attachment),
  PoolMessage(attachment),
  Subject(PoolMessage(attachment)),
) {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_record(
      atom.create("dream_postgres_pool_request"),
      1,
      request_of,
    )
    |> process.select_map(reports, MemberReported)
    |> process.select_monitors(monitor_fired)
    |> process.select_trapped_exits(ExitReceived)
  process.send_after(
    subject,
    settings.health_check_interval_milliseconds,
    HealthCheckDue,
  )
  new_state(subject, settings, supervisor.pid, catalog)
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(subject)
}

fn new_state(
  subject: Subject(PoolMessage(attachment)),
  settings: Settings(attachment),
  supervisor: Pid,
  catalog: actor.Started(Catalog),
) -> State(attachment) {
  State(
    subject:,
    settings:,
    supervisor:,
    catalog: catalog.data,
    catalog_pid: catalog.pid,
    slots: dict.new(),
    holders: dict.new(),
    waiters: [],
    last_connect_error: None,
    next_id: 0,
    phase: Serving,
    stop_replies: [],
  )
}

fn monitor_fired(down: Down) -> PoolMessage(attachment) {
  MonitorFired(down.monitor)
}

/// Stops the pool. It hands out nothing more, and each checkout that
/// waits gets `PoolStopped`. The holds that run may finish until the
/// deadline. Then each connection sends Terminate and closes.
///
/// ## Parameters
///
/// - `pool`: the pool
/// - `deadline_milliseconds`: the longest time to wait for the holds that
///   run
///
/// ## Returns
///
/// `Nil` when every connection is closed, also when the pool is gone
/// already.
pub fn stop(pool: Pool(attachment), deadline_milliseconds: Int) -> Nil {
  ask(pool, StopRequest(deadline_milliseconds, _)) |> result.unwrap(Nil)
}
