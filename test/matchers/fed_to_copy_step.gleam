//// A matcher for the copy step of `dream_postgres/driver/query/copy_step`: feeds
//// inputs to a new copy step, one at a time, and gives what the step gave
//// for each.

import dream_postgres/driver/query/copy_step.{
  type CopyState, type CopyStep, CopyConnectionEnded, CopyFinished, CopyRow,
  CopySend, CopyStarted, CopyWait,
} as query_copy_step
import dream_postgres/driver/query/step.{
  type CopyDirection, type UnexpectedMessage, UnexpectedMessage,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/copy_step_inputs.{
  type Input, type Seen, AppAbandons, AppFinishes, ConnectionEnded,
  DeadlinePasses, Finished, FromServer, Row, Sent, Started, Unexpected, Waited,
}
import gleam/list

/// The step after some inputs, what it gave for each, newest first, and
/// whether it still takes inputs.
type Fed {
  Fed(state: CopyState, seen: List(Seen), open: Bool)
}

/// Feeds the inputs to a new copy step of `direction`, in order, up to the
/// end of the step.
///
/// ## Parameters
///
/// - `result`: the inputs
/// - `direction`: the direction of the step's COPY
///
/// ## Returns
///
/// What the step gave for each input that it took, in order.
pub fn fed_to_copy_step(
  result: MatchResult(List(Input)),
  direction: CopyDirection,
) -> MatchResult(List(Seen)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(inputs) -> MatchOk(feed(inputs, direction))
  }
}

fn feed(inputs: List(Input), direction: CopyDirection) -> List(Seen) {
  let start = query_copy_step.start_copy("COPY t FROM STDIN", direction)
  let fed = list.fold(inputs, Fed(start.state, [], True), feed_one)
  list.reverse(fed.seen)
}

fn feed_one(fed: Fed, input: Input) -> Fed {
  case fed.open, input {
    False, _ -> fed
    True, FromServer(message) ->
      seen_step(fed, query_copy_step.step_copy(fed.state, message))
    True, AppFinishes -> app_step(fed, query_copy_step.finish_copy(fed.state))
    True, AppAbandons -> app_step(fed, query_copy_step.abandon_copy(fed.state))
    True, DeadlinePasses ->
      app_step(fed, query_copy_step.stop_at_deadline(fed.state))
  }
}

fn app_step(fed: Fed, stepped: #(CopyState, BitArray)) -> Fed {
  Fed(state: stepped.0, seen: [Sent(stepped.1), ..fed.seen], open: True)
}

fn seen_step(fed: Fed, step: Result(CopyStep, UnexpectedMessage)) -> Fed {
  case step {
    Ok(CopyStarted(state)) -> Fed(state, [Started, ..fed.seen], True)
    Ok(CopyRow(row, state)) -> Fed(state, [Row(row), ..fed.seen], True)
    Ok(CopySend(bytes, state)) -> Fed(state, [Sent(bytes), ..fed.seen], True)
    Ok(CopyWait(state)) -> Fed(state, [Waited, ..fed.seen], True)
    Ok(CopyFinished(outcome)) ->
      Fed(..fed, seen: [Finished(outcome), ..fed.seen], open: False)
    Ok(CopyConnectionEnded(report, _messages)) ->
      Fed(..fed, seen: [ConnectionEnded(report), ..fed.seen], open: False)
    Error(UnexpectedMessage(phase:, ..)) ->
      Fed(..fed, seen: [Unexpected(phase), ..fed.seen], open: False)
  }
}
