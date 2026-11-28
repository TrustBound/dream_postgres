//// The generated SqlState type against the errcodes.txt file of each
//// supported PostgreSQL version: a change to a file without a new run of
//// scripts/generate_sql_state.py fails here.

import dream_postgres/sql_state.{
  DeadlockDetected, IntegrityConstraintViolationClass, TransactionRollbackClass,
  UniqueViolation, Unlisted, UnlistedClass, UnlistedCode,
  WarningStringDataRightTruncation,
}
import dream_test/matchers.{
  be_empty, be_equal, be_error, be_ok, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/errcodes
import matchers/find_round_trip_mismatches.{find_round_trip_mismatches}
import matchers/find_unlisted_class_mismatches.{find_unlisted_class_mismatches}

pub fn tests() -> TestSuite {
  describe("sql_state", [
    group("each code of errcodes.txt", [
      it("round trips every named code of PostgreSQL 16", fn() {
        // Arrange
        let codes = errcodes.named_codes("16")

        // Act and assert
        codes
        |> should
        |> find_round_trip_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected every code of PostgreSQL 16 to round trip with its name and class",
        )
      }),
      it("round trips every named code of PostgreSQL 17", fn() {
        // Arrange
        let codes = errcodes.named_codes("17")

        // Act and assert
        codes
        |> should
        |> find_round_trip_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected every code of PostgreSQL 17 to round trip with its name and class",
        )
      }),
      it("round trips every named code of PostgreSQL 18", fn() {
        // Arrange
        let codes = errcodes.named_codes("18")

        // Act and assert
        codes
        |> should
        |> find_round_trip_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected every code of PostgreSQL 18 to round trip with its name and class",
        )
      }),
      it("round trips every named code of PostgreSQL 19", fn() {
        // Arrange
        let codes = errcodes.named_codes("19")

        // Act and assert
        codes
        |> should
        |> find_round_trip_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected every code of PostgreSQL 19 to round trip with its name and class",
        )
      }),
    ]),
    group("an unlisted code of each class", [
      it("gives the class of PostgreSQL 16 to an unlisted code", fn() {
        // Arrange
        let codes = errcodes.named_codes("16")

        // Act and assert
        codes
        |> should
        |> find_unlisted_class_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected an unlisted code of each class of PostgreSQL 16 to get its class",
        )
      }),
      it("gives the class of PostgreSQL 17 to an unlisted code", fn() {
        // Arrange
        let codes = errcodes.named_codes("17")

        // Act and assert
        codes
        |> should
        |> find_unlisted_class_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected an unlisted code of each class of PostgreSQL 17 to get its class",
        )
      }),
      it("gives the class of PostgreSQL 18 to an unlisted code", fn() {
        // Arrange
        let codes = errcodes.named_codes("18")

        // Act and assert
        codes
        |> should
        |> find_unlisted_class_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected an unlisted code of each class of PostgreSQL 18 to get its class",
        )
      }),
      it("gives the class of PostgreSQL 19 to an unlisted code", fn() {
        // Arrange
        let codes = errcodes.named_codes("19")

        // Act and assert
        codes
        |> should
        |> find_unlisted_class_mismatches()
        |> be_empty()
        |> or_fail_with(
          "Expected an unlisted code of each class of PostgreSQL 19 to get its class",
        )
      }),
    ]),
    group("from_string", [
      it("gives UniqueViolation for 23505", fn() {
        // Arrange
        let code = "23505"

        // Act
        let found = sql_state.parse_sql_state(code)

        // Assert
        found
        |> should
        |> be_equal(UniqueViolation)
        |> or_fail_with("Expected UniqueViolation for 23505")
      }),
      it("gives Unlisted for a code that no version has", fn() {
        // Arrange
        let code = "99X99"

        // Act
        let found = sql_state.parse_sql_state(code)

        // Assert
        found
        |> should
        |> be_equal(Unlisted("99X99"))
        |> or_fail_with("Expected Unlisted(\"99X99\") for 99X99")
      }),
      it("gives the code back for Unlisted", fn() {
        // Arrange
        let code = Unlisted("99X99")

        // Act
        let found = sql_state.sql_state_to_string(code)

        // Assert
        found
        |> should
        |> be_equal("99X99")
        |> or_fail_with("Expected the code 99X99 back from Unlisted")
      }),
    ]),
    group("name", [
      it("names a code whose name two codes share by its own name", fn() {
        // Arrange
        let code = WarningStringDataRightTruncation

        // Act
        let found = sql_state.sql_state_name(code)

        // Assert
        found
        |> should
        |> be_ok()
        |> be_equal("string_data_right_truncation")
        |> or_fail_with(
          "Expected the condition name string_data_right_truncation for 01004",
        )
      }),
      it("gives UnlistedCode for an Unlisted code", fn() {
        // Arrange
        let code = Unlisted("99X99")

        // Act
        let found = sql_state.sql_state_name(code)

        // Assert
        found
        |> should
        |> be_error()
        |> be_equal(UnlistedCode("99X99"))
        |> or_fail_with(
          "Expected UnlistedCode(\"99X99\") for Unlisted(\"99X99\")",
        )
      }),
    ]),
    group("class", [
      it("gives the class of a listed code", fn() {
        // Arrange
        let code = DeadlockDetected

        // Act
        let found = sql_state.sql_state_class(code)

        // Assert
        found
        |> should
        |> be_equal(TransactionRollbackClass)
        |> or_fail_with(
          "Expected TransactionRollbackClass for DeadlockDetected",
        )
      }),
      it("gives a listed class for an unlisted code of a listed class", fn() {
        // Arrange
        let code = Unlisted("23999")

        // Act
        let found = sql_state.sql_state_class(code)

        // Assert
        found
        |> should
        |> be_equal(IntegrityConstraintViolationClass)
        |> or_fail_with("Expected IntegrityConstraintViolationClass for 23999")
      }),
      it("gives UnlistedClass for a code of an unlisted class", fn() {
        // Arrange
        let code = Unlisted("99X99")

        // Act
        let found = sql_state.sql_state_class(code)

        // Assert
        found
        |> should
        |> be_equal(UnlistedClass("99"))
        |> or_fail_with("Expected UnlistedClass(\"99\") for 99X99")
      }),
    ]),
  ])
}
