//// Extracts the values that ParameterStatus messages give one parameter.

import dream_postgres/driver/message.{type BackendMessage, ParameterStatus}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list.{filter_map}

/// Gives the value of each ParameterStatus message for the parameter
/// `name` in the list, in order. Other messages give nothing.
///
/// ```gleam
/// messages
/// |> should
/// |> extract_parameter_values(named: "server_version")
/// |> be_equal(["18.7"])
/// |> or_fail_with("Expected the server_version 18.7")
/// ```
pub fn extract_parameter_values(
  result: MatchResult(List(BackendMessage)),
  named name: String,
) -> MatchResult(List(String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(messages) -> MatchOk(filter_map(messages, value_of(_, name)))
  }
}

fn value_of(message: BackendMessage, name: String) -> Result(String, Nil) {
  case message {
    ParameterStatus(parameter, value) if parameter == name -> Ok(value)
    _other -> Error(Nil)
  }
}
