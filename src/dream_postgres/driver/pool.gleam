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
//// `.timeouts`, `.wait_time`, `.use_time`; docs/db/database-metrics.md,
//// in development status), not as spans. The pool events and `status` give
//// the numbers that those metrics read.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig, type RequestFailure,
}
import dream_postgres/driver/pool_member.{
  type Member, type MemberReport, MemberConfig, MemberReady, MemberStarted,
  SessionBack, SessionLost,
}
import gleam/bool.{guard}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{
  type Down, type ExitMessage, type Monitor, type Name, type Pid, type Subject,
  type Timer,
}
import gleam/int.{range}
import gleam/list.{append, count, each, find, find_map, partition}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{OneForOne}
import gleam/otp/supervision.{type ChildSpecification, Transient}
import gleam/result.{map_error, try}
import gleam/string

// Types -----------------------------------------------------------------------

/// Everything a pool needs.
pub type PoolConfig(attachment) {
  PoolConfig(
    /// The settings of each connection process. The `events` subject of
    /// these settings gets every event of every connection process of the
    /// pool: a connection that replaces another starts with its own
    /// `Connected`.
    connection: ConnectionConfig,
    /// A value of the pool's user, kept by the pool process and read with
    /// `attachment`, also through a handle of the pool's name. The driver
    /// never looks inside it.
    attachment: attachment,
    /// Where the pool tells what each member does, in the order it changed
    /// its state: a hold sent after an event sees the state of that event.
    events: Option(Subject(PoolEvent)),
    /// How often the pool looks for connections to check. A connection is
    /// checked when it was free and unused for a whole interval. It must be
    /// 1 or more.
    health_check_interval_milliseconds: Int,
    /// The longest time that the query of a health check may take.
    health_check_deadline_milliseconds: Int,
    /// The longest time that the reset of a connection that comes back
    /// may take: the wait for its last request, then again for the
    /// rollback of a transaction that it left open.
    rollback_deadline_milliseconds: Int,
    /// How long the pool waits for the holds that run when its owner's
    /// process exits, before it closes the connections.
    shutdown_deadline_milliseconds: Int,
  )
}

/// What the pool tells its subscriber about its members. Each event names
/// the member's slot: its place in the pool.
pub type PoolEvent {
  /// A new connection process of the member connected and logged in.
  MemberConnected(slot: Int)
  /// The member's connection lost its session, for `error`. Its process
  /// connects again.
  MemberDisconnected(slot: Int, error: RequestFailure)
  /// The member's connection connected and logged in again after a loss.
  MemberReconnected(slot: Int)
  /// A start or a reconnect of the member's connection failed.
  MemberConnectFailed(slot: Int, error: ConnectError)
  /// The member stopped its connection process, after a failed rollback or
  /// health check, or the process exited. A new one starts.
  MemberReplacing(slot: Int)
  /// The member's connection is free for the next hold: connected, idle
  /// outside any transaction, and held by no one.
  MemberFree(slot: Int)
  /// A hold found no free connection and waits in the queue, which now has
  /// `waiting` holds.
  HoldWaiting(waiting: Int)
  /// The pool handed the member's connection to a hold.
  MemberHeld(slot: Int)
  /// The hold of the member's connection ended, and the member resets it.
  MemberReturned(slot: Int)
  /// The pool refused a hold with `error`.
  HoldRefused(error: HoldError)
  /// The pool started to stop: it refuses each new hold, and closes when
  /// the last hold ended.
  PoolStopping
}

/// Why a pool did not start.
pub type StartError {
  /// The size is below 1.
  InvalidSize(size: Int)
  /// The health check interval is below 1 millisecond.
  InvalidHealthCheckInterval(milliseconds: Int)
  /// The manager process did not start.
  PoolProcessStartFailed(error: actor.StartError)
}

/// Why a hold got no connection.
pub type HoldError {
  /// No connection was free before the deadline.
  HoldDeadlinePassed
  /// No connection is connected, and the last connect failed with this
  /// error.
  ConnectFailed(error: ConnectError)
  /// The pool stops, or it is gone.
  PoolStopped
}

/// Why a request that only reads from the pool failed: no pool process
/// runs. The pool is gone, or no pool runs under the name now, for example
/// while its supervisor starts it again.
pub type PoolNotRunning {
  PoolNotRunning
}

