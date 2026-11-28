//// The answer of the process to a caller when a step of the Extended Query
//// protocol ends.

import dream_postgres/driver/connection/notices.{
  after_step, plain_outcome, take_pending,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  type Prepared, type StatementRequest, PrepareStatement, Prepared, RunStatement,
}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type PrepareError, type RunError,
  HousekeepingAnswerUnexpected, HousekeepingRefused, PrepareRefused,
  RunCopyRefused, RunRefused,
}
import dream_postgres/driver/connection/state.{type Finisher, type State, State}
import dream_postgres/driver/query/step.{
  type Failure, type StatementResult, CopyNotSupported, ServerError,
} as query_step
import dream_postgres/driver/transaction.{
  type TransactionTracker, track, track_step,
}
import dream_postgres/internal/cell.{
  type ServerReport, type StatementDescription, type TransactionStatus,
}
import gleam/option
import gleam/result.{map_error}

pub fn prepare_finisher(
  reply_to: ReplyTo(Result(Prepared, PrepareError)),
) -> Finisher(query_step.Outcome(StatementDescription, ServerReport)) {
  fn(state, _socket, outcome) { finish_prepare(state, outcome, reply_to) }
}

pub fn run_finisher(
  reply_to: ReplyTo(Result(Outcome, RunError)),
) -> Finisher(query_step.Outcome(StatementResult, Failure)) {
  fn(state, _socket, outcome) {
    finish_run(state, outcome, reply_to, run_failure)
  }
}

pub fn housekeeping_run_finisher(
  reply_to: ReplyTo(Result(Outcome, HousekeepingError)),
) -> Finisher(query_step.Outcome(StatementResult, Failure)) {
  fn(state, _socket, outcome) {
    finish_run(state, outcome, reply_to, housekeeping_run_failure)
  }
}

fn finish_prepare(
  state: State,
  outcome: query_step.Outcome(StatementDescription, ServerReport),
  reply_to: ReplyTo(Result(Prepared, PrepareError)),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_prepare(state.tracker, outcome)
  let warning_code = state.warning_code
  let result =
    outcome.result
    |> result.map(Prepared(_, warning_code:))
    |> map_error(PrepareRefused(_, outcome.status))
  reply(reply_to, result)
  State(..state, tracker:)
}

/// A prepare fails only with the server's error.
pub fn track_prepare(
  tracker: TransactionTracker,
  outcome: query_step.Outcome(StatementDescription, ServerReport),
) -> TransactionTracker {
  track(
    tracker,
    outcome.status,
    option.from_result(result_error(outcome.result)),
  )
}

fn result_error(result: Result(value, error)) -> Result(error, Nil) {
  case result {
    Ok(_value) -> Error(Nil)
    Error(error) -> Ok(error)
  }
}

fn finish_run(
  state: State,
  outcome: query_step.Outcome(StatementResult, Failure),
  reply_to: ReplyTo(Result(Outcome, error)),
  failing: fn(Failure, TransactionStatus) -> error,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let #(state, result) = case outcome.result {
    Ok(statement) -> {
      let #(state, single) =
        take_pending(state, plain_outcome(statement, outcome.status))
      #(state, Ok(single))
    }
    Error(failure) -> #(state, Error(failing(failure, outcome.status)))
  }
  reply(reply_to, result)
  State(..state, tracker:)
}

/// The server refused the prepare of a statement: a `prepare` or the first
/// run of a statement.
pub fn prepare_refused(
  request: StatementRequest,
  report: ServerReport,
  status: TransactionStatus,
) -> Nil {
  case request {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareRefused(report, status)))
    RunStatement(details) ->
      reply(details.reply, Error(RunRefused(report, status)))
  }
}

pub fn run_failure(failure: Failure, status: TransactionStatus) -> RunError {
  case failure {
    ServerError(report) -> RunRefused(report, status)
    CopyNotSupported(_report) -> RunCopyRefused
  }
}

/// A housekeeping statement is not a COPY, so a COPY answer breaks the
/// protocol.
fn housekeeping_run_failure(
  failure: Failure,
  status: TransactionStatus,
) -> HousekeepingError {
  case failure {
    ServerError(report) -> HousekeepingRefused(report, status)
    CopyNotSupported(_report) -> HousekeepingAnswerUnexpected
  }
}
