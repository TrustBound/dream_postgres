//// A matcher that finds the named codes that do not round trip through
//// the SqlState type.

import dream_postgres/sql_state.{UnlistedClass}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list
import gleam/string

/// Keep each `#(code, condition_name)` of the chain whose code does not
/// round trip: `sql_state.from_string` then `sql_state.to_string` does not
/// give the code back, `sql_state.name` does not give the condition name, or
/// `sql_state.class` does not give a listed class. The chain goes on with
/// the codes that do not round trip.
///
/// ## Example
///
/// ```gleam
/// errcodes.named_codes("16")
/// |> should
/// |> find_round_trip_mismatches()
/// |> be_empty()
/// |> or_fail_with("Expected every code to round trip")
/// ```
pub fn find_round_trip_mismatches(
  result: MatchResult(List(#(String, String))),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(codes) -> MatchOk(list.filter(codes, does_not_round_trip))
  }
}

fn does_not_round_trip(named_code: #(String, String)) -> Bool {
  let #(code, condition_name) = named_code
  let parsed = sql_state.parse_sql_state(code)
  sql_state.sql_state_to_string(parsed) != code
  || sql_state.sql_state_name(parsed) != Ok(condition_name)
  || sql_state.sql_state_class(parsed)
  == UnlistedClass(string.slice(code, 0, 2))
}
