//// Reads bytes as one big-endian unsigned integer.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/int.{to_string}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the bytes as one unsigned integer of `bits` bits. Fails when the
/// bytes do not hold exactly that many bits.
///
/// ```gleam
/// <<255, 255, 255, 255>>
/// |> should
/// |> extract_unsigned_integer(bits: 32)
/// |> be_equal(4_294_967_295)
/// |> or_fail_with("Expected 4294967295")
/// ```
pub fn extract_unsigned_integer(
  result: MatchResult(BitArray),
  bits bits: Int,
) -> MatchResult(Int) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> read(bytes, bits)
  }
}

fn read(bytes: BitArray, bits: Int) -> MatchResult(Int) {
  case bytes {
    <<number:size(bits)>> -> MatchOk(number)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_unsigned_integer",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(bytes),
          description: "Expected exactly " <> to_string(bits) <> " bits",
        )),
      ))
  }
}
