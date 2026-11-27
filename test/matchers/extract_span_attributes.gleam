//// A matcher that gives every attribute of the recorded spans.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/test_tracer.{type RecordedSpan}
import gleam/list

/// Give each attribute of each span, as a key and a value, in the order
/// of the spans.
///
/// ## Example
///
/// ```gleam
/// spans
/// |> should
/// |> extract_span_attributes()
/// |> contain(#("db.system.name", "postgresql"))
/// |> or_fail_with("Expected the database system")
/// ```
pub fn extract_span_attributes(
  result: MatchResult(List(RecordedSpan)),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(spans) -> MatchOk(list.flat_map(spans, span_attributes))
  }
}

fn span_attributes(span: RecordedSpan) -> List(#(String, String)) {
  span.attributes
}
