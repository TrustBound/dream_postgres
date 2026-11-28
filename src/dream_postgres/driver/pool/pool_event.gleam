//// What a pool tells its subscriber about its connections and its holds.

import dream_postgres/driver/connection/event.{
  type ConnectError, type ConnectionEnd,
}
import dream_postgres/driver/pool/pool_failure.{type HoldError}

/// What the pool tells its subscriber about its members. Each event names
/// the member's slot: its place in the pool.
pub type PoolEvent {
  /// A new connection process of the member connected and logged in.
  MemberConnected(slot: Int)
  /// The member's connection lost its session, for `error`. Its process
  /// connects again.
  MemberDisconnected(slot: Int, error: ConnectionEnd)
  /// The member's connection connected and logged in again after a loss.
  MemberReconnected(slot: Int)
  /// A start or a reconnect of the member's connection failed.
  MemberConnectFailed(slot: Int, error: ConnectError)
  /// The member stopped its connection process, after a failed rollback or
  /// health check, or the process exited. A new one starts.
  MemberReplacing(slot: Int)
  /// The member's connection is free for the next hold: connected, idle
  /// outside any transaction, and held by no one.
  MemberFree(slot: Int)
  /// A hold found no free connection and waits in the queue, which now has
  /// `waiting` holds.
  HoldWaiting(waiting: Int)
  /// The pool handed the member's connection to a hold.
  MemberHeld(slot: Int)
  /// The hold of the member's connection ended, and the member resets it.
  MemberReturned(slot: Int)
  /// The pool refused a hold with `error`.
  HoldRefused(error: HoldError)
  /// The pool started to stop: it refuses each new hold, and closes when
  /// the last hold ended.
  PoolStopping
}
