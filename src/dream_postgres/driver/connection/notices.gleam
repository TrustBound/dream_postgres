//// The notices and the notifications that the server sends: kept, and given to
//// the caller with the outcome of the next request.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/connection/outcome.{
  type Notification, type Outcome, Notification, Outcome,
}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/connection/state.{type State, State}
import dream_postgres/driver/query/step.{
  type AsynchronousMessage, type StatementResult, Notice, ParameterChanged,
} as query_step
import dream_postgres/driver/sink.{type Delivery, Delivered, MapFailed}
import dream_postgres/driver/trace
import gleam/dict
import gleam/list.{filter_map, fold, reverse}
import gleam/option.{None, Some}

/// Sends a notice to the notices subscriber, if any, and keeps it for the
/// outcome of the request that runs: the next request drops the notices
/// that no outcome took, so none goes with a later request. A
/// notification goes at once to the notifications subscriber when there
/// is one, in the order the server sent it, and is kept for the next
/// outcome otherwise.
pub fn keep_asynchronous(state: State, message: AsynchronousMessage) -> State {
  case message, state.config.notifications {
    query_step.Notification(process_id:, channel:, payload:), Some(subscriber)
    ->
      sink.deliver(subscriber, Notification(process_id:, channel:, payload:))
      |> keep_notifications(state, _)
    Notice(report:), _subscriber -> {
      let state = send_notice(state, report)
      State(
        ..state,
        pending: [message, ..state.pending],
        warning_code: trace.later_warning_code(state.warning_code, report.code),
      )
    }
    query_step.Notification(..), None | ParameterChanged(..), _subscriber ->
      State(..state, pending: [message, ..state.pending])
  }
}

/// Sends a notice through the notices sink, if the process has one.
pub fn send_notice(state: State, report: ServerReport) -> State {
  case state.config.notices {
    Some(notices) -> sink.deliver(notices, report) |> keep_notices(state, _)
    None -> state
  }
}

/// A notices sink whose map crashed is dropped.
fn keep_notices(state: State, delivery: Delivery) -> State {
  case delivery {
    Delivered -> state
    MapFailed ->
      State(..state, config: ConnectionConfig(..state.config, notices: None))
  }
}

/// A notifications sink whose map crashed is dropped.
fn keep_notifications(state: State, delivery: Delivery) -> State {
  case delivery {
    Delivered -> state
    MapFailed ->
      State(
        ..state,
        config: ConnectionConfig(..state.config, notifications: None),
      )
  }
}

pub fn is_notification(message: AsynchronousMessage) -> Bool {
  case message {
    query_step.Notification(..) -> True
    Notice(..) | ParameterChanged(..) -> False
  }
}

/// One outcome for each statement. The last one carries the pending
/// notices and notifications. With no statement, they stay pending for
/// the next outcome.
pub fn outcomes_of(
  state: State,
  statements: List(StatementResult),
  status: TransactionStatus,
) -> #(State, List(Outcome)) {
  let outcomes = list.map(statements, plain_outcome(_, status))
  case reverse(outcomes) {
    [] -> #(state, [])
    [last, ..earlier] -> {
      let #(state, last) = take_pending(state, last)
      #(state, reverse([last, ..earlier]))
    }
  }
}

/// Gives the outcome the pending notices and notifications, which are
/// then no longer pending.
pub fn take_pending(state: State, outcome: Outcome) -> #(State, Outcome) {
  #(State(..state, pending: []), with_pending(outcome, state.pending))
}

pub fn plain_outcome(
  statement: StatementResult,
  status: TransactionStatus,
) -> Outcome {
  Outcome(
    columns: statement.columns,
    result: statement.result,
    notices: [],
    notifications: [],
    transaction_status: status,
  )
}

fn with_pending(
  outcome: Outcome,
  pending: List(AsynchronousMessage),
) -> Outcome {
  let messages = reverse(pending)
  Outcome(
    ..outcome,
    notices: filter_map(messages, notice_of),
    notifications: filter_map(messages, notification_of),
  )
}

fn notice_of(message: AsynchronousMessage) -> Result(ServerReport, Nil) {
  case message {
    Notice(report) -> Ok(report)
    _other -> Error(Nil)
  }
}

fn notification_of(message: AsynchronousMessage) -> Result(Notification, Nil) {
  case message {
    query_step.Notification(process_id:, channel:, payload:) ->
      Ok(Notification(process_id:, channel:, payload:))
    _other -> Error(Nil)
  }
}

/// Keeps the parameter changes, and adds the notices and notifications to
/// the pending ones.
pub fn after_step(state: State, messages: List(AsynchronousMessage)) -> State {
  fold(messages, state, after_message)
}

fn after_message(state: State, message: AsynchronousMessage) -> State {
  case message {
    ParameterChanged(name:, value:) ->
      State(..state, parameters: dict.insert(state.parameters, name, value))
    _notice_or_notification -> keep_asynchronous(state, message)
  }
}
