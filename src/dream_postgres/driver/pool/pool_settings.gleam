//// The settings of a pool, and the check that they are valid.

import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/pool/pool_event.{type PoolEvent}
import dream_postgres/driver/pool/pool_failure.{
  type StartError, InvalidHealthCheckInterval, InvalidSize,
}
import dream_postgres/driver/sink.{type Sink}
import gleam/bool.{guard}
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string

/// Everything a pool needs.
pub type PoolConfig(attachment) {
  PoolConfig(
    /// The settings of each connection process. The `events` sink of
    /// these settings gets every event of every connection process of the
    /// pool: a connection that replaces another starts with its own
    /// `Connected`.
    connection: ConnectionConfig,
    /// A value of the pool's user, kept by the pool process and read with
    /// `attachment`, also through a handle of the pool's name. The driver
    /// never looks inside it.
    attachment: attachment,
    /// Where the pool tells what each member does, in the order it changed
    /// its state: a hold sent after an event sees the state of that event.
    /// The sink's map runs in the pool's process. When it crashes, the
    /// pool drops the sink and sends no more events (see
    /// `driver/sink`).
    events: Option(Sink(PoolEvent)),
    /// How often the pool looks for connections to check. A connection is
    /// checked when it was free and unused for a whole interval. It must be
    /// 1 or more.
    health_check_interval_milliseconds: Int,
    /// The longest time that the query of a health check may take.
    health_check_deadline_milliseconds: Int,
    /// The longest time that the reset of a connection that comes back
    /// may take: the wait for its last request, then again for the
    /// rollback of a transaction that it left open.
    rollback_deadline_milliseconds: Int,
    /// How long the pool waits for the holds that run when its owner's
    /// process exits, before it closes the connections.
    shutdown_deadline_milliseconds: Int,
  )
}

/// The settings that the manager reads after it started.
pub type Settings(attachment) {
  Settings(
    size: Int,
    health_check_interval_milliseconds: Int,
    shutdown_deadline_milliseconds: Int,
    /// The events sink, `None` from the time its map crashed.
    events: Option(Sink(PoolEvent)),
    attachment: attachment,
    /// `False` for a pool from `supervised_without_database`, which has no
    /// member and refuses each hold with `NoDatabase`.
    has_database: Bool,
  )
}

pub fn check_settings(
  config: PoolConfig(attachment),
  size: Int,
) -> Result(Nil, StartError) {
  use <- guard(size < 1, Error(InvalidSize(size)))
  check_health_check_interval(config)
}

pub fn check_health_check_interval(
  config: PoolConfig(attachment),
) -> Result(Nil, StartError) {
  let interval = config.health_check_interval_milliseconds
  use <- guard(interval < 1, Error(InvalidHealthCheckInterval(interval)))
  Ok(Nil)
}

pub fn setting_refused(error: StartError) -> actor.StartError {
  actor.InitFailed(string.inspect(error))
}
