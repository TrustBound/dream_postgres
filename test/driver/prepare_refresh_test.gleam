//// Proves that `describe_current` gives the server's description now,
//// also for a statement that the cache holds: after a schema change it
//// shows the new columns, a run after it works, and an unchanged schema
//// gives the same description. A prepare from the cache gives the stale
//// description, and the run after it gives `RunStatementChanged`. On each
//// driver server.

import dream_postgres/driver/connection/request_failure.{
  ConnectionProcessDown, PrepareFailed,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_prepare.{
  describe_on_stopped_connection, prepare_and_run_after_change,
  prepare_around_change, run_after_changed_prepare,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import gleam/int.{to_string}
import gleam/list.{append, map}
import matchers/be_equal_parts.{be_equal_parts}
import matchers/extract_changed_column_names.{extract_changed_column_names}
import matchers/extract_column_names.{extract_column_names}
import matchers/extract_column_type_ids.{extract_column_type_ids}
import matchers/extract_description_columns.{extract_description_columns}
import matchers/extract_second_of_pair.{extract_second_of_pair}
import matchers/extract_stale_prepared.{extract_stale_prepared}
import matchers/extract_stale_run.{extract_stale_run}

/// The tests of a prepare after a schema change.
pub fn tests() -> TestSuite {
  suite_of(driver_servers())
}

fn suite_of(servers: List(Server)) -> TestSuite {
  describe(
    "a description after a schema change",
    append(map(servers, server_tests), [stopped_tests()]),
  )
}

fn stopped_tests() {
  group("of a connection that stopped", [
    it("gives PrepareFailed with ConnectionProcessDown", fn() {
      // Act
      let described = describe_on_stopped_connection(first_driver_server.port)

      // Assert
      described
      |> should
      |> be_ok
      |> be_equal(Error(PrepareFailed(ConnectionProcessDown)))
      |> or_fail_with("Expected PrepareFailed(ConnectionProcessDown)")
    }),
  ])
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
    it("prepare gives the cached description after DROP COLUMN", fn() {
      // Act
      let outcome =
        prepare_and_run_after_change(
          server.port,
          "ALTER TABLE prepared_after_change DROP COLUMN c",
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_stale_prepared
      |> extract_description_columns
      |> extract_column_names
      |> be_equal(["a", "b", "c"])
      |> or_fail_with("Expected the cached columns a, b and c")
    }),
    it("a run after that prepare gives RunStatementChanged", fn() {
      // Act
      let outcome =
        prepare_and_run_after_change(
          server.port,
          "ALTER TABLE prepared_after_change DROP COLUMN c",
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_stale_run
      |> be_error
      |> extract_changed_column_names
      |> be_equal(["a", "b"])
      |> or_fail_with("Expected RunStatementChanged with the columns a and b")
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
