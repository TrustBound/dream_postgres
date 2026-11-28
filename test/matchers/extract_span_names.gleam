//// A matcher that gives the name of each recorded span.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/test_tracer.{type RecordedSpan}
import gleam/list

/// Give the name of each span, in order.
///
/// ## Example
///
/// ```gleam
/// spans
/// |> should
/// |> extract_span_names()
/// |> be_equal(["user.find_by_email"])
/// |> or_fail_with("Expected the span of the named query")
/// ```
pub fn extract_span_names(
  result: MatchResult(List(RecordedSpan)),
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(spans) -> MatchOk(list.map(spans, span_name))
  }
}

fn span_name(span: RecordedSpan) -> String {
  span.name
}
