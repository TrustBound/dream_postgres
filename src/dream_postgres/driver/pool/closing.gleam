//// Draining and closing a pool: no new checkout, the holds end, and the members
//// stop.

import dream_postgres/driver/catalog
import dream_postgres/driver/pool/checkouts.{refuse_waiters, settle}
import dream_postgres/driver/pool/pool_event.{PoolStopping}
import dream_postgres/driver/pool/pool_failure.{PoolStopped}
import dream_postgres/driver/pool/pool_message.{
  type PoolMessage, DrainDeadlinePassed,
}
import dream_postgres/driver/pool/pool_state.{
  type State, Draining, Serving, State, tell,
}
import gleam/bool.{guard}
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process.{type Down, type ExitMessage, type Subject}
import gleam/list.{append, each}
import gleam/otp/actor

/// While the pool serves, it hands each free connection to the oldest
/// waiter. While it drains, it closes when the last hold ended.
pub fn next(
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

/// Starts to drain, or goes on: each waiter gets `PoolStopped`, and the
/// pool closes when the last hold ended, or at the deadline. A second stop
/// keeps the earlier deadline when it is shorter.
pub fn drain(
  state: State(attachment),
  deadline_milliseconds: Int,
  replies: List(Subject(Nil)),
) -> State(attachment) {
  process.send_after(state.subject, deadline_milliseconds, DrainDeadlinePassed)
  let first_stop = state.phase == Serving
  let state =
    guard(when: !first_stop, return: state, otherwise: fn() {
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
pub fn exit_received(
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
pub fn shut_down(
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