/// The state of a pool at one moment.
pub type PoolStatus {
  PoolStatus(
    /// The number of connections that the pool keeps.
    size: Int,
    /// The connections that have a session with the server now.
    connected: Int,
    /// The connected connections that a checkout can take now.
    available: Int,
    /// The holds that run now.
    held: Int,
    /// The checkouts that wait in the queue.
    waiting: Int,
    /// The last connect error while no connection is connected, and
    /// `None` while one is, or while no connect has failed.
    last_connect_error: Option(ConnectError),
  )
}

/// A pool: the subject of its manager process. For a pool that started
/// under a name, the subject is the name's, so a handle stays valid when a
/// supervisor starts the pool again under the same name.
pub opaque type Pool(attachment) {
  Pool(subject: Subject(PoolMessage(attachment)))
}

/// A connection that a checkout gives, with the ID of the hold and the
/// manager process that gave it.
type Lease {
  Lease(id: Int, connection: Connection, manager: Pid)
}

/// Sends a request to the manager's process (see the FFI module).
@external(erlang, "dream_postgres_pool_ffi", "deliver")
fn deliver(manager: Pid, message: PoolMessage(attachment)) -> Nil

/// The request inside a message of `deliver`.
@external(erlang, "dream_postgres_pool_ffi", "request_of")
fn request_of(message: Dynamic) -> PoolMessage(attachment)

/// A message to the manager process of a pool. A name for `start_named`
/// is a name for these messages.
pub opaque type PoolMessage(attachment) {
  CheckOut(
    caller: Pid,
    deadline_milliseconds: Int,
    reply: Subject(Result(Lease, HoldError)),
  )
  CheckIn(lease_id: Int)
  WaiterExpired(waiter_id: Int)
  StatusRequest(reply: Subject(PoolStatus))
  CatalogRequest(reply: Subject(Catalog))
  AttachmentRequest(reply: Subject(attachment))
  StopRequest(deadline_milliseconds: Int, reply: Subject(Nil))
  DrainDeadlinePassed
  HealthCheckDue
  MemberReported(report: MemberReport)
  MonitorFired(monitor: Monitor)
  ExitReceived(exit: ExitMessage)
}

/// The settings that the manager reads after it started.
type Settings(attachment) {
  Settings(
    size: Int,
    health_check_interval_milliseconds: Int,
    shutdown_deadline_milliseconds: Int,
    events: Option(Subject(PoolEvent)),
    attachment: attachment,
  )
}

/// A member process, with the manager's monitor of it.
type MemberProcess {
  MemberProcess(member: Member, monitor: Monitor)
}

/// Who uses the connection of a slot.
type Usage {
  /// No one: a checkout can take it while it is connected.
  Free
  /// The caller of the hold with this lease ID.
  HeldBy(lease_id: Int)
  /// Its member, for a rollback or a health check.
  Maintained
}

/// One place of the pool, with its running member.
type Slot {
  Slot(
    process: MemberProcess,
    /// The member's connection process, while it has one.
    connection: Option(Connection),
    /// Whether the connection has a session with the server now.
    connected: Bool,
    usage: Usage,
    /// Whether the connection connected, was handed out or came back since
    /// the last health check time. Such a connection proved itself, and
    /// the next health check time skips it.
    used_since_check: Bool,
  )
}

/// A caller that holds a connection.
type Holder {
  Holder(slot: Int, monitor: Monitor)
}

/// A checkout that waits for a free connection.
type Waiter {
  Waiter(
    id: Int,
    caller: Pid,
    reply: Subject(Result(Lease, HoldError)),
    timer: Timer,
  )
}

type Phase {
  /// The pool hands out connections.
  Serving
  /// The pool hands out nothing more. It waits for the holds that run,
  /// then closes the connections.
  Draining
}

type State(attachment) {
  State(
    subject: Subject(PoolMessage(attachment)),
    settings: Settings(attachment),
    supervisor: Pid,
    /// The pool's type catalog, and its process.
    catalog: Catalog,
    catalog_pid: Pid,
    /// The slot of each member that runs, by its place in the pool.
    slots: Dict(Int, Slot),
    /// The holds that run, by lease ID.
    holders: Dict(Int, Holder),
    /// The checkouts that wait, oldest first.
    waiters: List(Waiter),
    last_connect_error: Option(ConnectError),
    /// The next lease or waiter ID.
    next_id: Int,
    phase: Phase,
    /// The callers of `stop` that wait for the pool to close.
    stop_replies: List(Subject(Nil)),
  )
}

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

