//// Gives backend messages to a query step, one at a time.

import dream_postgres/driver/message.{type BackendMessage, type FrontendMessage}
import dream_postgres/driver/query.{
  type Step, type UnexpectedMessage, Send, Wait,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{append}

/// The messages that the steps asked to send, in order, and what the last
/// step gave.
pub type QueryFeed(state, outcome) {
  QueryFeed(
    sent: List(FrontendMessage),
    last: Result(Step(state, outcome), UnexpectedMessage),
  )
}

/// Gives each message of the list to `step`, starting from `state`, while
/// the step waits or sends. Stops at the first step that finishes or gives
/// an error. Gives the messages that the steps sent, and the last step.
///
/// ```gleam
/// [ParseComplete, ParameterDescriptions([]), NoData, ReadyForQuery(Idle)]
/// |> should
/// |> extract_query_feed(start.state, step_prepare)
/// |> extract_last_step
/// |> be_ok
/// |> be_equal(Finished(expected_outcome))
/// |> or_fail_with("Expected the statement description")
/// ```
pub fn extract_query_feed(
  result: MatchResult(List(BackendMessage)),
  state: state,
  step: fn(state, BackendMessage) ->
    Result(Step(state, outcome), UnexpectedMessage),
) -> MatchResult(QueryFeed(state, outcome)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) ->
      MatchOk(feed_from(
        QueryFeed(sent: [], last: Ok(Wait(state))),
        messages,
        step,
      ))
  }
}

fn feed_from(
  fed: QueryFeed(state, outcome),
  messages: List(BackendMessage),
  step: fn(state, BackendMessage) ->
    Result(Step(state, outcome), UnexpectedMessage),
) -> QueryFeed(state, outcome) {
  case fed.last, messages {
    Ok(Wait(state)), [message, ..rest]
    | Ok(Send(state:, ..)), [message, ..rest]
    -> feed_from(record(fed.sent, step(state, message)), rest, step)
    _, _ -> fed
  }
}

fn record(
  sent: List(FrontendMessage),
  last: Result(Step(state, outcome), UnexpectedMessage),
) -> QueryFeed(state, outcome) {
  case last {
    Ok(Send(messages:, ..)) -> QueryFeed(sent: append(sent, messages), last:)
    _other -> QueryFeed(sent:, last:)
  }
}
