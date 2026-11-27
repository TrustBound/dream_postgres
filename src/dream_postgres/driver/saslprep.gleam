//// SASLprep (RFC 4013), the stringprep profile (RFC 3454) that SCRAM
//// applies to a password before it hashes it (RFC 5802 section 2.2).
////
//// The steps are the ones of PostgreSQL's `pg_saslprep`
//// (`src/common/saslprep.c`), so the password gives the key that the
//// server stored:
////
//// 1. Map: each non-ASCII space (table C.1.2) becomes SPACE (U+0020), and
////    each character of table B.1 is removed. An empty result is an error.
//// 2. Normalize with Unicode normalization form KC.
//// 3. Prohibit the characters of RFC 4013 section 2.3 and the code points
////    that Unicode 3.2 does not assign (table A.1).
//// 4. Check the bidirectional rules of RFC 3454 section 6.
////
//// PostgreSQL checks steps 3 and 4 on the text of step 1, before the
//// normalization, and this module does the same. RFC 4013 checks them on
//// the normalized text, but a key that differs from the server's key would
//// make the login fail.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/stringprep_tables.{
  left_to_right, mapped_to_nothing, non_ascii_spaces, prohibited, right_to_left,
  unassigned,
}
import gleam/bool.{guard}
import gleam/list.{any, first, last, map, try_each}
import gleam/result.{try}
import gleam/string.{
  concat, from_utf_codepoints, to_utf_codepoints, utf_codepoint_to_int,
}

/// Why SASLprep refuses a text.
pub type SaslprepError {
  /// The text is empty after the mapping step.
  EmptyAfterMapping
  /// The text holds a prohibited or unassigned code point.
  ProhibitedCodePoint(code_point: Int)
  /// The text holds a right-to-left character and breaks a rule of RFC 3454
  /// section 6: it also holds a left-to-right character, or it does not
  /// start and end with a right-to-left character.
  InvalidBidirectionalText
}

/// Prepares a text with SASLprep, as PostgreSQL does.
///
/// ## Parameters
///
/// - `text`: the text to prepare, for example a password
///
/// ## Returns
///
/// - `Ok(prepared)`: the mapped text in Unicode normalization form KC
/// - `Error(SaslprepError)`: the text is empty after the mapping, or breaks
///   a rule of SASLprep
pub fn saslprep(text: String) -> Result(String, SaslprepError) {
  let mapped =
    to_utf_codepoints(text)
    |> map(mapped_code_point)
    |> concat
  let code_points = to_utf_codepoints(mapped) |> map(utf_codepoint_to_int)
  use <- guard(code_points == [], Error(EmptyAfterMapping))
  use _ <- try(try_each(code_points, check_allowed))
  use _ <- try(check_bidirectional(code_points))
  Ok(normalize_kc(mapped))
}

@external(erlang, "unicode", "characters_to_nfkc_binary")
fn normalize_kc(text: String) -> String

fn mapped_code_point(code_point: UtfCodepoint) -> String {
  let number = utf_codepoint_to_int(code_point)
  use <- guard(in_ranges(number, non_ascii_spaces), " ")
  use <- guard(in_ranges(number, mapped_to_nothing), "")
  from_utf_codepoints([code_point])
}

fn check_allowed(code_point: Int) -> Result(Nil, SaslprepError) {
  let refused =
    in_ranges(code_point, prohibited) || in_ranges(code_point, unassigned)
  use <- guard(refused, Error(ProhibitedCodePoint(code_point)))
  Ok(Nil)
}

/// RFC 3454 section 6: a text with a right-to-left character has no
/// left-to-right character, and starts and ends with a right-to-left
/// character.
fn check_bidirectional(code_points: List(Int)) -> Result(Nil, SaslprepError) {
  use <- guard(!any(code_points, is_right_to_left), Ok(Nil))
  let mixed = any(code_points, is_left_to_right)
  let starts_right_to_left =
    result.map(first(code_points), is_right_to_left) == Ok(True)
  let ends_right_to_left =
    result.map(last(code_points), is_right_to_left) == Ok(True)
  let valid = !mixed && starts_right_to_left && ends_right_to_left
  use <- guard(!valid, Error(InvalidBidirectionalText))
  Ok(Nil)
}

fn is_right_to_left(code_point: Int) -> Bool {
  in_ranges(code_point, right_to_left)
}

fn is_left_to_right(code_point: Int) -> Bool {
  in_ranges(code_point, left_to_right)
}

fn in_ranges(code_point: Int, ranges: List(#(Int, Int))) -> Bool {
  case ranges {
    [] -> False
    [#(first, final), ..rest] ->
      { code_point >= first && code_point <= final }
      || in_ranges(code_point, rest)
  }
}
