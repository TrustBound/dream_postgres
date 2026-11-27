//// Reads the bytes after a 32-bit length.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Reads a 32-bit length, then gives that many bytes after it. Bytes after
/// them stay out of the result. Fails when there are fewer bytes than the
/// length.
///
/// ```gleam
/// <<3:32, "abcdef":utf8>>
/// |> should
/// |> extract_length_prefixed_bytes
/// |> be_equal(<<"abc":utf8>>)
/// |> or_fail_with("Expected the first three bytes")
/// ```
pub fn extract_length_prefixed_bytes(
  result: MatchResult(BitArray),
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> read(bytes)
  }
}

fn read(bytes: BitArray) -> MatchResult(BitArray) {
  case bytes {
    <<size:32, value:bytes-size(size), _rest:bytes>> -> MatchOk(value)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_length_prefixed_bytes",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(bytes),
          description: "Expected a 32-bit length and that many bytes",
        )),
      ))
  }
}
