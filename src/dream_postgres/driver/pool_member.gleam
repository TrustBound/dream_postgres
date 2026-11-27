//// A pool member: one gleam_otp actor that owns one connection process of a
//// pool, under the pool's supervisor.
////
//// The member starts its connection process, and starts it again with the
//// backoff of the connection settings while the start fails. It receives
//// the events of its connection, and tells its pool of each change in a
//// report. It also does the work that a pool must not do in its own
//// process, because that work waits for the server: the rollback of a
//// connection that comes back inside a transaction, and the health check
//// of an idle connection. When that work fails, the member stops the
//// connection and starts a new one, so a broken connection is replaced and
//// never handed out again.
////
//// The member traps exits. The exit of its supervisor stops the
//// connection with a Terminate, then the member. The abnormal exit of its
//// connection process makes the member start a new one. A normal exit is
//// one that the member or a caller asked for, and changes nothing by
//// itself.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type RequestFailure, ConnectFailed, Connected,
  ConnectionConfig, Disconnected, ReconnectFailed, Reconnected,
}
import dream_postgres/internal/cell.{Idle}
import gleam/erlang/process.{
  type ExitMessage, type Pid, type Subject, ExitMessage, Normal,
}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification, Transient}

// Types -----------------------------------------------------------------------

/// What a member needs, the same for each member of a pool.
pub type MemberConfig {
  MemberConfig(
    /// The settings of the connection process. Its `events` subject gets
    /// every event of each connection process of the member: a replacement
    /// starts with its own `Connected`.
    connection: ConnectionConfig,
    /// The longest time that the query of a health check may take.
    health_check_deadline_milliseconds: Int,
    /// The longest time that the reset of a returned connection may take:
    /// the wait for its last request, then again for its rollback.
    rollback_deadline_milliseconds: Int,
  )
}

/// What a member tells its pool. Each report names the member's slot: its
/// place in the pool, the same after a restart of the member.
pub type MemberReport {
  /// The member process started. It has no connection process yet.
  MemberStarted(slot: Int, member: Member)
  /// A new connection process is connected and idle, outside any
  /// transaction.
  MemberConnected(slot: Int, connection: Connection)
  /// The connection that the pool gave to a rollback or a health check is
  /// idle again, outside any transaction.
  MemberReady(slot: Int)
  /// The connection lost its session with the server, for `error`. Its
  /// process connects again.
  SessionLost(slot: Int, error: RequestFailure)
  /// The connection connected and logged in again after a loss.
  SessionBack(slot: Int)
  /// A start of a connection process, or a reconnect of the connection,
  /// failed.
  MemberConnectFailed(slot: Int, error: ConnectError)
  /// The member stopped its connection process, or the process exited.
  /// The member starts a new one.
  MemberReplacing(slot: Int)
}

/// A member process.
pub opaque type Member {
  Member(subject: Subject(Message), pid: Pid)
}

type Message {
  Connect(attempt: Int)
  Reset(connection: Connection)
  CheckHealth(connection: Connection)
  EventReceived(event: ConnectionEvent)
  ExitReceived(exit: ExitMessage)
}

type State {
  State(
    slot: Int,
    config: MemberConfig,
    reports: Subject(MemberReport),
    subject: Subject(Message),
    /// The subject that the connection process sends its events to.
    events: Subject(ConnectionEvent),
    /// The supervisor that started the member.
    parent: Pid,
    /// The connection process, while the member has one.
    connection: Option(Connection),
  )
}

/// The query of a health check.
const health_check_sql = "SELECT 1"

// Starting --------------------------------------------------------------------

/// The member of one slot, as a child of the pool's supervisor.
///
/// ## Parameters
///
/// - `slot`: the member's place in the pool
/// - `config`: the connection and the deadlines of the member's work
/// - `reports`: the pool's subject for the member's reports
///
/// ## Returns
///
/// A transient worker child: the supervisor starts it again only after an
/// abnormal exit. The supervisor's shutdown makes the member stop its
/// connection with a Terminate.
pub fn supervised(
  slot: Int,
  config: MemberConfig,
  reports: Subject(MemberReport),
) -> ChildSpecification(Member) {
  supervision.worker(fn() { start(slot, config, reports) })
  |> supervision.restart(Transient)
}

/// Starts the member. The supervisor calls it in its own process, so the
/// caller is the member's parent.
fn start(
  slot: Int,
  config: MemberConfig,
  reports: Subject(MemberReport),
) -> Result(actor.Started(Member), actor.StartError) {
  let parent = process.self()
  actor.new_with_initialiser(1000, initialise(_, slot, config, reports, parent))
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Sets the member up without waiting for the server: the first connect
/// is the member's first message.
fn initialise(
  subject: Subject(Message),
  slot: Int,
  config: MemberConfig,
  reports: Subject(MemberReport),
  parent: Pid,
) -> Result(actor.Initialised(State, Message, Member), String) {
  process.trap_exits(True)
  let events = process.new_subject()
  let member = Member(subject:, pid: process.self())
  process.send(reports, MemberStarted(slot, member))
  process.send(subject, Connect(0))
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(events, EventReceived)
    |> process.select_trapped_exits(ExitReceived)
  State(slot:, config:, reports:, subject:, events:, parent:, connection: None)
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(member)
  |> Ok
}

// Requests of the pool ----------------------------------------------------------

/// The process of the member, for the pool's monitor.
///
/// ## Parameters
///
/// - `member`: the member
///
/// ## Returns
///
/// The member's process ID.
pub fn member_pid(member: Member) -> Pid {
  member.pid
}

/// Asks the member to make a returned connection ready for reuse: a
/// connection inside a transaction gets a ROLLBACK. The member reports
/// `MemberReady`, or replaces the connection when the rollback fails.
///
/// ## Parameters
///
/// - `member`: the member
/// - `connection`: the member's connection, which no caller holds
///
/// ## Returns
///
/// `Nil` at once. The member does the work in its own process.
pub fn reset(member: Member, connection: Connection) -> Nil {
  process.send(member.subject, Reset(connection))
}

/// Asks the member to run the health check query on an idle connection.
/// The member reports `MemberReady`, or replaces the connection when the
/// query fails or passes its deadline.
///
/// ## Parameters
///
/// - `member`: the member
/// - `connection`: the member's connection, which no caller holds
///
/// ## Returns
///
/// `Nil` at once. The member does the work in its own process.
pub fn check_health(member: Member, connection: Connection) -> Nil {
  process.send(member.subject, CheckHealth(connection))
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Connect(attempt:) -> actor.continue(connect(state, attempt))
    Reset(connection:) -> actor.continue(reset_connection(state, connection))
    CheckHealth(connection:) ->
      actor.continue(check_connection(state, connection))
    EventReceived(event:) -> {
      option.map(report_of_event(state.slot, event), report(state, _))
      tell(state, event)
      actor.continue(state)
    }
    ExitReceived(exit:) -> exit_received(state, exit)
  }
}

