//// A snapshot of a pool: its members, its holds and its queue.

import dream_postgres/driver/connection/event.{type ConnectError}
import gleam/option.{type Option}

/// The state of a pool at one moment.
pub type PoolStatus {
  PoolStatus(
    /// The number of connections that the pool keeps.
    size: Int,
    /// The connections that have a session with the server now.
    connected: Int,
    /// The connected connections that a checkout can take now.
    available: Int,
    /// The holds that run now.
    held: Int,
    /// The checkouts that wait in the queue.
    waiting: Int,
    /// The last connect error while no connection is connected, and
    /// `None` while one is, or while no connect has failed.
    last_connect_error: Option(ConnectError),
  )
}
