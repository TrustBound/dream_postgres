//// The settings of a connection process.

import dream_postgres/driver/connection/backoff.{type Backoff}
import dream_postgres/driver/connection/event.{type ConnectionEvent}
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/login.{type LoginConfig}
import dream_postgres/driver/sink.{type Sink}
import dream_postgres/driver/transport.{type TransportConfig}
import dream_postgres/internal/cell.{type ServerReport}
import gleam/option.{type Option}

/// Everything a connection process needs.
pub type ConnectionConfig {
  ConnectionConfig(
    transport: TransportConfig,
    login: LoginConfig,
    /// The longest time for one setup: the TCP connect, TLS and the login
    /// together, from the start of the process and again for each
    /// reconnect. Each blocking step waits for its own timeout or for the
    /// time left in the setup, whichever is shorter: the transport's
    /// `connect_timeout_milliseconds` bounds each TCP connect, TLS answer
    /// and TLS handshake, and the up to three connects of `PreferTls` all
    /// fit inside the one setup. A setup that runs out of time fails with
    /// `SetupTimedOut`.
    setup_timeout_milliseconds: Int,
    /// The longest time that a cancel may take after a deadline passed:
    /// to open its connection, and for the server to stop the statement.
    /// After it, the connection is closed and replaced.
    cancel_timeout_milliseconds: Int,
    reconnect: Backoff,
    /// Where the process tells of each loss and each reconnect, for
    /// example to its pool.
    events: Option(Sink(ConnectionEvent)),
    /// Where the process sends each notification at once, as it arrives,
    /// also while the connection is idle, for example to the listener.
    /// With `None`, each notification goes with the next outcome.
    notifications: Option(Sink(Notification)),
    /// Where the process sends each notice at once, as it arrives: during
    /// the login, during any request, and while the connection is idle.
    /// An outcome holds only the notices of its own request, so a notice
    /// of a prepare, a COPY, a failed statement, a housekeeping statement
    /// or of idle time reaches the app only here. With `None`, those go
    /// to no one.
    ///
    /// The map of each of these three sinks runs in the connection
    /// process. When it crashes, the process drops that sink: it sets the
    /// field to `None` in its own settings, and sends nothing to it again
    /// (see `driver/sink`). A notification after a dropped
    /// `notifications` sink goes with the next outcome.
    notices: Option(Sink(ServerReport)),
    statements: StatementCaching,
  )
}

/// How the process prepares statements.
pub type StatementCaching {
  /// Each statement is prepared one time under a name, and runs again by
  /// that name. The cache keeps at most `limit` statements; the least
  /// recently used one is closed on the server.
  CacheStatements(limit: Int)
  /// Each statement is prepared again on the unnamed statement, for a
  /// pooler such as PgBouncer in transaction mode, where the next
  /// transaction may run on another server session.
  UnnamedStatements
}
