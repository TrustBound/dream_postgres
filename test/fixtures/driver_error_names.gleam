//// Short names of driver errors, for tests whose errors carry a whole
//// server report: the message, the file and the line of a report differ
//// from one PostgreSQL version to the next, its SQLSTATE does not.

import dream_postgres/driver/connection.{
  type CopyError, type DriverError, AppFailed, ConnectionLost, CopyNotRunning,
  CopyNotStarted, DeadlinePassed, DriverFailed, InvalidRequest,
  ProtocolViolation, ServerEndedConnection, ServerRefused,
}
import dream_postgres/driver/transport.{
  ConnectionReset, SendTimedOut, SocketClosed,
}
import gleam/result

/// The name of a driver error: the SQLSTATE of a server's refusal, or a
/// word for the kind of error.
pub fn driver_error_name(error: DriverError) -> String {
  case error {
    ServerRefused(report, _) -> report.code
    ServerEndedConnection(report) -> "ended " <> report.code
    ConnectionLost(SocketClosed) -> "lost closed"
    ConnectionLost(ConnectionReset) -> "lost reset"
    ConnectionLost(SendTimedOut) -> "lost send timeout"
    ConnectionLost(_other) -> "lost"
    ProtocolViolation(_) -> "violation"
    DeadlinePassed(cancelled: True) -> "deadline cancelled"
    DeadlinePassed(cancelled: False) -> "deadline"
    CopyNotStarted(_) -> "not started"
    CopyNotRunning -> "not running"
    InvalidRequest(_) -> "invalid"
    _ -> "another error"
  }
}

/// The name of a COPY error: `app` or `driver`, then the name of the
/// driver error.
pub fn copy_error_name(error: CopyError(DriverError)) -> String {
  case error {
    AppFailed(reason) -> "app " <> driver_error_name(reason)
    DriverFailed(error) -> "driver " <> driver_error_name(error)
  }
}

/// The name of each error of a result.
pub fn driver_error_names(
  answer: Result(value, DriverError),
) -> Result(value, String) {
  result.map_error(answer, driver_error_name)
}

/// The name of the COPY error of a result.
pub fn copy_error_names(
  answer: Result(value, CopyError(DriverError)),
) -> Result(value, String) {
  result.map_error(answer, copy_error_name)
}