/// Starts a connection process. A failed start is tried again after the
/// backoff of the connection settings.
fn connect(state: State, attempt: Int) -> State {
  let settings =
    ConnectionConfig(..state.config.connection, events: Some(state.events))
  case connection.start(settings) {
    Ok(started) -> {
      report(state, MemberConnected(state.slot, started))
      State(..state, connection: Some(started))
    }
    Error(error) -> {
      report(state, MemberConnectFailed(state.slot, error))
      let delay =
        connection.backoff_delay(state.config.connection.reconnect, attempt)
      process.send_after(state.subject, delay, Connect(attempt + 1))
      State(..state, connection: None)
    }
  }
}

/// A connection that is idle gets no query. One inside a transaction, or
/// one whose process is gone, gets a ROLLBACK. The status is the one after
/// every request that the connection has: a request of a caller that
/// stopped waiting still runs, and may begin a transaction.
fn reset_connection(state: State, held: Connection) -> State {
  let deadline = state.config.rollback_deadline_milliseconds
  case connection.settled_transaction_status(held, deadline) {
    Ok(Idle) -> ready(state)
    _in_transaction_or_down -> roll_back(state, held)
  }
}

fn roll_back(state: State, held: Connection) -> State {
  let deadline = state.config.rollback_deadline_milliseconds
  case connection.run_housekeeping_script(held, "ROLLBACK", deadline) {
    Ok(_outcomes) -> ready(state)
    Error(_error) -> replace(state, held)
  }
}

fn check_connection(state: State, idle: Connection) -> State {
  let deadline = state.config.health_check_deadline_milliseconds
  case connection.run_housekeeping_script(idle, health_check_sql, deadline) {
    Ok(_outcomes) -> ready(state)
    Error(_error) -> replace(state, idle)
  }
}

fn ready(state: State) -> State {
  report(state, MemberReady(state.slot))
  state
}

/// Stops the connection and starts a new one. Each process speaks only for
/// itself: the subscriber of the connection's events hears the events of
/// the stopped process, then the `Connected` of the new one, and the
/// pool hears `MemberReplacing`.
fn replace(state: State, broken: Connection) -> State {
  connection.stop(broken)
  drop_stale_events(state)
  report(state, MemberReplacing(state.slot))
  connect(state, 0)
}

/// Takes the events that the stopped connection sent before it stopped out
/// of the mailbox, so that none of them is taken for an event of the next
/// connection. The stop waits for the process's answer, and the process
/// sent each of its events before that answer, so they are all here. The
/// subscriber still gets each of them.
fn drop_stale_events(state: State) -> Nil {
  case process.receive(state.events, 0) {
    Ok(event) -> {
      tell(state, event)
      drop_stale_events(state)
    }
    Error(Nil) -> Nil
  }
}

/// The report of a connection event. The member reports a new connection
/// itself, as `MemberConnected`, once its start worked, and a member's
/// connection starts with `start`, which never sends `ConnectFailed`.
fn report_of_event(slot: Int, event: ConnectionEvent) -> Option(MemberReport) {
  case event {
    Disconnected(error:) -> Some(SessionLost(slot, error))
    ReconnectFailed(error:) -> Some(MemberConnectFailed(slot, error))
    Reconnected -> Some(SessionBack(slot))
    Connected | ConnectFailed(_error) -> None
  }
}

/// The exit of the supervisor stops the connection with a Terminate, then
/// the member. Any other exit that is not normal is the one of the
/// connection process, the only other process that the member links to.
fn exit_received(
  state: State,
  exit: ExitMessage,
) -> actor.Next(State, Message) {
  let ExitMessage(pid:, reason:) = exit
  case pid == state.parent, reason {
    True, _ -> {
      option.map(state.connection, connection.stop)
      actor.stop()
    }
    False, Normal -> actor.continue(state)
    False, _crashed -> {
      drop_stale_events(state)
      report(state, MemberReplacing(state.slot))
      actor.continue(connect(state, 0))
    }
  }
}

fn report(state: State, member_report: MemberReport) -> Nil {
  process.send(state.reports, member_report)
}

/// Gives an event to the subscriber of the connection settings, if any.
fn tell(state: State, event: ConnectionEvent) -> Nil {
  option.map(state.config.connection.events, process.send(_, event))
  Nil
}
