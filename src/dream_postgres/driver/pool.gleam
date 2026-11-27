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
//// health check on each idle connection at each interval. A connection that
//// fails the rollback or the health check is replaced, and a connection
//// that lost its session is not handed out until it is connected again.
////
//// Each pool keeps all of its state in its own processes: two pools never
//// share state, also when their settings are the same.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
}
import dream_postgres/driver/pool_member.{
  type Member, type MemberReport, MemberConfig, MemberConnectFailed,
  MemberConnected, MemberReady, MemberReplacing, MemberStarted, SessionBack,
  SessionLost,
}
import gleam/bool.{guard}
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{
  type Down, type ExitMessage, type Monitor, type Pid, type Subject, type Timer,
}
import gleam/int.{range}
import gleam/list.{append, count, each, find, find_map, partition}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{OneForOne}
import gleam/result.{map_error, try}

// Types -----------------------------------------------------------------------

/// Everything a pool needs.
pub type PoolConfig(extra) {
  PoolConfig(
    /// The settings of each connection process. The pool gives its own
    /// subject to each process; the `events` subject of these settings gets
    /// every event of every connection of the pool, and a `Disconnected`
    /// for each connection that the pool replaces.
    connection: ConnectionConfig,
    /// How often the pool runs a health check on each idle connection.
    /// It must be 1 or more.
    health_check_interval_milliseconds: Int,
    /// The longest time that the query of a health check may take.
    health_check_deadline_milliseconds: Int,
    /// The longest time that the rollback of a connection that comes back
    /// inside a transaction may take.
    rollback_deadline_milliseconds: Int,
    /// How long the pool waits for the holds that run when its owner's
    /// process exits, before it closes the connections.
    shutdown_deadline_milliseconds: Int,
    /// Any value that goes with the pool, for the code that uses it. The
    /// pool does not read it.
    extra: extra,
  )
}

/// Why a pool did not start.
pub type StartError {
  /// The size is below 1.
  InvalidSize(size: Int)
  /// The health check interval is below 1 millisecond.
  InvalidHealthCheckInterval(milliseconds: Int)
  /// The manager process did not start.
  ManagerStartFailed(error: actor.StartError)
}

