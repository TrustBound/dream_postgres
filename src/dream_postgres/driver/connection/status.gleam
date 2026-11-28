//// What a caller reads of the connection without a request to the server: its
//// transaction status and its server parameters.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/connection/call.{type Connection, request, snapshot}
import dream_postgres/driver/connection/process_message.{
  type Snapshot, SettledStatusRequest,
}
import dream_postgres/driver/connection/request_failure.{
  type ConnectionStateError, type SettleError, SettleFailed,
}
import gleam/dict
import gleam/option.{type Option}
import gleam/result

/// The transaction status after the last request.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
///
/// ## Parameters
///
/// - `connection`: the connection
///
/// ## Returns
///
/// - `Ok(TransactionStatus)`: idle, in a transaction, or in a failed one
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn transaction_status(
  connection: Connection,
) -> Result(TransactionStatus, ConnectionStateError) {
  snapshot(connection) |> result.map(snapshot_status)
}

/// The transaction status after the running request and every request
/// that waits before this one finished, for example the requests of a
/// caller that stopped waiting. A pool reads it before it hands the
/// connection to the next holder.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `deadline_milliseconds`: the longest time to wait
///
/// ## Returns
///
/// - `Ok(TransactionStatus)`: idle, in a transaction, or in a failed one
/// - `Error(SettleNotConnected(error))`: a supervised process has not
///   connected yet
/// - `Error(SettleFailed(failure))`: the connection is lost, the process
///   is gone, or the deadline passed
pub fn settled_transaction_status(
  connection: Connection,
  deadline_milliseconds: Int,
) -> Result(TransactionStatus, SettleError) {
  request(connection, SettledStatusRequest, deadline_milliseconds, SettleFailed)
}

fn snapshot_status(snapshot: Snapshot) -> TransactionStatus {
  snapshot.transaction_status
}

/// The report of the statement that failed the transaction.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
///
/// ## Parameters
///
/// - `connection`: the connection
///
/// ## Returns
///
/// - `Ok(Some(report))`: while the transaction status is
///   `InFailedTransaction`
/// - `Ok(None)`: in any other status. It clears when the status is idle
///   again.
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn aborted_by(
  connection: Connection,
) -> Result(Option(ServerReport), ConnectionStateError) {
  snapshot(connection) |> result.map(snapshot_aborted_by)
}

fn snapshot_aborted_by(snapshot: Snapshot) -> Option(ServerReport) {
  snapshot.aborted_by
}

/// A run-time parameter that the server reported, for example
/// `server_version` or `TimeZone`, with its latest value.
///
/// The caller waits at most the reply margin of the connection: its cancel
/// timeout plus its setup timeout. The process reads its own state, so it
/// answers at once, except while it reconnects: a reconnect blocks it for
/// at most the setup timeout.
///
/// ## Parameters
///
/// - `connection`: the connection
/// - `name`: the parameter's name
///
/// ## Returns
///
/// - `Ok(Some(value))`: the latest value
/// - `Ok(None)`: the server reported no parameter of that name
/// - `Error(ProcessGone)`: the process is gone
/// - `Error(NoAnswerInTime)`: the process did not answer within the reply
///   margin
pub fn server_parameter(
  connection: Connection,
  name: String,
) -> Result(Option(String), ConnectionStateError) {
  snapshot(connection) |> result.map(parameter_of(_, name))
}

fn parameter_of(snapshot: Snapshot, name: String) -> Option(String) {
  dict.get(snapshot.parameters, name) |> option.from_result
}
