//// A checkout in the manager: it is served, queued, refused, or expired.

import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/pool/pool_event.{
  HoldRefused, HoldWaiting, MemberHeld,
}
import dream_postgres/driver/pool/pool_failure.{
  type HoldError, ConnectFailed, HoldDeadlinePassed, NoDatabase, PoolStopped,
}
import dream_postgres/driver/pool/pool_message.{type Lease, Lease, WaiterExpired}
import dream_postgres/driver/pool/pool_state.{
  type Slot, type State, type Waiter, Draining, Free, HeldBy, Holder, Serving,
  Slot, State, Waiter, tell,
}
import dream_postgres/driver/pool/pool_status.{type PoolStatus, PoolStatus}
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list.{append, count, find_map, fold, partition}
import gleam/option.{type Option, None, Some}
import gleam/result

/// Each checkout waits in the queue, with a timer for its deadline. The
/// settle after it hands it a free connection at once, if there is one.
pub fn check_out_request(
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
  |> refuse_without_database
  |> settle_checkout(id)
}

/// A pool with no database refuses each hold at once.
fn refuse_without_database(state: State(attachment)) -> State(attachment) {
  case state.settings.has_database {
    True -> state
    False -> refuse_waiters(state, NoDatabase)
  }
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
    False -> state
  }
}

/// A pool that drains refuses each checkout at once.
fn refuse_while_draining(state: State(attachment)) -> State(attachment) {
  case state.phase {
    Serving -> state
    Draining -> refuse_waiters(state, PoolStopped)
  }
}

pub fn expire(state: State(attachment), waiter_id: Int) -> State(attachment) {
  let #(expired, others) = partition(state.waiters, waiter_has_id(_, waiter_id))
  let state = fold(expired, state, refuse_waiter(HoldDeadlinePassed))
  State(..state, waiters: others)
}

fn waiter_has_id(waiter: Waiter, id: Int) -> Bool {
  waiter.id == id
}

pub fn refuse_waiters(
  state: State(attachment),
  error: HoldError,
) -> State(attachment) {
  let state = fold(state.waiters, state, refuse_waiter(error))
  State(..state, waiters: [])
}

/// A step of a fold over waiters: each one gets the error, and the
/// subscriber hears of each refusal.
fn refuse_waiter(
  error: HoldError,
) -> fn(State(attachment), Waiter) -> State(attachment) {
  fn(state: State(attachment), waiter: Waiter) {
    process.cancel_timer(waiter.timer)
    process.send(waiter.reply, Error(error))
    tell(state, HoldRefused(error))
  }
}

/// Hands free connections to the waiters, oldest first. When none is
/// connected and the last connect failed, every waiter gets that error.
pub fn settle(state: State(attachment)) -> State(attachment) {
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
pub fn free_connection(slot: Slot) -> Result(Connection, Nil) {
  case slot {
    Slot(connection: Some(connection), connected: True, usage: Free, ..) ->
      Ok(connection)
    _ -> Error(Nil)
  }
}

pub fn is_free(slot: Slot) -> Bool {
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
}

/// The last connect error, while no connection is connected.
fn unreachable_error(state: State(attachment)) -> Option(ConnectError) {
  case count(dict.values(state.slots), is_connected) {
    0 -> state.last_connect_error
    _connected -> None
  }
}

pub fn status_of(state: State(attachment)) -> PoolStatus {
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