fn setting_refused(error: StartError) -> actor.StartError {
  actor.InitFailed(string.inspect(error))
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

fn check_settings(
  config: PoolConfig(attachment),
  size: Int,
) -> Result(Nil, StartError) {
  use <- guard(size < 1, Error(InvalidSize(size)))
  let interval = config.health_check_interval_milliseconds
  use <- guard(interval < 1, Error(InvalidHealthCheckInterval(interval)))
  Ok(Nil)
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
  let settings =
    Settings(
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

// Holds -----------------------------------------------------------------------

/// Holds one connection for the callback, which may send it any number of
/// commands, for example the commands of a transaction. The hold ends when
/// the callback returns, or when the caller's process exits. A transaction
/// that the callback leaves open is rolled back before the pool hands the
/// connection out again.
///
/// ## Parameters
///
/// - `pool`: the pool
/// - `deadline_milliseconds`: the longest time to wait in the queue for a
///   free connection
/// - `callback`: what to do with the connection
///
/// ## Returns
///
/// - `Ok(value)`: the value of the callback
/// - `Error(HoldDeadlinePassed)`: no connection was free before the deadline
/// - `Error(ConnectFailed(error))`: no connection is connected, and the
///   last connect failed with `error`
/// - `Error(PoolStopped)`: the pool stops, or it is gone
pub fn hold(
  pool: Pool(attachment),
  deadline_milliseconds: Int,
  callback: fn(Connection) -> value,
) -> Result(value, HoldError) {
  use lease <- result.map(check_out(pool, deadline_milliseconds))
  let value = callback(lease.connection)
  check_in_lease(lease)
  value
}

/// Ends the hold at the manager that gave the lease. When that manager is
/// gone, the message is dropped, and there is nothing to end.
fn check_in_lease(lease: Lease) -> Nil {
  deliver(lease.manager, CheckIn(lease.id))
}

fn check_out(
  pool: Pool(attachment),
  deadline_milliseconds: Int,
) -> Result(Lease, HoldError) {
  ask(pool, CheckOut(process.self(), deadline_milliseconds, _))
  |> result.map_error(stopped_hold)
  |> result.flatten
}

/// The type catalog of the pool. Each pool has its own catalog, which
/// starts empty and stops with the pool. The handle asks the manager for
/// it, because a pool that starts again under its name has a new catalog.
///
/// ## Parameters
///
/// - `pool`: the pool
///
/// ## Returns
///
/// - `Ok(Catalog)`: the catalog of the manager that runs now, for the
///   lookups of the codecs
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn catalog(pool: Pool(attachment)) -> Result(Catalog, PoolNotRunning) {
  ask(pool, CatalogRequest)
}

/// A pool that does not run refuses a hold with `PoolStopped`.
fn stopped_hold(_not_running: PoolNotRunning) -> HoldError {
  PoolStopped
}

/// The value that the pool's user attached to the pool in its settings.
/// It is read from the pool process, so a handle of a name gives the value
/// of the pool that runs under the name now: after a restart by a
/// supervisor, the one of the child spec again.
///
/// ## Parameters
///
/// - `pool`: the pool, or a handle of its name
///
/// ## Returns
///
/// - `Ok(attachment)`: the value of the pool's settings
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn attachment(
  pool: Pool(attachment),
) -> Result(attachment, PoolNotRunning) {
  ask(pool, AttachmentRequest)
}

/// The state of the pool now: its connections, its holds, its queue and
/// its last connect error.
///
/// ## Parameters
///
/// - `pool`: the pool
///
/// ## Returns
///
/// - `Ok(PoolStatus)`: the counts and the last connect error
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn status(pool: Pool(attachment)) -> Result(PoolStatus, PoolNotRunning) {
  ask(pool, StatusRequest)
}

/// Sends a request to the manager and waits for its answer. The manager
/// answers each request; a manager that is gone, or a name that no
/// manager has, gives `PoolStopped`. The request goes to the process ID
/// that the subject has now, never to the name, so a manager that exits
/// at that moment gives `PoolStopped` too, not a crash of the caller.
fn ask(
  pool: Pool(attachment),
  make: fn(Subject(reply)) -> PoolMessage(attachment),
) -> Result(reply, PoolNotRunning) {
  use manager <- try(manager_pid(pool))
  let reply_to = process.new_subject()
  let monitor = process.monitor(manager)
  deliver(manager, make(reply_to))
  let answer =
    process.new_selector()
    |> process.select_map(reply_to, Ok)
    |> process.select_specific_monitor(monitor, pool_down)
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

/// The manager process of the pool, or of its name now.
fn manager_pid(pool: Pool(attachment)) -> Result(Pid, PoolNotRunning) {
  process.subject_owner(pool.subject) |> result.replace_error(PoolNotRunning)
}

fn pool_down(_down: Down) -> Result(reply, PoolNotRunning) {
  Error(PoolNotRunning)
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State(attachment),
  message: PoolMessage(attachment),
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  case message {
    CheckOut(caller:, deadline_milliseconds:, reply:) ->
      check_out_request(state, caller, deadline_milliseconds, reply) |> next
    CheckIn(lease_id:) -> check_in(state, lease_id) |> next
    WaiterExpired(waiter_id:) -> expire(state, waiter_id) |> next
    StatusRequest(reply:) -> {
      process.send(reply, status_of(state))
      actor.continue(state)
    }
    CatalogRequest(reply:) -> {
      process.send(reply, state.catalog)
      actor.continue(state)
    }
    AttachmentRequest(reply:) -> {
      process.send(reply, state.settings.attachment)
      actor.continue(state)
    }
    StopRequest(deadline_milliseconds:, reply:) ->
      drain(state, deadline_milliseconds, [reply]) |> next
    DrainDeadlinePassed -> shut_down(state)
    HealthCheckDue -> check_health(state) |> next
    MemberReported(report:) -> after_report(state, report) |> next
    MonitorFired(monitor:) -> after_down(state, monitor) |> next
    ExitReceived(exit:) -> exit_received(state, exit)
  }
}

/// While the pool serves, it hands each free connection to the oldest
/// waiter. While it drains, it closes when the last hold ended.
fn next(
  state: State(attachment),
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  case state.phase {
    Serving -> actor.continue(settle(state))
    Draining -> drained(state)
  }
}

fn drained(
  state: State(attachment),
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  case dict.is_empty(state.holders) {
    True -> shut_down(state)
    False -> actor.continue(state)
  }
}

// Checkouts -------------------------------------------------------------------

/// Each checkout waits in the queue, with a timer for its deadline. The
/// settle after it hands it a free connection at once, if there is one.
fn check_out_request(
  state: State(attachment),
  caller: Pid,
  deadline_milliseconds: Int,
  reply: Subject(Result(Lease, HoldError)),
) -> State(attachment) {
  let id = state.next_id
  let timer =
    process.send_after(state.subject, deadline_milliseconds, WaiterExpired(id))
  let waiter = Waiter(id:, caller:, reply:, timer:)
  State(..state, waiters: append(state.waiters, [waiter]), next_id: id + 1)
  |> refuse_while_draining
  |> settle_checkout(id)
}

/// A checkout that no free connection serves at once waits, and the
/// subscriber hears how many wait.
fn settle_checkout(
  state: State(attachment),
  waiter_id: Int,
) -> State(attachment) {
  let state = settle(state)
  case list.any(state.waiters, waiter_has_id(_, waiter_id)) {
    True -> tell(state, HoldWaiting(list.length(state.waiters)))
    False -> Nil
  }
  state
}

/// A pool that drains refuses each checkout at once.
fn refuse_while_draining(state: State(attachment)) -> State(attachment) {
  case state.phase {
    Serving -> state
    Draining -> refuse_waiters(state, PoolStopped)
  }
}

fn expire(state: State(attachment), waiter_id: Int) -> State(attachment) {
  let #(expired, others) = partition(state.waiters, waiter_has_id(_, waiter_id))
  each(expired, refuse_waiter(state, _, HoldDeadlinePassed))
  State(..state, waiters: others)
}

fn waiter_has_id(waiter: Waiter, id: Int) -> Bool {
  waiter.id == id
}

fn refuse_waiters(
  state: State(attachment),
  error: HoldError,
) -> State(attachment) {
  each(state.waiters, refuse_waiter(state, _, error))
  State(..state, waiters: [])
}

fn refuse_waiter(
  state: State(attachment),
  waiter: Waiter,
  error: HoldError,
) -> Nil {
  process.cancel_timer(waiter.timer)
  process.send(waiter.reply, Error(error))
  tell(state, HoldRefused(error))
}

/// Hands free connections to the waiters, oldest first. When none is
/// connected and the last connect failed, every waiter gets that error.
fn settle(state: State(attachment)) -> State(attachment) {
  let state = serve(state)
  case unreachable_error(state) {
    Some(error) -> refuse_waiters(state, ConnectFailed(error))
    None -> state
  }
}

fn serve(state: State(attachment)) -> State(attachment) {
  case state.waiters, find_map(dict.to_list(state.slots), free_entry) {
    [oldest, ..others], Ok(#(slot_id, slot, connection)) ->
      State(..state, waiters: others)
      |> hand_out(oldest, slot_id, slot, connection)
      |> serve
    _, _ -> state
  }
}

fn free_entry(entry: #(Int, Slot)) -> Result(#(Int, Slot, Connection), Nil) {
  let #(slot_id, slot) = entry
  free_connection(slot) |> result.map(with_place(slot_id, slot, _))
}

fn with_place(
  slot_id: Int,
  slot: Slot,
  connection: Connection,
) -> #(Int, Slot, Connection) {
  #(slot_id, slot, connection)
}

/// The connection of a slot that a checkout can take: connected, and
/// used by no one.
fn free_connection(slot: Slot) -> Result(Connection, Nil) {
  case slot {
    Slot(connection: Some(connection), connected: True, usage: Free, ..) ->
      Ok(connection)
    _ -> Error(Nil)
  }
}

fn is_free(slot: Slot) -> Bool {
  free_connection(slot) |> result.is_ok
}

fn is_connected(slot: Slot) -> Bool {
  slot.connected
}

/// Gives the slot's connection to the waiter. The pool monitors the
/// caller, so the hold ends also when the caller exits.
fn hand_out(
  state: State(attachment),
  waiter: Waiter,
  slot_id: Int,
  slot: Slot,
  connection: Connection,
) -> State(attachment) {
  process.cancel_timer(waiter.timer)
  let lease_id = state.next_id
  let holder = Holder(slot: slot_id, monitor: process.monitor(waiter.caller))
  process.send(waiter.reply, Ok(Lease(lease_id, connection, process.self())))
  let held = Slot(..slot, usage: HeldBy(lease_id), used_since_check: True)
  let state =
    State(
      ..state,
      slots: dict.insert(state.slots, slot_id, held),
      holders: dict.insert(state.holders, lease_id, holder),
      next_id: lease_id + 1,
    )
  tell(state, MemberHeld(slot_id))
  state
}

/// The last connect error, while no connection is connected.
fn unreachable_error(state: State(attachment)) -> Option(ConnectError) {
  case count(dict.values(state.slots), is_connected) {
    0 -> state.last_connect_error
    _connected -> None
  }
}

fn status_of(state: State(attachment)) -> PoolStatus {
  let slots = dict.values(state.slots)
  PoolStatus(
    size: state.settings.size,
    connected: count(slots, is_connected),
    available: count(slots, is_free),
    held: dict.size(state.holders),
    waiting: list.length(state.waiters),
    last_connect_error: unreachable_error(state),
  )
}

// Check-ins -------------------------------------------------------------------

/// Ends a hold. The connection goes to its member for a reset, unless the
/// member replaced it during the hold.
fn check_in(state: State(attachment), lease_id: Int) -> State(attachment) {
  dict.get(state.holders, lease_id)
  |> result.map(release(state, lease_id, _))
  |> result.unwrap(state)
}

fn release(
  state: State(attachment),
  lease_id: Int,
  holder: Holder,
) -> State(attachment) {
  process.demonitor_process(holder.monitor)
  let holders = dict.delete(state.holders, lease_id)
  let state =
    State(..state, holders:)
    |> update_slot(holder.slot, returned(_, lease_id))
  tell(state, MemberReturned(holder.slot))
  state
}

fn returned(slot: Slot, lease_id: Int) -> Slot {
  case slot {
    Slot(usage: HeldBy(holding), connection: Some(connection), ..)
      if holding == lease_id
    -> {
      pool_member.reset(slot.process.member, connection)
      Slot(..slot, usage: Maintained, used_since_check: True)
    }
    _replaced -> slot
  }
}

/// A monitor of a holder ends its hold. A monitor of a member removes
/// its slot until the supervisor starts the member again.
fn after_down(state: State(attachment), monitor: Monitor) -> State(attachment) {
  case find(dict.to_list(state.holders), holder_has_monitor(_, monitor)) {
    Ok(#(lease_id, holder)) -> release(state, lease_id, holder)
    Error(Nil) ->
      State(
        ..state,
        slots: dict.filter(state.slots, fn(_slot_id, slot) {
          member_has_other_monitor(slot, monitor)
        }),
      )
  }
}

fn holder_has_monitor(entry: #(Int, Holder), monitor: Monitor) -> Bool {
  let #(_lease_id, holder) = entry
  holder.monitor == monitor
}

fn member_has_other_monitor(slot: Slot, monitor: Monitor) -> Bool {
  slot.process.monitor != monitor
}

// Members ---------------------------------------------------------------------

/// Changes the state for the report, then tells the subscriber the event
/// of the report, and `MemberFree` when the report freed the member's
/// connection.
fn after_report(
  state: State(attachment),
  report: MemberReport,
) -> State(attachment) {
  let changed = state_after_report(state, report)
  let slot_id = report_slot(report)
  option.map(event_of_report(report), tell(changed, _))
  case slot_is_free(state, slot_id), slot_is_free(changed, slot_id) {
    False, True -> tell(changed, MemberFree(slot_id))
    _before, _after -> Nil
  }
  changed
}

fn tell(state: State(attachment), event: PoolEvent) -> Nil {
  option.map(state.settings.events, process.send(_, event))
  Nil
}

fn slot_is_free(state: State(attachment), slot_id: Int) -> Bool {
  dict.get(state.slots, slot_id) |> result.map(is_free) |> result.unwrap(False)
}

fn report_slot(report: MemberReport) -> Int {
  report.slot
}

fn event_of_report(report: MemberReport) -> Option(PoolEvent) {
  case report {
    pool_member.MemberConnected(slot:, ..) -> Some(MemberConnected(slot))
    SessionLost(slot:, error:) -> Some(MemberDisconnected(slot, error))
    SessionBack(slot:) -> Some(MemberReconnected(slot))
    pool_member.MemberConnectFailed(slot:, error:) ->
      Some(MemberConnectFailed(slot, error))
    pool_member.MemberReplacing(slot:) -> Some(MemberReplacing(slot))
    MemberStarted(..) | MemberReady(..) -> None
  }
}

fn state_after_report(
  state: State(attachment),
  report: MemberReport,
) -> State(attachment) {
  case report {
    MemberStarted(slot:, member:) -> member_started(state, slot, member)
    pool_member.MemberConnected(slot:, connection:) ->
      State(..state, last_connect_error: None)
      |> update_slot(slot, connected(_, connection))
    MemberReady(slot:) -> update_slot(state, slot, with_usage(_, Free))
    SessionLost(slot:, ..) -> update_slot(state, slot, with_connected(_, False))
    SessionBack(slot:) ->
      State(..state, last_connect_error: None)
      |> update_slot(slot, with_connected(_, True))
    pool_member.MemberConnectFailed(error:, ..) ->
      State(..state, last_connect_error: Some(error))
    pool_member.MemberReplacing(slot:) ->
      update_slot(state, slot, without_connection)
  }
}

fn member_started(
  state: State(attachment),
  slot_id: Int,
  member: Member,
) -> State(attachment) {
  let monitor = process.monitor(pool_member.member_pid(member))
  let slot =
    Slot(
      process: MemberProcess(member:, monitor:),
      connection: None,
      connected: False,
      usage: Free,
      used_since_check: False,
    )
  State(..state, slots: dict.insert(state.slots, slot_id, slot))
}

fn connected(slot: Slot, connection: Connection) -> Slot {
  Slot(
    ..slot,
    connection: Some(connection),
    connected: True,
    usage: Free,
    used_since_check: True,
  )
}

fn with_usage(slot: Slot, usage: Usage) -> Slot {
  Slot(..slot, usage:)
}

fn with_connected(slot: Slot, connected: Bool) -> Slot {
  Slot(..slot, connected:)
}

fn without_connection(slot: Slot) -> Slot {
  Slot(..slot, connection: None, connected: False)
}

/// Changes the slot of a member that runs. A member's reports all come
/// before the monitor of its exit, so the slot is there.
fn update_slot(
  state: State(attachment),
  slot_id: Int,
  change: fn(Slot) -> Slot,
) -> State(attachment) {
  dict.get(state.slots, slot_id)
  |> result.map(change)
  |> result.map(dict.insert(state.slots, slot_id, _))
  |> result.map(with_slots(state, _))
  |> result.unwrap(state)
}

fn with_slots(
  state: State(attachment),
  slots: Dict(Int, Slot),
) -> State(attachment) {
  State(..state, slots:)
}

/// Gives each connection that was free and unused for a whole interval to
/// its member for a health check, and sets the timer for the next one. A
/// connection that was used in the interval proved itself: it waits for
/// the next interval.
fn check_health(state: State(attachment)) -> State(attachment) {
  process.send_after(
    state.subject,
    state.settings.health_check_interval_milliseconds,
    HealthCheckDue,
  )
  State(..state, slots: dict.map_values(state.slots, health_checked))
}

fn health_checked(_slot_id: Int, slot: Slot) -> Slot {
  case free_connection(slot), slot.used_since_check {
    Ok(connection), False -> {
      pool_member.check_health(slot.process.member, connection)
      Slot(..slot, usage: Maintained)
    }
    _busy_or_used, _ -> Slot(..slot, used_since_check: False)
  }
}

// Draining and closing --------------------------------------------------------

/// Starts to drain, or goes on: each waiter gets `PoolStopped`, and the
/// pool closes when the last hold ended, or at the deadline. A second stop
/// keeps the earlier deadline when it is shorter.
fn drain(
  state: State(attachment),
  deadline_milliseconds: Int,
  replies: List(Subject(Nil)),
) -> State(attachment) {
  process.send_after(state.subject, deadline_milliseconds, DrainDeadlinePassed)
  let first_stop = state.phase == Serving
  guard(when: !first_stop, return: Nil, otherwise: fn() {
    tell(state, PoolStopping)
  })
  State(
    ..state,
    phase: Draining,
    stop_replies: append(replies, state.stop_replies),
  )
  |> refuse_waiters(PoolStopped)
}

/// The exit of the members' supervisor or of the catalog ends the pool
/// with an error. Any other exit is the one of the pool's owner, and the
/// pool drains and closes.
fn exit_received(
  state: State(attachment),
  exit: ExitMessage,
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  case exit.pid == state.supervisor || exit.pid == state.catalog_pid {
    True -> stop_with_error("a process of the pool stopped")
    False ->
      drain(state, state.settings.shutdown_deadline_milliseconds, []) |> next
  }
}

/// Stops the manager with an exit reason that is not normal. The manager
/// traps exits, so the exit signal that `stop_abnormal` sends to its own
/// process would only be a message: the manager stops trapping first.
fn stop_with_error(
  reason: String,
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  process.trap_exits(False)
  actor.stop_abnormal(reason)
}

/// Shuts the members' supervisor down, which makes each member send
/// Terminate on its connection, and waits until it is down. Then the
/// catalog stops, and each caller of `stop` gets its answer.
fn shut_down(
  state: State(attachment),
) -> actor.Next(State(attachment), PoolMessage(attachment)) {
  let monitor = process.monitor(state.supervisor)
  process.send_abnormal_exit(state.supervisor, atom.create("shutdown"))
  process.new_selector()
  |> process.select_specific_monitor(monitor, ignore_down)
  |> process.selector_receive_forever
  catalog.stop(state.catalog)
  each(state.stop_replies, process.send(_, Nil))
  actor.stop()
}

fn ignore_down(_down: Down) -> Nil {
  Nil
}
