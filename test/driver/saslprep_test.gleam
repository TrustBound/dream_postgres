//// Tests for `dream_postgres/driver/saslprep`: the examples of RFC 4013
//// section 3, and each rule of the profile.

import dream_postgres/driver/saslprep.{
  type SaslprepError, EmptyAfterMapping, InvalidBidirectionalText,
  ProhibitedCodePoint, saslprep,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/list.{map}

/// The tests of SASLprep.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/saslprep", [
    group("the examples of RFC 4013 section 3", map(rfc_cases(), saslprep_test)),
    group("each rule of the profile", map(rule_cases(), saslprep_test)),
  ])
}

type SaslprepCase {
  SaslprepCase(
    name: String,
    input: String,
    expected: Result(String, SaslprepError),
  )
}

fn saslprep_test(test_case: SaslprepCase) {
  it(test_case.name, fn() { check_saslprep(test_case) })
}

fn check_saslprep(test_case: SaslprepCase) {
  // Act
  let prepared = saslprep(test_case.input)

  // Assert
  prepared
  |> should
  |> be_equal(test_case.expected)
  |> or_fail_with("Expected the SASLprep result of " <> test_case.name)
}

fn rfc_cases() -> List(SaslprepCase) {
  [
    SaslprepCase("1: SOFT HYPHEN mapped to nothing", "I\u{00AD}X", Ok("IX")),
    SaslprepCase("2: no transformation", "user", Ok("user")),
    SaslprepCase("3: case preserved", "USER", Ok("USER")),
    SaslprepCase("4: output is NFKC", "\u{00AA}", Ok("a")),
    SaslprepCase("5: output is NFKC, matches 1", "\u{2168}", Ok("IX")),
    SaslprepCase(
      "6: prohibited character",
      "\u{0007}",
      Error(ProhibitedCodePoint(0x07)),
    ),
    SaslprepCase(
      "7: bidirectional check",
      "\u{0627}\u{0031}",
      Error(InvalidBidirectionalText),
    ),
  ]
}

fn rule_cases() -> List(SaslprepCase) {
  [
    SaslprepCase("a non-ASCII space becomes SPACE", "a\u{00A0}b", Ok("a b")),
    SaslprepCase(
      "a text that the mapping empties",
      "\u{00AD}\u{200D}",
      Error(EmptyAfterMapping),
    ),
    SaslprepCase("the empty text", "", Error(EmptyAfterMapping)),
    SaslprepCase(
      "a code point that Unicode 3.2 does not assign",
      "a\u{0221}",
      Error(ProhibitedCodePoint(0x0221)),
    ),
    SaslprepCase(
      "a private use character",
      "\u{E000}",
      Error(ProhibitedCodePoint(0xE000)),
    ),
    SaslprepCase(
      "a right-to-left text",
      "\u{0627}1\u{0628}",
      Ok("\u{0627}1\u{0628}"),
    ),
    SaslprepCase(
      "a right-to-left text with a left-to-right character",
      "\u{0627}a\u{0628}",
      Error(InvalidBidirectionalText),
    ),
    SaslprepCase(
      "a right-to-left character that does not start the text",
      "1\u{0627}",
      Error(InvalidBidirectionalText),
    ),
  ]
}
