//// The deadline of a request: what happens when it passes, and when its cancel
//// ends.

import dream_postgres/driver/connection/refusal.{refuse_running, refuse_ticket}
import dream_postgres/driver/connection/request_failure.{
  DeadlinePassed, RefusedWithFailure,
}
import dream_postgres/driver/connection/state.{
  type Current, type Running, type State, type Ticket, Current, State,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}

pub fn deadline_passed(state: State) -> Bool {
  state.current |> option.map(current_deadline_passed) |> option.unwrap(False)
}

fn current_deadline_passed(current: Current) -> Bool {
  current.deadline_passed
}

/// After its deadline, a request's caller gets `DeadlinePassed` when its
/// step ends, before the step's own answer, which the caller's alias then
/// drops. A request that the deadline stopped goes no further.
pub fn answer_deadline(state: State, running: Running) -> State {
  case state.current {
    Some(Current(deadline_passed: True, cancel_confirmed:, ..)) -> {
      refuse_running(running, DeadlinePassed(cancelled: cancel_confirmed))
      state
    }
    _ -> state
  }
}

pub fn end_waiting(state: State, id: Int) -> State {
  let #(ended, waiting) = list.partition(state.waiting, has_id(_, id))
  list.each(ended, refuse_ticket(
    _,
    RefusedWithFailure(DeadlinePassed(cancelled: False)),
  ))
  State(..state, waiting:)
}

fn has_id(ticket: Ticket, id: Int) -> Bool {
  ticket.id == id
}

pub fn end_current(state: State) -> State {
  option.map(state.current, stop_timer)
  State(..state, current: None)
}

fn stop_timer(current: Current) -> Nil {
  process.cancel_timer(current.timer)
  Nil
}
