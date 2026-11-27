//// Reads bytes as one big-endian IEEE 754 float.

import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/int.{to_string}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the bytes as one float of `bits` bits. Fails when the
/// bytes do not hold exactly that many bits.
///
/// ```gleam
/// <<64, 32, 0, 0>>
/// |> should
/// |> extract_float(bits: 32)
/// |> be_equal(2.5)
/// |> or_fail_with("Expected 2.5")
/// ```
pub fn extract_float(
  result: MatchResult(BitArray),
  bits bits: Int,
) -> MatchResult(Float) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> read(bytes, bits)
  }
}

fn read(bytes: BitArray, bits: Int) -> MatchResult(Float) {
  case bytes {
    <<number:float-size(bits)>> -> MatchOk(number)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_float",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(bytes),
          description: "Expected exactly " <> to_string(bits) <> " bits",
        )),
      ))
  }
}
