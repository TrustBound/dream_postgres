//// The members of the pool: what they report, and the health check of their
//// connections.

import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/pool/checkouts.{free_connection, is_free}
import dream_postgres/driver/pool/pool_event.{
  type PoolEvent, MemberConnectFailed, MemberConnected, MemberDisconnected,
  MemberFree, MemberReconnected, MemberReplacing,
}
import dream_postgres/driver/pool/pool_message.{HealthCheckDue}
import dream_postgres/driver/pool/pool_state.{
  type Slot, type State, type Usage, Free, Maintained, MemberProcess, Slot,
  State, tell,
}
import dream_postgres/driver/pool_member.{
  type Member, type MemberReport, MemberReady, MemberStarted, SessionBack,
  SessionLost,
}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result

/// Changes the state for the report, then tells the subscriber the event
/// of the report, and `MemberFree` when the report freed the member's
/// connection.
pub fn after_report(
  state: State(attachment),
  report: MemberReport,
) -> State(attachment) {
  let slot_id = report_slot(report)
  let changed = state_after_report(state, report)
  let told =
    event_of_report(report)
    |> option.map(tell(changed, _))
    |> option.unwrap(changed)
  case slot_is_free(state, slot_id), slot_is_free(told, slot_id) {
    False, True -> tell(told, MemberFree(slot_id))
    True, True | True, False | False, False -> told
  }
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
pub fn update_slot(
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
pub fn check_health(state: State(attachment)) -> State(attachment) {
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
