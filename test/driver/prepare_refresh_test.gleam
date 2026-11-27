//// Proves that a prepare gives the server's description now, also for a
//// statement that the cache holds: after a schema change it shows the
//// new columns, a run after it works, and an unchanged schema gives the
//// same description. On each driver server.

import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_prepare.{prepare_around_change, run_after_changed_prepare}
import driver/servers.{type Server, driver_servers}
import gleam/int.{to_string}
import gleam/list.{map}
import matchers/be_equal_parts.{be_equal_parts}
import matchers/extract_column_names.{extract_column_names}
import matchers/extract_column_type_ids.{extract_column_type_ids}
import matchers/extract_description_columns.{extract_description_columns}
import matchers/extract_second_of_pair.{extract_second_of_pair}

/// The tests of a prepare after a schema change.
pub fn tests() -> TestSuite {
  suite_of(driver_servers())
}

fn suite_of(servers: List(Server)) -> TestSuite {
  describe("a prepare after a schema change", map(servers, server_tests))
}

fn server_tests(server: Server) {
  group("on PostgreSQL " <> to_string(server.version), [
    it("shows the new type after ALTER COLUMN TYPE", fn() {
      // Act
      let descriptions =
        prepare_around_change(
          server.port,
          "ALTER TABLE prepared_after_change ALTER COLUMN b TYPE text",
        )

      // Assert
      descriptions
      |> should
      |> be_ok
      |> extract_second_of_pair
      |> extract_description_columns
      |> extract_column_type_ids
      |> be_equal([23, 25, 23])
      |> or_fail_with("Expected the column b as text, OID 25")
    }),
    it("shows a dropped column gone after DROP COLUMN", fn() {
      // Act
      let descriptions =
        prepare_around_change(
          server.port,
          "ALTER TABLE prepared_after_change DROP COLUMN c",
        )

      // Assert
      descriptions
      |> should
      |> be_ok
      |> extract_second_of_pair
      |> extract_description_columns
      |> extract_column_names
      |> be_equal(["a", "b"])
      |> or_fail_with("Expected the columns a and b")
    }),
    it("runs the statement after the prepare that saw the change", fn() {
      // Act
      let ran =
        run_after_changed_prepare(
          server.port,
          "ALTER TABLE prepared_after_change DROP COLUMN c",
        )

      // Assert
      ran
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the run to work, with no StatementChanged")
    }),
    it("gives the same description for an unchanged schema", fn() {
      // Act
      let descriptions = prepare_around_change(server.port, "SELECT 1")

      // Assert
      descriptions
      |> should
      |> be_ok
      |> be_equal_parts
      |> extract_description_columns
      |> extract_column_names
      |> be_equal(["a", "b", "c"])
      |> or_fail_with("Expected the same description twice")
    }),
  ])
}
