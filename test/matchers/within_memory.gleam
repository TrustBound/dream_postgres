//// A matcher for the COPY memory tests: the peak of a COPY stays within a
//// bound.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/copy_callbacks.{type MemoryPeak}
import gleam/int
import gleam/option.{Some}

/// Checks that the memory of the connection process and of the caller
/// stayed under `bound` bytes, and the mailbox of the connection process
/// at most `queue_bound` messages, over a COPY of `count` rows.
///
/// ## Parameters
///
/// - `result`: the count of the COPY and its peak
/// - `bound`: the bound of each memory, in bytes
/// - `queue_bound`: the bound of the mailbox, in messages
///
/// ## Returns
///
/// The count, for the next matcher.
pub fn within_memory(
  result: MatchResult(#(Int, MemoryPeak)),
  bound: Int,
  queue_bound: Int,
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(#(count, peak)) -> check_peak(count, peak, bound, queue_bound)
  }
}

fn check_peak(
  count: Int,
  peak: MemoryPeak,
  bound: Int,
  queue_bound: Int,
) -> MatchResult(Int) {
  let within =
    peak.connection < bound && peak.caller < bound && peak.queue <= queue_bound
  case within {
    True -> MatchOk(count)
    False -> peak_failure(peak, bound, queue_bound)
  }
}

fn peak_failure(
  peak: MemoryPeak,
  bound: Int,
  queue_bound: Int,
) -> MatchResult(Int) {
  MatchFailed(AssertionFailure(
    operator: "within_memory",
    message: "",
    payload: Some(CustomMatcherFailure(
      actual: "connection "
        <> int.to_string(peak.connection)
        <> " bytes, caller "
        <> int.to_string(peak.caller)
        <> " bytes, mailbox "
        <> int.to_string(peak.queue),
      description: "expected each memory under "
        <> int.to_string(bound)
        <> " bytes and the mailbox at most "
        <> int.to_string(queue_bound),
    )),
  ))
}
