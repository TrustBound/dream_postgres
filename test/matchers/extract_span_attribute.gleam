//// Extracts one attribute of a span that the test tracer recorded.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/test_tracer.{type RecordedSpan}
import gleam/list.{key_find}
import gleam/option.{type Option}

/// Gives the value of the attribute `key` of the span, or `None` when the
/// span has no such attribute.
///
/// ```gleam
/// next_span()
/// |> should
/// |> be_ok
/// |> extract_span_attribute(key: "db.response.status_code")
/// |> be_equal(Some("01004"))
/// |> or_fail_with("Expected the last warning code")
/// ```
pub fn extract_span_attribute(
  result: MatchResult(RecordedSpan),
  key key: String,
) -> MatchResult(Option(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(span) ->
      MatchOk(key_find(span.attributes, key) |> option.from_result)
  }
}
