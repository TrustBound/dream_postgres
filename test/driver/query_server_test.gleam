//// Runs the query steps on the driver servers of PostgreSQL 16 to 19, over
//// a SCRAM login on the transport: prepare, run, simple query, errors,
//// transactions, notices, parameter changes, notifications and COPY.

import dream_postgres/driver/query.{
  type AsynchronousMessage, type Failure, type Outcome, type ScriptFailure,
  type StatementResult, CopyNotSupported, Notice, Notification, ParameterChanged,
  ServerError, start_prepare, start_prepare_and_run, start_run,
  start_simple_query, step_prepare, step_prepare_and_run, step_run,
  step_simple_query,
}
import dream_postgres/driver/transaction.{
  aborting_error, new_tracker, track_script, transaction_status,
}
import dream_postgres/internal/cell.{
  type CommandResult, type ServerReport, Binary, BinaryFormat, ColumnDescription,
  CommandResult, Idle, InFailedTransaction, Null, ParameterDescription,
  StatementDescription, Text, TextFormat,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_query.{
  type QueryFailure, type Session, run_step, with_session,
}
import driver/servers.{type Server, driver_servers}
import gleam/int.{to_string}
import gleam/list.{filter_map, map}
import gleam/option.{type Option, None, Some}
import gleam/result.{try}

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
      check_prepare(server)
    }),
    it("runs a prepared statement with binary and text cells", fn() {
      check_run(server)
    }),
    it("binds a NULL parameter", fn() { check_null(server) }),
    it("runs a script and gives one result for each statement", fn() {
      check_script(server)
    }),
    it("stays usable after an error in the extended protocol", fn() {
      check_usable_after_error(server)
    }),
    it("keeps the error that aborted a transaction until the rollback", fn() {
      check_aborting_error(server)
    }),
    it("gives back each notice", fn() { check_notices(server) }),
    it("gives back each parameter change", fn() {
      check_parameter_change(server)
    }),
    it("gives back each notification", fn() { check_notification(server) }),
    it("refuses COPY TO STDOUT and stays usable", fn() {
      check_copy_out(server)
    }),
    it("refuses COPY FROM STDIN and stays usable", fn() {
      check_copy_in(server)
    }),
  ])
}

// Steps -----------------------------------------------------------------------

fn script(
  session: Session,
  sql: String,
) -> Result(
  #(Outcome(List(StatementResult), ScriptFailure), Session),
  QueryFailure,
) {
  run_step(session, start_simple_query(sql), step_simple_query)
}

fn prepare_and_run(
  session: Session,
  sql: String,
) -> Result(#(Outcome(StatementResult, Failure), Session), QueryFailure) {
  run_step(
    session,
    start_prepare_and_run(sql, [], [], []),
    step_prepare_and_run,
  )
}

fn tags(outcome: Outcome(List(StatementResult), ScriptFailure)) {
  outcome.result |> result.map(map(_, tag_and_count))
}

fn tag_and_count(statement: StatementResult) -> #(String, Int) {
  #(statement.result.tag, statement.result.count)
}

fn failure_code(failure: Failure) -> Option(String) {
  case failure {
    ServerError(report) -> Some(report.code)
    CopyNotSupported(Some(report)) -> Some(report.code)
    CopyNotSupported(None) -> None
  }
}

// Tests -----------------------------------------------------------------------

fn check_prepare(server: Server) {
  // Arrange
  let sql = "SELECT $1::int4 AS n, relname FROM pg_class WHERE relname = $2"

  // Act
  let description = {
    use session <- with_session(server)
    use #(outcome, _session) <- try(run_step(
      session,
      start_prepare("", sql, []),
      step_prepare,
    ))
    Ok(outcome.result)
  }

  // Assert
  description
  |> should
  |> be_equal(
    Ok(
      Ok(
        StatementDescription(
          parameters: [ParameterDescription(23), ParameterDescription(19)],
          columns: [
            ColumnDescription("n", 23, -1, 0, 0),
            ColumnDescription("relname", 19, -1, 1259, 2),
          ],
        ),
      ),
    ),
  )
  |> or_fail_with("Expected the parameter types and the column descriptions")
}

fn check_run(server: Server) {
  // Arrange
  let sql = "SELECT $1::int4 AS n, relname FROM pg_class WHERE relname = $2"
  let parameters = [Binary(<<7:32>>), Text(<<"pg_class":utf8>>)]

  // Act
  let rows = {
    use session <- with_session(server)
    use #(_prepared, session) <- try(run_step(
      session,
      start_prepare("find_class", sql, []),
      step_prepare,
    ))
    use #(outcome, _session) <- try(run_step(
      session,
      start_run("find_class", parameters, [BinaryFormat, TextFormat]),
      step_run,
    ))
    Ok(outcome.result)
  }

  // Assert
  rows
  |> should
  |> be_equal(
    Ok(
      Ok(CommandResult(
        rows: [[Binary(<<7:32>>), Text(<<"pg_class":utf8>>)]],
        tag: "SELECT 1",
        count: 1,
      )),
    ),
  )
  |> or_fail_with("Expected one row with a binary and a text cell")
}

fn check_null(server: Server) {
  // Act
  let rows = {
    use session <- with_session(server)
    use #(_prepared, session) <- try(run_step(
      session,
      start_prepare("is_null", "SELECT $1::text IS NULL", []),
      step_prepare,
    ))
    use #(outcome, _session) <- try(run_step(
      session,
      start_run("is_null", [Null], []),
      step_run,
    ))
    Ok(outcome.result |> result.map(command_rows))
  }

  // Assert
  rows
  |> should
  |> be_equal(Ok(Ok([[Text(<<"t":utf8>>)]])))
  |> or_fail_with("Expected the text cell t")
}

