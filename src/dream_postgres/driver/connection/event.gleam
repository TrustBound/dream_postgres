//// What a connection process tells its subscriber: that it connected, lost its
//// connection, or could not connect.

import dream_postgres/driver/connection/outcome.{type Violation}
import dream_postgres/driver/login.{type LoginError}
import dream_postgres/driver/message.{type ProtocolError}
import dream_postgres/driver/transport.{
  type SendError, type SocketError, type TransportError,
}
import dream_postgres/internal/cell.{type ServerReport}

/// What the process tells its subscriber about the connection.
///
/// | Event | When the process sends it |
/// |---|---|
/// | `Connected` | Once, after its first login. A process from `start` sends it before `start` returns. |
/// | `ConnectFailed(error)` | After each failed first attempt of a process from `supervised`, until its first login. |
/// | `Disconnected(error)` | When the connection of a process that logged in is lost. |
/// | `ReconnectFailed(error)` | After each failed attempt to connect again after a loss. |
/// | `Reconnected` | When the process logged in again after a loss. |
///
/// Each process speaks only for itself: a process that replaces another
/// starts again with `Connected`.
pub type ConnectionEvent {
  /// The process connected and logged in for the first time.
  Connected
  /// An attempt of a supervised process to connect for the first time
  /// failed. The next one follows after the reconnect backoff.
  ConnectFailed(error: ConnectError)
  /// The connection is lost. The process connects again after the backoff.
  Disconnected(error: ConnectionEnd)
  /// An attempt to connect again failed. The next one follows after the
  /// backoff.
  ReconnectFailed(error: ConnectError)
  /// The process connected and logged in again.
  Reconnected
}

/// Why a connection was lost.
pub type LossReason {
  /// The socket closed or failed.
  SocketFailed(error: SocketError)
  /// The server read nothing for the send timeout, so the socket closed.
  ServerStoppedReading
  /// The deadline of the running request passed and its cancel did not
  /// end it in time, so the process closed the connection. The request
  /// whose deadline passed gets `DeadlinePassed(cancelled: False)`. The
  /// requests that waited behind it, and the ones that come while the
  /// process connects again, get this reason.
  ClosedAfterDeadline
}

/// Why a connection ended. The process connects again.
pub type ConnectionEnd {
  /// The connection is gone. `reason` says why.
  ConnectionLost(reason: LossReason)
  /// The server ended the session with a FATAL or PANIC error, for example
  /// `57P01` when an administrator stops it.
  ServerEndedConnection(report: ServerReport)
  /// The server broke the protocol.
  ProtocolViolation(violation: Violation)
}

/// Why the process could not connect and log in.
pub type ConnectError {
  /// The TCP connect or TLS failed.
  TransportRefused(error: TransportError)
  /// The socket failed during the login, for example because the server
  /// closed it.
  LoginSocketFailed(error: SocketError)
  /// A login message could not be sent, for example because the server
  /// read nothing of it for the send timeout.
  LoginSendFailed(error: SendError)
  /// The login settings require channel binding, and the connection has
  /// no TLS: its transport has `NoTls`, or `PreferTls` and a server that
  /// refused TLS. No login message went to the server.
  LoginRequiresTls
  /// The login failed, for example with the server's 28P01.
  LoginRefused(error: LoginError)
  /// The server sent bytes during the login that are not a valid message.
  LoginUndecodable(error: ProtocolError)
  /// The connect and the login took longer than the setup timeout.
  SetupTimedOut
  /// The process exited while it connected.
  SetupExited
}
