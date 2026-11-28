//// Extracts the name of a span that the test tracer recorded.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import driver/test_tracer.{type RecordedSpan}

/// Gives the name of the span.
///
/// ```gleam
/// next_span()
/// |> should
/// |> be_ok
/// |> extract_span_name
/// |> be_equal("INSERT app")
/// |> or_fail_with("Expected the name INSERT app")
/// ```
pub fn extract_span_name(
  result: MatchResult(RecordedSpan),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(span) -> MatchOk(span.name)
  }
}
