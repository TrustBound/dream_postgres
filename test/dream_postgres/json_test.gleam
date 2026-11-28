//// The JSON document type.

import dream_postgres/json
import dream_test/matchers.{be_equal, be_ok, be_true, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/dynamic/decode
import gleam/json as gleam_json
import gleam/result

pub fn tests() -> TestSuite {
  describe("json", [
    it("makes a document from a gleam/json value", fn() {
      // Arrange
      let value = gleam_json.object([#("a", gleam_json.int(1))])

      // Act
      let text = json.gleam_json_to_json(value) |> json.json_to_string

      // Assert
      text
      |> should
      |> be_equal("{\"a\":1}")
      |> or_fail_with("Expected the text of the value")
    }),
    it("makes a document from valid JSON text", fn() {
      // Act
      let text = json.parse_json("[1, 2]") |> result.map(json.json_to_string)

      // Assert
      text
      |> should
      |> be_ok()
      |> be_equal("[1, 2]")
      |> or_fail_with("Expected the text, unchanged")
    }),
    it("refuses text that is not JSON", fn() {
      // Act
      let refused = json.parse_json("[1,") |> result.is_error

      // Assert
      refused
      |> should
      |> be_true()
      |> or_fail_with("Expected an error for text that is not JSON")
    }),
    it("decodes a document", fn() {
      // Arrange
      let document = json.gleam_json_to_json(gleam_json.int(7))

      // Act
      let value = json.decode_json(document, decode.int)

      // Assert
      value
      |> should
      |> be_ok()
      |> be_equal(7)
      |> or_fail_with("Expected 7")
    }),
  ])
}