fn command_rows(command: CommandResult) {
  command.rows
}

fn check_script(server: Server) {
  // Arrange
  let sql =
    "CREATE TEMP TABLE t (id int); INSERT INTO t VALUES (1), (2); SELECT id FROM t ORDER BY id"

  // Act
  let results = {
    use session <- with_session(server)
    use #(outcome, _session) <- try(script(session, sql))
    Ok(tags(outcome))
  }

  // Assert
  results
  |> should
  |> be_equal(
    Ok(Ok([#("CREATE TABLE", 0), #("INSERT 0 2", 2), #("SELECT 2", 2)])),
  )
  |> or_fail_with("Expected three results with their tags and counts")
}

fn check_usable_after_error(server: Server) {
  // Act
  let answers = {
    use session <- with_session(server)
    use #(failed, session) <- try(run_step(
      session,
      start_prepare("", "SELECT * FROM no_such_table", []),
      step_prepare,
    ))
    use #(next, _session) <- try(script(session, "SELECT 1"))
    Ok(#(failed.result |> result.map_error(failure_code), tags(next)))
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error(Some("42P01")), Ok([#("SELECT 1", 1)]))))
  |> or_fail_with("Expected 42P01, then SELECT 1 on the same connection")
}

fn check_aborting_error(server: Server) {
  // Act
  let states = {
    use session <- with_session(server)
    use #(failed, session) <- try(script(session, "BEGIN; SELECT 1/0"))
    let aborted = track_script(new_tracker(), failed)
    use #(rolled_back, _session) <- try(script(session, "ROLLBACK"))
    let ended = track_script(aborted, rolled_back)
    Ok(#(tracked(aborted), tracked(ended)))
  }

  // Assert
  states
  |> should
  |> be_equal(Ok(#(#(InFailedTransaction, Some("22012")), #(Idle, None))))
  |> or_fail_with("Expected 22012 while the transaction failed, then nothing")
}

fn tracked(tracker: transaction.TransactionTracker) {
  #(transaction_status(tracker), aborting_error(tracker) |> option.map(code))
}

fn code(report: ServerReport) -> String {
  report.code
}

fn check_notices(server: Server) {
  // Arrange
  let sql = "DO $$ BEGIN RAISE NOTICE 'first'; RAISE NOTICE 'second'; END $$"

  // Act
  let notices = {
    use session <- with_session(server)
    use #(outcome, _session) <- try(script(session, sql))
    Ok(filter_map(outcome.asynchronous_messages, notice_text))
  }

  // Assert
  notices
  |> should
  |> be_equal(Ok(["first", "second"]))
  |> or_fail_with("Expected both notices, in order")
}

fn notice_text(message: AsynchronousMessage) -> Result(String, Nil) {
  case message {
    Notice(report) -> Ok(report.message)
    _ -> Error(Nil)
  }
}

fn check_parameter_change(server: Server) {
  // Act
  let changes = {
    use session <- with_session(server)
    use #(outcome, _session) <- try(script(
      session,
      "SET application_name = 'driver test'",
    ))
    Ok(filter_map(outcome.asynchronous_messages, parameter_change))
  }

  // Assert
  changes
  |> should
  |> be_equal(Ok([#("application_name", "driver test")]))
  |> or_fail_with("Expected the change of application_name")
}

fn parameter_change(
  message: AsynchronousMessage,
) -> Result(#(String, String), Nil) {
  case message {
    ParameterChanged(name, value) -> Ok(#(name, value))
    _ -> Error(Nil)
  }
}

fn check_notification(server: Server) {
  // Act
  let notifications = {
    use session <- with_session(server)
    use #(outcome, _session) <- try(script(
      session,
      "LISTEN jobs; NOTIFY jobs, 'done'",
    ))
    Ok(filter_map(outcome.asynchronous_messages, notification))
  }

  // Assert
  notifications
  |> should
  |> be_equal(Ok([#("jobs", "done")]))
  |> or_fail_with("Expected the notification on jobs")
}

fn notification(
  message: AsynchronousMessage,
) -> Result(#(String, String), Nil) {
  case message {
    Notification(_process_id, channel, payload) -> Ok(#(channel, payload))
    _ -> Error(Nil)
  }
}

fn check_copy_out(server: Server) {
  // Act
  let answers = {
    use session <- with_session(server)
    use #(refused, session) <- try(prepare_and_run(
      session,
      "COPY (SELECT 1) TO STDOUT",
    ))
    use #(next, _session) <- try(script(session, "SELECT 1"))
    Ok(#(refused.result |> result.map_error(failure_code), tags(next)))
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error(None), Ok([#("SELECT 1", 1)]))))
  |> or_fail_with("Expected the refusal, then SELECT 1")
}

fn check_copy_in(server: Server) {
  // Act
  let answers = {
    use session <- with_session(server)
    use #(_created, session) <- try(script(
      session,
      "CREATE TEMP TABLE c (x int)",
    ))
    use #(refused, session) <- try(prepare_and_run(session, "COPY c FROM STDIN"))
    use #(next, _session) <- try(script(session, "SELECT count(*) FROM c"))
    Ok(#(refused.result |> result.map_error(failure_code), tags(next)))
  }

  // Assert
  answers
  |> should
  |> be_equal(Ok(#(Error(Some("57014")), Ok([#("SELECT 1", 1)]))))
  |> or_fail_with("Expected the server's answer to CopyFail, then a query")
}
