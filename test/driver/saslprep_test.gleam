//// Tests for `dream_postgres/driver/saslprep`: the examples of RFC 4013
//// section 3, and each rule of the profile.

import dream_postgres/driver/saslprep.{
  type SaslprepError, EmptyAfterMapping, InvalidBidirectionalText,
  ProhibitedCodePoint, saslprep,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}

/// The tests of SASLprep.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/saslprep", [
    group("the examples of RFC 4013 section 3", rfc_tests()),
    group("each rule of the profile", rule_tests()),
  ])
}

fn prepared_test(name: String, input: String, expected: String) {
  it(name, fn() {
    // Act
    let prepared = saslprep(input)

    // Assert
    prepared
    |> should
    |> be_ok
    |> be_equal(expected)
    |> or_fail_with("Expected the SASLprep result of " <> name)
  })
}

fn refused_test(name: String, input: String, expected: SaslprepError) {
  it(name, fn() {
    // Act
    let prepared = saslprep(input)

    // Assert
    prepared
    |> should
    |> be_error
    |> be_equal(expected)
    |> or_fail_with("Expected the SASLprep result of " <> name)
  })
}

fn rfc_tests() {
  [
    prepared_test("1: SOFT HYPHEN mapped to nothing", "I\u{00AD}X", "IX"),
    prepared_test("2: no transformation", "user", "user"),
    prepared_test("3: case preserved", "USER", "USER"),
    prepared_test("4: output is NFKC", "\u{00AA}", "a"),
    prepared_test("5: output is NFKC, matches 1", "\u{2168}", "IX"),
    refused_test(
      "6: prohibited character",
      "\u{0007}",
      ProhibitedCodePoint(0x07),
    ),
    refused_test(
      "7: bidirectional check",
      "\u{0627}\u{0031}",
      InvalidBidirectionalText,
    ),
  ]
}

fn rule_tests() {
  [
    prepared_test("a non-ASCII space becomes SPACE", "a\u{00A0}b", "a b"),
    refused_test(
      "a text that the mapping empties",
      "\u{00AD}\u{200D}",
      EmptyAfterMapping,
    ),
    refused_test("the empty text", "", EmptyAfterMapping),
    refused_test(
      "a code point that Unicode 3.2 does not assign",
      "a\u{0221}",
      ProhibitedCodePoint(0x0221),
    ),
    refused_test(
      "a private use character",
      "\u{E000}",
      ProhibitedCodePoint(0xE000),
    ),
    prepared_test(
      "a right-to-left text",
      "\u{0627}1\u{0628}",
      "\u{0627}1\u{0628}",
    ),
    refused_test(
      "a right-to-left text with a left-to-right character",
      "\u{0627}a\u{0628}",
      InvalidBidirectionalText,
    ),
    refused_test(
      "a right-to-left character that does not start the text",
      "1\u{0627}",
      InvalidBidirectionalText,
    ),
  ]
}
