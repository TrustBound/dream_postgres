//// Why a pool does not start, why a hold fails, and why a call to a pool that
//// is down fails.

import dream_postgres/driver/connection/event.{type ConnectError}
import gleam/otp/actor

/// Why a pool did not start.
pub type StartError {
  /// The size is below 1.
  InvalidSize(size: Int)
  /// The health check interval is below 1 millisecond.
  InvalidHealthCheckInterval(milliseconds: Int)
  /// The manager process did not start.
  PoolProcessStartFailed(error: actor.StartError)
}

/// Why a hold got no connection.
pub type HoldError {
  /// No connection was free before the deadline.
  HoldDeadlinePassed
  /// No connection is connected, and the last connect failed with this
  /// error.
  ConnectFailed(error: ConnectError)
  /// The pool stops, or it is gone.
  PoolStopped
  /// The pool has no database: it started with
  /// `supervised_without_database`, so it has no connection to hold.
  NoDatabase
}

/// Why a request that only reads from the pool failed: no pool process
/// runs. The pool is gone, or no pool runs under the name now, for example
/// while its supervisor starts it again.
pub type PoolNotRunning {
  PoolNotRunning
}
