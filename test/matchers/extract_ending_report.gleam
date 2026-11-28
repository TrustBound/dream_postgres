//// Extracts the report of a session that the server ended.

import dream_postgres/driver/cell.{type ServerReport}
import dream_postgres/driver/connection/event.{
  type ConnectionEnd, ServerEndedConnection,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the FATAL or PANIC report of `ServerEndedConnection`. Fails for
/// other errors.
///
/// ```gleam
/// next_event(events)
/// |> should
/// |> be_ok
/// |> extract_disconnect_error
/// |> extract_ending_report
/// |> extract_report_code
/// |> be_equal("57P01")
/// |> or_fail_with("Expected the server to end the session")
/// ```
pub fn extract_ending_report(
  result: MatchResult(ConnectionEnd),
) -> MatchResult(ServerReport) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> report_of(error)
  }
}

fn report_of(error: ConnectionEnd) -> MatchResult(ServerReport) {
  case error {
    ServerEndedConnection(report) -> MatchOk(report)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_ending_report",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ServerEndedConnection",
        )),
      ))
  }
}
