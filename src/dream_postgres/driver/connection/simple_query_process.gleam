//// The answer of the process to a caller when a Simple Query ends.

import dream_postgres/driver/cell.{type TransactionStatus}
import dream_postgres/driver/connection/notices.{after_step, outcomes_of}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type SimpleQueryError, HousekeepingAnswerUnexpected,
  HousekeepingRefused, SimpleQueryCopyRefused, SimpleQueryFailed,
  SimpleQueryRefused,
}
import dream_postgres/driver/connection/state.{type Finisher, type State, State}
import dream_postgres/driver/query/step.{
  type Failure, type SimpleQueryFailure, type StatementResult, CopyNotSupported,
  ServerError, SimpleQueryFailure,
} as query_step
import dream_postgres/driver/transaction.{track_simple_query}

pub fn simple_query_finisher(
  reply_to: ReplyTo(Result(List(Outcome), SimpleQueryError)),
) -> Finisher(query_step.Outcome(List(StatementResult), SimpleQueryFailure)) {
  fn(state, _socket, outcome) {
    finish_simple_query(state, outcome, reply_to, simple_query_failure)
  }
}

pub fn housekeeping_simple_query_finisher(
  reply_to: ReplyTo(Result(List(Outcome), HousekeepingError)),
) -> Finisher(query_step.Outcome(List(StatementResult), SimpleQueryFailure)) {
  fn(state, _socket, outcome) {
    finish_simple_query(
      state,
      outcome,
      reply_to,
      housekeeping_simple_query_failure,
    )
  }
}

fn finish_simple_query(
  state: State,
  outcome: query_step.Outcome(List(StatementResult), SimpleQueryFailure),
  reply_to: ReplyTo(Result(List(Outcome), error)),
  failing: fn(Failure, TransactionStatus, List(Outcome)) -> error,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_simple_query(state.tracker, outcome)
  let #(state, result) = simple_query_result(state, outcome, failing)
  reply(reply_to, result)
  State(..state, tracker:)
}

fn simple_query_result(
  state: State,
  outcome: query_step.Outcome(List(StatementResult), SimpleQueryFailure),
  failing: fn(Failure, TransactionStatus, List(Outcome)) -> error,
) -> #(State, Result(List(Outcome), error)) {
  case outcome.result {
    Ok(statements) -> {
      let #(state, outcomes) = outcomes_of(state, statements, outcome.status)
      #(state, Ok(outcomes))
    }
    Error(SimpleQueryFailure(completed:, failure:)) -> {
      let #(state, outcomes) = outcomes_of(state, completed, outcome.status)
      #(state, Error(failing(failure, outcome.status, outcomes)))
    }
  }
}

/// A housekeeping statement is one statement that is not a COPY, so an
/// error after a result and a COPY answer break the protocol.
fn housekeeping_simple_query_failure(
  failure: Failure,
  status: TransactionStatus,
  completed: List(Outcome),
) -> HousekeepingError {
  case failure, completed {
    ServerError(report), [] -> HousekeepingRefused(report, status)
    ServerError(_report), [_ran, ..] | CopyNotSupported(_report), _ran ->
      HousekeepingAnswerUnexpected
  }
}

/// The first statement of a simple query that fails is refused; a later one
/// fails the simple query after the ones that ran.
fn simple_query_failure(
  failure: Failure,
  status: TransactionStatus,
  completed: List(Outcome),
) -> SimpleQueryError {
  case failure, completed {
    ServerError(report), [] -> SimpleQueryRefused(report, status)
    ServerError(report), _ran -> SimpleQueryFailed(completed, report, status)
    CopyNotSupported(_report), _ran -> SimpleQueryCopyRefused(completed)
  }
}
