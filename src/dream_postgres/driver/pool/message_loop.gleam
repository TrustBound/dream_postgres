//// The loop of the pool manager: one message at a time.

import dream_postgres/driver/pool/check_ins.{after_down, check_in}
import dream_postgres/driver/pool/checkouts.{
  check_out_request, expire, status_of,
}
import dream_postgres/driver/pool/closing.{drain, exit_received, next, shut_down}
import dream_postgres/driver/pool/members.{after_report, check_health}
import dream_postgres/driver/pool/pool_message.{
  type PoolMessage, AttachmentRequest, CatalogRequest, CheckIn, CheckOut,
  DrainDeadlinePassed, ExitReceived, HealthCheckDue, MemberReported,
  MonitorFired, StatusRequest, StopRequest, WaiterExpired,
}
import dream_postgres/driver/pool/pool_state.{type State}
import gleam/erlang/process
import gleam/otp/actor

pub fn handle_message(
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
