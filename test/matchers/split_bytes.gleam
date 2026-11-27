//// Splits bytes in two at a byte count.

import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives `Ok(#(first, rest))`: the first `at` bytes and the bytes after
/// them. Gives `Error(Nil)` when there are fewer bytes than `at`, or when
/// `at` is negative.
///
/// ```gleam
/// <<"abcdef":utf8>>
/// |> should
/// |> split_bytes(at: 2)
/// |> be_ok
/// |> be_equal(#(<<"ab":utf8>>, <<"cdef":utf8>>))
/// |> or_fail_with("Expected ab, then cdef")
/// ```
pub fn split_bytes(
  result: MatchResult(BitArray),
  at count: Int,
) -> MatchResult(Result(#(BitArray, BitArray), Nil)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(bytes) -> MatchOk(split(bytes, count))
  }
}

fn split(bytes: BitArray, count: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bytes {
    <<first:bytes-size(count), rest:bytes>> -> Ok(#(first, rest))
    _other -> Error(Nil)
  }
}
