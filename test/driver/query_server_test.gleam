//// Runs the query steps on the driver servers of PostgreSQL 16 to 19, over
//// a SCRAM login on the transport: prepare, run, simple query, errors,
//// transactions, notices, parameter changes, notifications and COPY.

import dream_postgres/driver/query/extended_query.{
  start_prepare, start_prepare_and_run, start_run, step_prepare,
  step_prepare_and_run, step_run,
}
import dream_postgres/driver/query/simple_query.{
  start_simple_query, step_simple_query,
}
import dream_postgres/driver/query/step.{CopyNotSupported}
import dream_postgres/internal/cell.{
  Binary, BinaryFormat, ColumnDescription, CommandResult, Idle,
  InFailedTransaction, Null, ParameterDescription, StatementDescription, Text,
  TextFormat,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_query.{open_session}
import driver/servers.{type Server, driver_servers}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import matchers/extract_asynchronous_messages.{extract_asynchronous_messages}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_failure_code.{extract_failure_code}
import matchers/extract_next_session.{extract_next_session}
import matchers/extract_notice_texts.{extract_notice_texts}
import matchers/extract_notifications.{extract_notifications}
import matchers/extract_outcome_result.{extract_outcome_result}
import matchers/extract_parameter_changes.{extract_parameter_changes}
import matchers/extract_report_code.{extract_report_code}
import matchers/extract_session_step.{extract_session_step}
import matchers/extract_simple_query_tracker.{extract_simple_query_tracker}
import matchers/extract_statement_tags.{extract_statement_tags}
import matchers/extract_step_outcome.{extract_step_outcome}
import matchers/extract_tracked_state.{extract_tracked_state}

/// The tests of the query steps on each driver server.
pub fn tests() -> TestSuite {
  describe(
    "running queries on real servers",
    map(driver_servers(), server_tests),
  )
}

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("prepares a statement and describes it before any Bind", fn() {
      // Arrange
      let sql = "SELECT $1::int4 AS n, relname FROM pg_class WHERE relname = $2"
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(start_prepare("", sql, []), step_prepare)
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> be_equal(
        StatementDescription(
          parameters: [ParameterDescription(23), ParameterDescription(19)],
          columns: [
            ColumnDescription("n", 23, -1, 0, 0),
            ColumnDescription("relname", 19, -1, 1259, 2),
          ],
        ),
      )
      |> or_fail_with(
        "Expected the parameter types and the column descriptions",
      )
    }),
    it("runs a prepared statement with binary and text cells", fn() {
      // Arrange
      let sql = "SELECT $1::int4 AS n, relname FROM pg_class WHERE relname = $2"
      let parameters = [Binary(<<7:32>>), Text(<<"pg_class":utf8>>)]
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare("find_class", sql, []),
        step_prepare,
      )
      |> extract_next_session
      |> extract_session_step(
        start_run("find_class", parameters, [BinaryFormat, TextFormat]),
        step_run,
      )
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> be_equal(CommandResult(
        rows: [[Binary(<<7:32>>), Text(<<"pg_class":utf8>>)]],
        tag: "SELECT 1",
        count: 1,
      ))
      |> or_fail_with("Expected one row with a binary and a text cell")
    }),
    it("binds a NULL parameter", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare("is_null", "SELECT $1::text IS NULL", []),
        step_prepare,
      )
      |> extract_next_session
      |> extract_session_step(start_run("is_null", [Null], []), step_run)
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> extract_command_rows
      |> be_equal([[Text(<<"t":utf8>>)]])
      |> or_fail_with("Expected the text cell t")
    }),
    it("runs a simple query and gives one result for each statement", fn() {
      // Arrange
      let sql =
        "CREATE TEMP TABLE t (id int); INSERT INTO t VALUES (1), (2); SELECT id FROM t ORDER BY id"
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(start_simple_query(sql), step_simple_query)
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> extract_statement_tags
      |> be_equal([#("CREATE TABLE", 0), #("INSERT 0 2", 2), #("SELECT 2", 2)])
      |> or_fail_with("Expected three results with their tags and counts")
    }),
    it("gives the SQLSTATE of an error in the extended protocol", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare("", "SELECT * FROM no_such_table", []),
        step_prepare,
      )
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_error
      |> extract_report_code
      |> be_equal("42P01")
      |> or_fail_with("Expected 42P01")
    }),
    it("stays usable after an error in the extended protocol", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare("", "SELECT * FROM no_such_table", []),
        step_prepare,
      )
      |> extract_next_session
      |> extract_session_step(start_simple_query("SELECT 1"), step_simple_query)
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> extract_statement_tags
      |> be_equal([#("SELECT 1", 1)])
      |> or_fail_with("Expected SELECT 1 on the same connection after 42P01")
    }),
    it("keeps the error that aborted a transaction", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_simple_query_tracker(["BEGIN; SELECT 1/0"])
      |> extract_tracked_state
      |> be_equal(#(InFailedTransaction, Some("22012")))
      |> or_fail_with("Expected 22012 while the transaction failed")
    }),
    it("keeps the error that aborted a transaction until the rollback", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_simple_query_tracker(["BEGIN; SELECT 1/0", "ROLLBACK"])
      |> extract_tracked_state
      |> be_equal(#(Idle, None))
      |> or_fail_with("Expected no error after the rollback")
    }),
    it("gives back each notice", fn() {
      // Arrange
      let sql =
        "DO $$ BEGIN RAISE NOTICE 'first'; RAISE NOTICE 'second'; END $$"
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(start_simple_query(sql), step_simple_query)
      |> extract_step_outcome
      |> extract_asynchronous_messages
      |> extract_notice_texts
      |> be_equal(["first", "second"])
      |> or_fail_with("Expected both notices, in order")
    }),
    it("gives back each parameter change", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_simple_query("SET application_name = 'driver test'"),
        step_simple_query,
      )
      |> extract_step_outcome
      |> extract_asynchronous_messages
      |> extract_parameter_changes
      |> be_equal([#("application_name", "driver test")])
      |> or_fail_with("Expected the change of application_name")
    }),
    it("gives back each notification", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_simple_query("LISTEN jobs; NOTIFY jobs, 'done'"),
        step_simple_query,
      )
      |> extract_step_outcome
      |> extract_asynchronous_messages
      |> extract_notifications
      |> be_equal([#("jobs", "done")])
      |> or_fail_with("Expected the notification on jobs")
    }),
    it("refuses COPY TO STDOUT", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare_and_run("COPY (SELECT 1) TO STDOUT", [], [], []),
        step_prepare_and_run,
      )
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_error
      |> be_equal(CopyNotSupported(None))
      |> or_fail_with("Expected the refusal")
    }),
    it("refuses COPY TO STDOUT and stays usable", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_prepare_and_run("COPY (SELECT 1) TO STDOUT", [], [], []),
        step_prepare_and_run,
      )
      |> extract_next_session
      |> extract_session_step(start_simple_query("SELECT 1"), step_simple_query)
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> extract_statement_tags
      |> be_equal([#("SELECT 1", 1)])
      |> or_fail_with("Expected SELECT 1 after the refusal")
    }),
    it("refuses COPY FROM STDIN with the server's answer to CopyFail", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_simple_query("CREATE TEMP TABLE c (x int)"),
        step_simple_query,
      )
      |> extract_next_session
      |> extract_session_step(
        start_prepare_and_run("COPY c FROM STDIN", [], [], []),
        step_prepare_and_run,
      )
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_error
      |> extract_failure_code
      |> be_equal("57014")
      |> or_fail_with("Expected the server's answer to CopyFail")
    }),
    it("refuses COPY FROM STDIN and stays usable", fn() {
      // Arrange
      let session = open_session(server)

      // Act and Assert
      session
      |> should
      |> be_ok
      |> extract_session_step(
        start_simple_query("CREATE TEMP TABLE c (x int)"),
        step_simple_query,
      )
      |> extract_next_session
      |> extract_session_step(
        start_prepare_and_run("COPY c FROM STDIN", [], [], []),
        step_prepare_and_run,
      )
      |> extract_next_session
      |> extract_session_step(
        start_simple_query("SELECT count(*) FROM c"),
        step_simple_query,
      )
      |> extract_step_outcome
      |> extract_outcome_result
      |> be_ok
      |> extract_statement_tags
      |> be_equal([#("SELECT 1", 1)])
      |> or_fail_with("Expected a query after the refusal")
    }),
  ])
}