/// Why a checkout gave no connection.
pub type CheckoutError {
  /// No connection was free before the deadline.
  CheckoutTimedOut
  /// No connection is connected, and the last connect failed with this
  /// error.
  ConnectFailed(error: ConnectError)
  /// The pool stops, or it is gone.
  PoolStopped
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

/// A pool, with the extra value of its settings.
pub opaque type Pool(extra) {
  Pool(subject: Subject(Message), pid: Pid, extra: extra)
}

/// The manager process, before the extra value goes with it.
type Manager {
  Manager(subject: Subject(Message), pid: Pid)
}

/// A connection that a checkout gives, with the ID of the hold.
type Lease {
  Lease(id: Int, connection: Connection)
}

type Message {
  CheckOut(
    caller: Pid,
    deadline_milliseconds: Int,
    reply: Subject(Result(Lease, CheckoutError)),
  )
  CheckIn(lease_id: Int)
  WaiterExpired(waiter_id: Int)
  StatusRequest(reply: Subject(PoolStatus))
  StopRequest(deadline_milliseconds: Int, reply: Subject(Nil))
  DrainDeadlinePassed
  HealthCheckDue
  MemberReported(report: MemberReport)
  MonitorFired(monitor: Monitor)
  ExitReceived(exit: ExitMessage)
}

/// The settings that the manager reads after it started.
type Settings {
  Settings(
    size: Int,
    health_check_interval_milliseconds: Int,
    shutdown_deadline_milliseconds: Int,
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
    reply: Subject(Result(Lease, CheckoutError)),
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

type State {
  State(
    subject: Subject(Message),
    settings: Settings,
    supervisor: Pid,
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
/// - `config`: the connection settings, the deadlines and the extra value
/// - `size`: the number of connections, 1 or more
///
/// ## Returns
///
/// - `Ok(Pool)`: the pool runs, and its members connect
/// - `Error(StartError)`: a setting is not valid, or the manager did not
///   start
pub fn start(
  config: PoolConfig(extra),
  size: Int,
) -> Result(Pool(extra), StartError) {
  use <- guard(size < 1, Error(InvalidSize(size)))
  let interval = config.health_check_interval_milliseconds
  use <- guard(interval < 1, Error(InvalidHealthCheckInterval(interval)))
  use started <- try(start_manager(config, size))
  let Manager(subject:, pid:) = started.data
  Ok(Pool(subject:, pid:, extra: config.extra))
}

fn start_manager(
  config: PoolConfig(extra),
  size: Int,
) -> Result(actor.Started(Manager), StartError) {
  let settings =
    Settings(
      size:,
      health_check_interval_milliseconds: config.health_check_interval_milliseconds,
      shutdown_deadline_milliseconds: config.shutdown_deadline_milliseconds,
    )
  let member_config =
    MemberConfig(
      connection: config.connection,
      health_check_deadline_milliseconds: config.health_check_deadline_milliseconds,
      rollback_deadline_milliseconds: config.rollback_deadline_milliseconds,
    )
  actor.new_with_initialiser(5000, initialise(_, settings, member_config))
  |> actor.on_message(handle_message)
  |> actor.start
  |> map_error(ManagerStartFailed)
}

/// Starts the supervisor of the members, with one member for each slot.
fn initialise(
  subject: Subject(Message),
  settings: Settings,
  member_config: pool_member.MemberConfig,
) -> Result(actor.Initialised(State, Message, Manager), String) {
  process.trap_exits(True)
  let reports = process.new_subject()
  let supervisor =
    range(0, settings.size, static_supervisor.new(OneForOne), fn(builder, slot) {
      add_member(builder, slot, member_config, reports)
    })
    |> static_supervisor.start
  supervisor
  |> result.map(initialised(_, subject, settings, reports))
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
  subject: Subject(Message),
  settings: Settings,
  reports: Subject(MemberReport),
) -> actor.Initialised(State, Message, Manager) {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(reports, MemberReported)
    |> process.select_monitors(monitor_fired)
    |> process.select_trapped_exits(ExitReceived)
  process.send_after(
    subject,
    settings.health_check_interval_milliseconds,
    HealthCheckDue,
  )
  new_state(subject, settings, supervisor.pid)
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(Manager(subject:, pid: process.self()))
}

fn new_state(
  subject: Subject(Message),
  settings: Settings,
  supervisor: Pid,
) -> State {
  State(
    subject:,
    settings:,
    supervisor:,
    slots: dict.new(),
    holders: dict.new(),
    waiters: [],
    last_connect_error: None,
    next_id: 0,
    phase: Serving,
    stop_replies: [],
  )
}

fn monitor_fired(down: Down) -> Message {
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
pub fn stop(pool: Pool(extra), deadline_milliseconds: Int) -> Nil {
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
/// - `Error(CheckoutTimedOut)`: no connection was free before the deadline
/// - `Error(ConnectFailed(error))`: no connection is connected, and the
///   last connect failed with `error`
/// - `Error(PoolStopped)`: the pool stops, or it is gone
pub fn hold(
  pool: Pool(extra),
  deadline_milliseconds: Int,
  callback: fn(Connection) -> value,
) -> Result(value, CheckoutError) {
  use lease <- result.map(check_out(pool, deadline_milliseconds))
  let value = callback(lease.connection)
  process.send(pool.subject, CheckIn(lease.id))
  value
}

fn check_out(
  pool: Pool(extra),
  deadline_milliseconds: Int,
) -> Result(Lease, CheckoutError) {
  ask(pool, CheckOut(process.self(), deadline_milliseconds, _))
  |> result.flatten
}

/// The extra value of the pool's settings.
///
/// ## Parameters
///
/// - `pool`: the pool
///
/// ## Returns
///
/// The `extra` of the `PoolConfig` that started the pool.
pub fn extra(pool: Pool(extra)) -> extra {
  pool.extra
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
/// - `Error(PoolStopped)`: the pool is gone
pub fn status(pool: Pool(extra)) -> Result(PoolStatus, CheckoutError) {
  ask(pool, StatusRequest)
}

/// Sends a request to the manager and waits for its answer. The manager
/// answers each request; a manager that is gone gives `PoolStopped`.
fn ask(
  pool: Pool(extra),
  make: fn(Subject(reply)) -> Message,
) -> Result(reply, CheckoutError) {
  let reply_to = process.new_subject()
  let monitor = process.monitor(pool.pid)
  process.send(pool.subject, make(reply_to))
  let answer =
    process.new_selector()
    |> process.select_map(reply_to, Ok)
    |> process.select_specific_monitor(monitor, pool_down)
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

fn pool_down(_down: Down) -> Result(reply, CheckoutError) {
  Error(PoolStopped)
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    CheckOut(caller:, deadline_milliseconds:, reply:) ->
      check_out_request(state, caller, deadline_milliseconds, reply) |> next
    CheckIn(lease_id:) -> check_in(state, lease_id) |> next
    WaiterExpired(waiter_id:) -> expire(state, waiter_id) |> next
    StatusRequest(reply:) -> {
      process.send(reply, status_of(state))
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
fn next(state: State) -> actor.Next(State, Message) {
  case state.phase {
    Serving -> actor.continue(settle(state))
    Draining -> drained(state)
  }
}

fn drained(state: State) -> actor.Next(State, Message) {
  case dict.is_empty(state.holders) {
    True -> shut_down(state)
    False -> actor.continue(state)
  }
}

// Checkouts -------------------------------------------------------------------

/// Each checkout waits in the queue, with a timer for its deadline. The
/// settle after it hands it a free connection at once, if there is one.
fn check_out_request(
  state: State,
  caller: Pid,
  deadline_milliseconds: Int,
  reply: Subject(Result(Lease, CheckoutError)),
) -> State {
  let id = state.next_id
  let timer =
    process.send_after(state.subject, deadline_milliseconds, WaiterExpired(id))
  let waiter = Waiter(id:, caller:, reply:, timer:)
  State(..state, waiters: append(state.waiters, [waiter]), next_id: id + 1)
  |> refuse_while_draining
}

/// A pool that drains refuses each checkout at once.
fn refuse_while_draining(state: State) -> State {
  case state.phase {
    Serving -> state
    Draining -> refuse_waiters(state, PoolStopped)
  }
}

fn expire(state: State, waiter_id: Int) -> State {
  let #(expired, others) = partition(state.waiters, waiter_has_id(_, waiter_id))
  each(expired, refuse_waiter(_, CheckoutTimedOut))
  State(..state, waiters: others)
}

fn waiter_has_id(waiter: Waiter, id: Int) -> Bool {
  waiter.id == id
}

fn refuse_waiters(state: State, error: CheckoutError) -> State {
  each(state.waiters, refuse_waiter(_, error))
  State(..state, waiters: [])
}

fn refuse_waiter(waiter: Waiter, error: CheckoutError) -> Nil {
  process.cancel_timer(waiter.timer)
  process.send(waiter.reply, Error(error))
}

/// Hands free connections to the waiters, oldest first. When none is
/// connected and the last connect failed, every waiter gets that error.
fn settle(state: State) -> State {
  let state = serve(state)
  case unreachable_error(state) {
    Some(error) -> refuse_waiters(state, ConnectFailed(error))
    None -> state
  }
}

fn serve(state: State) -> State {
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
  state: State,
  waiter: Waiter,
  slot_id: Int,
  slot: Slot,
  connection: Connection,
) -> State {
  process.cancel_timer(waiter.timer)
  let lease_id = state.next_id
  let holder = Holder(slot: slot_id, monitor: process.monitor(waiter.caller))
  process.send(waiter.reply, Ok(Lease(lease_id, connection)))
  let held = Slot(..slot, usage: HeldBy(lease_id))
  State(
    ..state,
    slots: dict.insert(state.slots, slot_id, held),
    holders: dict.insert(state.holders, lease_id, holder),
    next_id: lease_id + 1,
  )
}

/// The last connect error, while no connection is connected.
fn unreachable_error(state: State) -> Option(ConnectError) {
  case count(dict.values(state.slots), is_connected) {
    0 -> state.last_connect_error
    _connected -> None
  }
}

fn status_of(state: State) -> PoolStatus {
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
fn check_in(state: State, lease_id: Int) -> State {
  dict.get(state.holders, lease_id)
  |> result.map(release(state, lease_id, _))
  |> result.unwrap(state)
}

fn release(state: State, lease_id: Int, holder: Holder) -> State {
  process.demonitor_process(holder.monitor)
  let holders = dict.delete(state.holders, lease_id)
  State(..state, holders:)
  |> update_slot(holder.slot, returned(_, lease_id))
}

fn returned(slot: Slot, lease_id: Int) -> Slot {
  case slot {
    Slot(usage: HeldBy(holding), connection: Some(connection), ..)
      if holding == lease_id
    -> {
      pool_member.reset(slot.process.member, connection)
      Slot(..slot, usage: Maintained)
    }
    _replaced -> slot
  }
}

/// A monitor of a holder ends its hold. A monitor of a member removes
/// its slot until the supervisor starts the member again.
fn after_down(state: State, monitor: Monitor) -> State {
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

fn after_report(state: State, report: MemberReport) -> State {
  case report {
    MemberStarted(slot:, member:) -> member_started(state, slot, member)
    MemberConnected(slot:, connection:) ->
      State(..state, last_connect_error: None)
      |> update_slot(slot, connected(_, connection))
    MemberReady(slot:) -> update_slot(state, slot, with_usage(_, Free))
    SessionLost(slot:) -> update_slot(state, slot, with_connected(_, False))
    SessionBack(slot:) ->
      State(..state, last_connect_error: None)
      |> update_slot(slot, with_connected(_, True))
    MemberConnectFailed(error:, ..) ->
      State(..state, last_connect_error: Some(error))
    MemberReplacing(slot:) -> update_slot(state, slot, without_connection)
  }
}

fn member_started(state: State, slot_id: Int, member: Member) -> State {
  let monitor = process.monitor(pool_member.member_pid(member))
  let slot =
    Slot(
      process: MemberProcess(member:, monitor:),
      connection: None,
      connected: False,
      usage: Free,
    )
  State(..state, slots: dict.insert(state.slots, slot_id, slot))
}

fn connected(slot: Slot, connection: Connection) -> Slot {
  Slot(..slot, connection: Some(connection), connected: True, usage: Free)
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
fn update_slot(state: State, slot_id: Int, change: fn(Slot) -> Slot) -> State {
  dict.get(state.slots, slot_id)
  |> result.map(change)
  |> result.map(dict.insert(state.slots, slot_id, _))
  |> result.map(with_slots(state, _))
  |> result.unwrap(state)
}

fn with_slots(state: State, slots: Dict(Int, Slot)) -> State {
  State(..state, slots:)
}

/// Gives each free, connected connection to its member for a health
/// check, and sets the timer for the next one.
fn check_health(state: State) -> State {
  process.send_after(
    state.subject,
    state.settings.health_check_interval_milliseconds,
    HealthCheckDue,
  )
  State(..state, slots: dict.map_values(state.slots, health_checked))
}

fn health_checked(_slot_id: Int, slot: Slot) -> Slot {
  case free_connection(slot) {
    Ok(connection) -> {
      pool_member.check_health(slot.process.member, connection)
      Slot(..slot, usage: Maintained)
    }
    Error(Nil) -> slot
  }
}

// Draining and closing --------------------------------------------------------

/// Starts to drain, or goes on: each waiter gets `PoolStopped`, and the
/// pool closes when the last hold ended, or at the deadline. A second stop
/// keeps the earlier deadline when it is shorter.
fn drain(
  state: State,
  deadline_milliseconds: Int,
  replies: List(Subject(Nil)),
) -> State {
  process.send_after(state.subject, deadline_milliseconds, DrainDeadlinePassed)
  State(
    ..state,
    phase: Draining,
    stop_replies: append(replies, state.stop_replies),
  )
  |> refuse_waiters(PoolStopped)
}

/// The exit of the members' supervisor ends the pool with an error. Any
/// other exit is the one of the pool's owner, and the pool drains and
/// closes.
fn exit_received(
  state: State,
  exit: ExitMessage,
) -> actor.Next(State, Message) {
  case exit.pid == state.supervisor {
    True -> stop_with_error("the supervisor of the members stopped")
    False ->
      drain(state, state.settings.shutdown_deadline_milliseconds, []) |> next
  }
}

/// Stops the manager with an exit reason that is not normal. The manager
/// traps exits, so the exit signal that `stop_abnormal` sends to its own
/// process would only be a message: the manager stops trapping first.
fn stop_with_error(reason: String) -> actor.Next(State, Message) {
  process.trap_exits(False)
  actor.stop_abnormal(reason)
}

/// Shuts the members' supervisor down, which makes each member send
/// Terminate on its connection, and waits until it is down. Then each
/// caller of `stop` gets its answer.
fn shut_down(state: State) -> actor.Next(State, Message) {
  let monitor = process.monitor(state.supervisor)
  process.send_abnormal_exit(state.supervisor, atom.create("shutdown"))
  process.new_selector()
  |> process.select_specific_monitor(monitor, ignore_down)
  |> process.selector_receive_forever
  each(state.stop_replies, process.send(_, Nil))
  actor.stop()
}

fn ignore_down(_down: Down) -> Nil {
  Nil
}
