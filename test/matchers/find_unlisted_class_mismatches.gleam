//// A matcher that finds the classes that an unlisted code does not get.

import dream_postgres/sql_state.{Unlisted}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list
import gleam/string

/// Keep each `#(code, condition_name)` of the chain whose class an unlisted
/// code of the same class does not get: the class of `Unlisted` with the
/// first two characters of the code and `ZZZ` is not the class of the code.
/// The chain goes on with the codes whose class the unlisted code does not
/// get.
///
/// ## Example
///
/// ```gleam
/// errcodes.named_codes("16")
/// |> should
/// |> find_unlisted_class_mismatches()
/// |> be_empty()
/// |> or_fail_with("Expected an unlisted code to get its class")
/// ```
pub fn find_unlisted_class_mismatches(
  result: MatchResult(List(#(String, String))),
) -> MatchResult(List(#(String, String))) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(codes) -> MatchOk(list.filter(codes, unlisted_class_differs))
  }
}

fn unlisted_class_differs(named_code: #(String, String)) -> Bool {
  let #(code, _condition_name) = named_code
  let unlisted = Unlisted(string.slice(code, 0, 2) <> "ZZZ")
  sql_state.sql_state_class(unlisted)
  != sql_state.sql_state_class(sql_state.parse_sql_state(code))
}
