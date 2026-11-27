//// Reads bytes as one big-endian signed integer.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/int.{to_string}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the bytes as one signed integer of `bits` bits. Fails when the
/// bytes do not hold exactly that many bits.
///
/// ```gleam
/// <<255, 254>>
/// |> should
/// |> extract_signed_integer(bits: 16)
/// |> be_equal(-2)
/// |> or_fail_with("Expected -2")
/// ```
pub fn extract_signed_integer(
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
    <<number:signed-size(bits)>> -> MatchOk(number)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_signed_integer",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(bytes),
          description: "Expected exactly " <> to_string(bits) <> " bits",
        )),
      ))
  }
}
