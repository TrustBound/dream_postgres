//// Tests for `dream_postgres/driver/transaction`: the transaction status
//// and the error that aborted a failed transaction, after each outcome.

import dream_postgres/driver/query.{
  type Failure, type Outcome, type ScriptFailure, CopyNotSupported, Outcome,
  ScriptFailure, ServerError,
}
import dream_postgres/driver/transaction.{
  aborting_error, new_tracker, track, track_script, track_step,
  transaction_status,
}
import dream_postgres/internal/cell.{
  type ServerReport, type TransactionStatus, Idle, InFailedTransaction,
  InTransaction, ServerReport,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/option.{None, Some}

/// The tests of the transaction tracker.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/transaction", [
    it("starts with the status Idle", fn() {
      // Act
      let status = transaction_status(new_tracker())

      // Assert
      status
      |> should
      |> be_equal(Idle)
      |> or_fail_with("Expected Idle")
    }),
    it("starts with no error", fn() {
      // Act
      let error = aborting_error(new_tracker())

      // Assert
      error
      |> should
      |> be_equal(None)
      |> or_fail_with("Expected no error")
    }),
    it("keeps the status of the last step", fn() {
      // Arrange
      let outcome = step_outcome(Ok(Nil), InTransaction)

      // Act
      let tracker = track_step(new_tracker(), outcome)

      // Assert
      transaction_status(tracker)
      |> should
      |> be_equal(InTransaction)
      |> or_fail_with("Expected InTransaction")
    }),
    it("keeps the error that aborted the transaction", fn() {
      // Arrange
      let outcome =
        step_outcome(Error(ServerError(division())), InFailedTransaction)

      // Act
      let tracker = track_step(new_tracker(), outcome)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(Some(division()))
      |> or_fail_with("Expected the division error")
    }),
    it("keeps the first error while the transaction stays failed", fn() {
      // Arrange
      let first =
        step_outcome(Error(ServerError(division())), InFailedTransaction)
      let second =
        step_outcome(Error(ServerError(aborted())), InFailedTransaction)

      // Act
      let tracker =
        new_tracker()
        |> track_step(first)
        |> track_step(second)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(Some(division()))
      |> or_fail_with("Expected the first error")
    }),
    it("clears the error when the transaction ends", fn() {
      // Arrange
      let failed =
        step_outcome(Error(ServerError(division())), InFailedTransaction)
      let rolled_back = step_outcome(Ok(Nil), Idle)

      // Act
      let tracker =
        new_tracker()
        |> track_step(failed)
        |> track_step(rolled_back)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(None)
      |> or_fail_with("Expected no error after the rollback")
    }),
    it("clears the error after a rollback to a savepoint", fn() {
      // Arrange
      let failed =
        step_outcome(Error(ServerError(division())), InFailedTransaction)
      let restored = step_outcome(Ok(Nil), InTransaction)

      // Act
      let tracker =
        new_tracker()
        |> track_step(failed)
        |> track_step(restored)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(None)
      |> or_fail_with("Expected no error in the restored transaction")
    }),
    it("keeps the error of a refused COPY", fn() {
      // Arrange
      let outcome =
        step_outcome(
          Error(CopyNotSupported(Some(division()))),
          InFailedTransaction,
        )

      // Act
      let tracker = track_step(new_tracker(), outcome)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(Some(division()))
      |> or_fail_with("Expected the error of the COPY")
    }),
    it("keeps the error that aborted a script", fn() {
      // Arrange
      let outcome =
        script_outcome(
          Error(ScriptFailure(completed: [], failure: ServerError(division()))),
          InFailedTransaction,
        )

      // Act
      let tracker = track_script(new_tracker(), outcome)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(Some(division()))
      |> or_fail_with("Expected the error of the script")
    }),
    it("keeps the status of a script that succeeded", fn() {
      // Arrange
      let outcome = script_outcome(Ok(Nil), InTransaction)

      // Act
      let tracker = track_script(new_tracker(), outcome)

      // Assert
      transaction_status(tracker)
      |> should
      |> be_equal(InTransaction)
      |> or_fail_with("Expected InTransaction")
    }),
    it("has no error for a failed transaction that no step saw fail", fn() {
      // Act
      let tracker = track(new_tracker(), InFailedTransaction, None)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_equal(None)
      |> or_fail_with("Expected no error")
    }),
  ])
}

fn step_outcome(
  result: Result(Nil, Failure),
  status: TransactionStatus,
) -> Outcome(Nil, Failure) {
  Outcome(result:, status:, asynchronous_messages: [])
}

fn script_outcome(
  result: Result(Nil, ScriptFailure),
  status: TransactionStatus,
) -> Outcome(Nil, ScriptFailure) {
  Outcome(result:, status:, asynchronous_messages: [])
}

fn division() -> ServerReport {
  report("22012", "division by zero")
}

fn aborted() -> ServerReport {
  report("25P02", "current transaction is aborted")
}

fn report(code: String, text: String) -> ServerReport {
  ServerReport(
    severity: "ERROR",
    localized_severity: "ERROR",
    code:,
    message: text,
    detail: None,
    hint: None,
    position: None,
    internal_position: None,
    internal_query: None,
    context: None,
    schema: None,
    table: None,
    column: None,
    data_type: None,
    constraint: None,
    file: None,
    line: None,
    routine: None,
    other_fields: [],
  )
}
