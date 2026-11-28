//// Prints the status of a process, as `sys:get_status` gives it.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/erlang/process.{type Pid}

/// Gives the status of the process, printed with `~p`: the text that an
/// observer or a crash report shows of its state.
///
/// ```gleam
/// pid_of(connection)
/// |> should
/// |> extract_printed_status
/// |> not_contain_text("<<\"dream\">>")
/// |> or_fail_with("Expected no password in the status")
/// ```
pub fn extract_printed_status(result: MatchResult(Pid)) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pid) -> MatchOk(printed_status(pid))
  }
}

@external(erlang, "driver_parity_ffi", "printed_status")
fn printed_status(pid: Pid) -> String
