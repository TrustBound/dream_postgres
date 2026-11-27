//// Extracts the messages that the query steps sent.

import dream_postgres/driver/message.{type FrontendMessage}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import matchers/extract_query_feed.{type QueryFeed}

/// Gives the messages that the steps of a query feed asked to send, in
/// order.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_query_feed(start.state, step_run)
/// |> extract_sent_messages
/// |> be_equal([CopyFail("COPY is not supported by this step")])
/// |> or_fail_with("Expected one CopyFail")
/// ```
pub fn extract_sent_messages(
  result: MatchResult(QueryFeed(state, outcome)),
) -> MatchResult(List(FrontendMessage)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(fed) -> MatchOk(fed.sent)
  }
}
