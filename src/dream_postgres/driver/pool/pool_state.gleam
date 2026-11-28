//// The state of the pool manager: its slots, its holders, and the checkouts
//// that wait.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/pool/pool_event.{type PoolEvent}
import dream_postgres/driver/pool/pool_failure.{type HoldError}
import dream_postgres/driver/pool/pool_message.{type Lease, type PoolMessage}
import dream_postgres/driver/pool/pool_settings.{type Settings, Settings}
import dream_postgres/driver/pool_member.{type Member}
import dream_postgres/driver/sink.{type Delivery, Delivered, MapFailed}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/option.{type Option, None, Some}

/// Sends the event through the events sink, if the pool has one. A sink
/// whose map crashed is dropped: the pool sends nothing to it again.
pub fn tell(state: State(attachment), event: PoolEvent) -> State(attachment) {
  case state.settings.events {
    Some(events) -> after_delivery(state, sink.deliver(events, event))
    None -> state
  }
}

fn after_delivery(
  state: State(attachment),
  delivery: Delivery,
) -> State(attachment) {
  case delivery {
    Delivered -> state
    MapFailed ->
      State(..state, settings: Settings(..state.settings, events: None))
  }
}

/// A member process, with the manager's monitor of it.
pub type MemberProcess {
  MemberProcess(member: Member, monitor: Monitor)
}

/// Who uses the connection of a slot.
pub type Usage {
  /// No one: a checkout can take it while it is connected.
  Free
  /// The caller of the hold with this lease ID.
  HeldBy(lease_id: Int)
  /// Its member, for a rollback or a health check.
  Maintained
}

/// One place of the pool, with its running member.
pub type Slot {
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
pub type Holder {
  Holder(slot: Int, monitor: Monitor)
}

/// A checkout that waits for a free connection.
pub type Waiter {
  Waiter(
    id: Int,
    caller: Pid,
    reply: Subject(Result(Lease, HoldError)),
    timer: Timer,
  )
}

pub type Phase {
  /// The pool hands out connections.
  Serving
  /// The pool hands out nothing more. It waits for the holds that run,
  /// then closes the connections.
  Draining
}

pub type State(attachment) {
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
