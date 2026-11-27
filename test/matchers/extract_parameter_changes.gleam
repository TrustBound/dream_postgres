//// Extracts `#(name, value)` of each parameter change from asynchronous messages.

import dream_postgres/driver/query.{type AsynchronousMessage, ParameterChanged}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives `#(name, value)` of each parameter change in the list, in order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_parameter_changes
/// |> be_equal([#("application_name", "driver test")])
/// |> or_fail_with("Expected the parameter changes")
/// ```
pub fn extract_parameter_changes(
  result: MatchResult(List(AsynchronousMessage)),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, pick))
  }
}

fn pick(message: AsynchronousMessage) -> Result(#(String, String), Nil) {
  case message {
    ParameterChanged(name, value) -> Ok(#(name, value))
    _other -> Error(Nil)
  }
}
