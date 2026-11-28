//// Tests for `dream_postgres/driver/transaction`: the transaction status
//// and the error that aborted a failed transaction, after each outcome.

import dream_postgres/driver/query/step.{
  type Failure, type Outcome, type SimpleQueryFailure, CopyNotSupported, Outcome,
  ServerError, SimpleQueryFailure,
}
import dream_postgres/driver/transaction.{
  aborting_error, new_tracker, track, track_simple_query, track_step,
  transaction_status,
}
import dream_postgres/internal/cell.{
  type ServerReport, type TransactionStatus, Idle, InFailedTransaction,
  InTransaction,
}
import dream_test/matchers.{be_equal, be_none, be_some, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/server_report.{server_report}
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
      |> be_none
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
      |> be_some
      |> be_equal(division())
      |> or_fail_with("Expected the division error")
    }),
    it("keeps the first error while the transaction stays failed", fn() {
      // Arrange
      let first =
        step_outcome(Error(ServerError(division())), InFailedTransaction)
      let second =
        step_outcome(
          Error(
            ServerError(server_report(
              "ERROR",
              "25P02",
              "current transaction is aborted",
            )),
          ),
          InFailedTransaction,
        )

      // Act
      let tracker =
        new_tracker()
        |> track_step(first)
        |> track_step(second)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_some
      |> be_equal(division())
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
      |> be_none
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
      |> be_none
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
      |> be_some
      |> be_equal(division())
      |> or_fail_with("Expected the error of the COPY")
    }),
    it("keeps the error that aborted a simple query", fn() {
      // Arrange
      let outcome =
        simple_query_outcome(
          Error(SimpleQueryFailure(
            completed: [],
            failure: ServerError(division()),
          )),
          InFailedTransaction,
        )

      // Act
      let tracker = track_simple_query(new_tracker(), outcome)

      // Assert
      aborting_error(tracker)
      |> should
      |> be_some
      |> be_equal(division())
      |> or_fail_with("Expected the error of the simple query")
    }),
    it("keeps the status of a simple query that succeeded", fn() {
      // Arrange
      let outcome = simple_query_outcome(Ok(Nil), InTransaction)

      // Act
      let tracker = track_simple_query(new_tracker(), outcome)

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
      |> be_none
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

fn simple_query_outcome(
  result: Result(Nil, SimpleQueryFailure),
  status: TransactionStatus,
) -> Outcome(Nil, SimpleQueryFailure) {
  Outcome(result:, status:, asynchronous_messages: [])
}

fn division() -> ServerReport {
  server_report("ERROR", "22012", "division by zero")
}
