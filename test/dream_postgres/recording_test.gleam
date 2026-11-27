//// The recording file format: what it writes, and what it reads back.

import dream_postgres/recording.{Recording}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/sample_recording

/// The recording file tests, with no database.
pub fn tests() -> TestSuite {
  describe("recording", [
    it("reads back every form it writes", fn() {
      // Arrange
      let written =
        sample_recording.every_form()
        |> recording.to_file_text

      // Act and assert
      recording.from_file_bytes(<<written:utf8>>)
      |> should
      |> be_ok()
      |> be_equal(sample_recording.every_form())
      |> or_fail_with("Expected the same recording back")
    }),
    it("writes an empty recording on four lines", fn() {
      // Act and assert
      recording.to_file_text(Recording(entries: []))
      |> should
      |> be_equal(
        "{\n  \"dream_postgres_recording\": 1,\n  \"entries\": []\n}\n",
      )
      |> or_fail_with("Expected the format number and no request")
    }),
    it("refuses a cell that is not hex", fn() {
      // Act and assert
      recording.from_file_bytes(<<
        "{\"dream_postgres_recording\": 1, \"entries\": [{\"key\": \"k\", \"script\": {\"sql\": \"SELECT 1\", \"outcome\": {\"answer\": {\"results\": [{\"count\": 1, \"rows\": [[{\"text\": \"zz\"}]], \"tag\": \"SELECT 1\"}]}}}}]}":utf8,
      >>)
      |> should
      |> be_error()
      |> or_fail_with("Expected the cell refused")
    }),
    it("refuses another format number", fn() {
      // Act and assert
      recording.from_file_bytes(<<
        "{\"dream_postgres_recording\": 2, \"entries\": []}":utf8,
      >>)
      |> should
      |> be_error()
      |> or_fail_with("Expected format 2 refused")
    }),
  ])
}
