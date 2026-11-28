//// Why a request to a connection process failed, for each kind of request.

import dream_postgres/driver/cell.{
  type ServerReport, type StatementDescription, type TransactionStatus,
}
import dream_postgres/driver/connection/event.{
  type ConnectError, type ConnectionEnd,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/message.{type EncodeError}
import gleam/option.{type Option}

/// A failure that any request can meet on its connection: the process is
/// gone, the deadline passed, or the connection ended.
pub type RequestFailure {
  /// The connection process is gone, for example after `stop`.
  ConnectionProcessDown
  /// The deadline passed before the result came. `cancelled` says whether
  /// the server confirmed a cancel. A request that waited behind another
  /// one, or a caller that got no answer in time, gets `False`.
  DeadlinePassed(cancelled: Bool)
  /// The connection ended. `end` says why.
  ConnectionEnded(end: ConnectionEnd)
}

/// Why `transaction_status`, `aborted_by` or `server_parameter` failed.
/// They read the state of the process only, so only the process can fail
/// them.
pub type ConnectionStateError {
  /// The connection process is gone.
  ProcessGone
  /// The connection process did not answer in time, for example because
  /// it is suspended.
  NoAnswerInTime
}

/// Why `settled_transaction_status` failed.
pub type SettleError {
  /// The request failed on its connection.
  SettleFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  SettleNotConnected(error: ConnectError)
}

/// Why `prepare` failed.
pub type PrepareError {
  /// The request failed on its connection.
  PrepareFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  PrepareNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  PrepareUnencodable(error: EncodeError)
  /// The server refused the statement. The connection stays usable.
  PrepareRefused(report: ServerReport, transaction_status: TransactionStatus)
}

/// Why `run` failed.
pub type RunError {
  /// The request failed on its connection.
  RunFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  RunNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  RunUnencodable(error: EncodeError)
  /// The server refused the statement. The connection stays usable.
  RunRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The statement is a COPY. COPY goes through `copy_from` and `copy_to`.
  /// The driver ended it, and the connection stays usable.
  RunCopyRefused
  /// The server made the driver prepare the statement again (SQLSTATE
  /// 0A000 or 26000, outside a transaction), and its description is not
  /// the cached one any more, for example after `ALTER TABLE`. The
  /// statement did not run: check it against `description` and run it
  /// again.
  RunStatementChanged(description: StatementDescription)
}

/// Why `run_simple_query` or `run_listener_simple_query` failed.
pub type SimpleQueryError {
  /// The request failed on its connection.
  SimpleQueryRequestFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  SimpleQueryNotConnected(error: ConnectError)
  /// The simple query cannot be written, for example SQL with a zero byte. No
  /// byte went to the server.
  SimpleQueryUnencodable(error: EncodeError)
  /// The server refused the first statement of the simple query, so no
  /// statement ran. The connection stays usable.
  SimpleQueryRefused(
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// A later statement of the simple query failed, after the ones in
  /// `completed` ran. `completed` is never empty: a failure of the first
  /// statement is `SimpleQueryRefused`.
  SimpleQueryFailed(
    completed: List(Outcome),
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// A statement of the simple query is a COPY. COPY goes through `copy_from`
  /// and `copy_to`. `completed` holds the statements that ran before it.
  SimpleQueryCopyRefused(completed: List(Outcome))
}

/// Why `run_housekeeping` or `run_housekeeping_simple_query` failed. A
/// housekeeping statement always encodes, runs on the unnamed statement
/// and is one statement that is not a COPY, so no case of an unencodable
/// statement, a changed statement or a later statement is here.
pub type HousekeepingError {
  /// The request failed on its connection.
  HousekeepingFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  HousekeepingNotConnected(error: ConnectError)
  /// The server refused the statement. The connection stays usable.
  HousekeepingRefused(
    report: ServerReport,
    transaction_status: TransactionStatus,
  )
  /// The server answered as no PostgreSQL server answers the statement:
  /// with a COPY, or with an error after a result. The connection stays
  /// usable.
  HousekeepingAnswerUnexpected
}

/// Why a `copy_from` or a `copy_to` failed.
pub type CopyError(reason) {
  /// The app's function failed with `reason`. The driver ended the COPY: a
  /// `COPY ... FROM STDIN` got a CopyFail, so the server stored no row of
  /// it, and the rest of a `COPY ... TO STDOUT` was read and dropped. The
  /// connection stays usable.
  AppFailed(reason: reason)
  /// The request failed on its connection.
  CopyFailed(failure: RequestFailure)
  /// A supervised process has not connected yet. `error` is why its last
  /// attempt failed. It tries again after the reconnect backoff.
  CopyNotConnected(error: ConnectError)
  /// The statement cannot be written, for example SQL with a zero byte.
  /// No byte went to the server.
  CopyUnencodable(error: EncodeError)
  /// The server refused the COPY or a row of it, for example a row that
  /// is not valid. The connection stays usable.
  CopyRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The SQL of `copy_from` did not start a `COPY ... FROM STDIN`, or the
  /// SQL of `copy_to` did not start a `COPY ... TO STDOUT`. `completed`
  /// says what ran:
  ///
  /// - `Some(outcome)`: the statement ran to its end. A statement that is
  ///   not a COPY gives its tag and its rows, as text cells, with no
  ///   columns, because the driver does not describe it. A
  ///   `COPY ... TO STDOUT` given to `copy_from` gives its tag, such as
  ///   `COPY 3`, and no rows: the driver read them and dropped them.
  /// - `None`: a `COPY ... FROM STDIN` given to `copy_to`. The driver ended
  ///   it with CopyFail, so the server stored no row. Inside a transaction,
  ///   the transaction failed.
  CopyNotStarted(completed: Option(Outcome))
}

/// Why `send_chunk` failed. The server takes no more data: give `Error`
/// from the function of `copy_from`.
pub type ChunkError {
  /// The request failed on its connection, or the deadline of the COPY
  /// passed.
  ChunkFailed(failure: RequestFailure)
  /// The COPY of the sender does not take data: it ended, for example
  /// because its `copy_from` returned already.
  ChunkCopyNotRunning
  /// The server refused the COPY, for example a row that is not valid.
  ChunkRefused(report: ServerReport, transaction_status: TransactionStatus)
}

/// Why the process refuses a request that it does not run: the link is
/// down, or the deadline of the request passed while it waited.
pub type Refusal {
  RefusedWithFailure(failure: RequestFailure)
  RefusedNotConnected(error: ConnectError)
}
