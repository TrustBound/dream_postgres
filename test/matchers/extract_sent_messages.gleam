//// Extracts the bytes that the query steps sent.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import matchers/extract_query_feed.{type QueryFeed}

/// Gives the bytes that the steps of a query feed asked to send, in
/// order: the encoded frontend messages.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_query_feed(start.state, step_run)
/// |> extract_sent_messages
/// |> be_equal(<<"c", 4:32>>)
/// |> or_fail_with("Expected one CopyDone")
/// ```
pub fn extract_sent_messages(
  result: MatchResult(QueryFeed(state, outcome)),
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(fed) -> MatchOk(fed.sent)
  }
}
