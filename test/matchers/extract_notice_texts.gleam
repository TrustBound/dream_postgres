//// Extracts the text of each notice from asynchronous messages.

import dream_postgres/driver/query/step.{type AsynchronousMessage, Notice}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives the text of each notice in the list, in order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_notice_texts
/// |> be_equal(["first", "second"])
/// |> or_fail_with("Expected the notice texts")
/// ```
pub fn extract_notice_texts(
  result: MatchResult(List(AsynchronousMessage)),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, pick))
  }
}

fn pick(message: AsynchronousMessage) -> Result(String, Nil) {
  case message {
    Notice(report) -> Ok(report.message)
    _other -> Error(Nil)
  }
}
