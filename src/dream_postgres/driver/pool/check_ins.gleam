//// A check in in the manager: a connection that comes back, or a holder that
//// ends.

import dream_postgres/driver/pool/members.{update_slot}
import dream_postgres/driver/pool/pool_event.{MemberReturned}
import dream_postgres/driver/pool/pool_state.{
  type Holder, type Slot, type State, HeldBy, Maintained, Slot, State, tell,
}
import dream_postgres/driver/pool_member
import gleam/dict
import gleam/erlang/process.{type Monitor}
import gleam/list.{find}
import gleam/option.{Some}
import gleam/result

/// Ends a hold. The connection goes to its member for a reset, unless the
/// member replaced it during the hold.
pub fn check_in(state: State(attachment), lease_id: Int) -> State(attachment) {
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
pub fn after_down(
  state: State(attachment),
  monitor: Monitor,
) -> State(attachment) {
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
