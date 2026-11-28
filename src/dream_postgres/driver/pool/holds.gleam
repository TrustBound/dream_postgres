//// A hold from the caller's side: the check out, the check in, and the reads
//// that need no connection.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/pool/pool_failure.{
  type HoldError, type PoolNotRunning, PoolNotRunning, PoolStopped,
}
import dream_postgres/driver/pool/pool_message.{
  type Lease, type Pool, type PoolMessage, AttachmentRequest, CatalogRequest,
  CheckIn, CheckOut, StatusRequest, deliver,
}
import dream_postgres/driver/pool/pool_status.{type PoolStatus}
import gleam/erlang/process.{type Down, type Pid, type Subject}
import gleam/result.{try}

/// Holds one connection for the callback, which may send it any number of
/// commands, for example the commands of a transaction. The hold ends when
/// the callback returns, or when the caller's process exits. A transaction
/// that the callback leaves open is rolled back before the pool hands the
/// connection out again.
///
/// ## Parameters
///
/// - `pool`: the pool
/// - `deadline_milliseconds`: the longest time to wait in the queue for a
///   free connection
/// - `callback`: what to do with the connection
///
/// ## Returns
///
/// - `Ok(value)`: the value of the callback
/// - `Error(HoldDeadlinePassed)`: no connection was free before the deadline
/// - `Error(ConnectFailed(error))`: no connection is connected, and the
///   last connect failed with `error`
/// - `Error(PoolStopped)`: the pool stops, or it is gone
/// - `Error(NoDatabase)`: the pool has no database
pub fn hold(
  pool: Pool(attachment),
  deadline_milliseconds: Int,
  callback: fn(Connection) -> value,
) -> Result(value, HoldError) {
  use lease <- result.map(check_out(pool, deadline_milliseconds))
  let value = callback(lease.connection)
  check_in_lease(lease)
  value
}

/// Ends the hold at the manager that gave the lease. When that manager is
/// gone, the message is dropped, and there is nothing to end.
fn check_in_lease(lease: Lease) -> Nil {
  deliver(lease.manager, CheckIn(lease.id))
}

fn check_out(
  pool: Pool(attachment),
  deadline_milliseconds: Int,
) -> Result(Lease, HoldError) {
  ask(pool, CheckOut(process.self(), deadline_milliseconds, _))
  |> result.map_error(stopped_hold)
  |> result.flatten
}

/// The type catalog of the pool. Each pool has its own catalog, which
/// starts empty and stops with the pool. The handle asks the manager for
/// it, because a pool that starts again under its name has a new catalog.
///
/// ## Parameters
///
/// - `pool`: the pool
///
/// ## Returns
///
/// - `Ok(Catalog)`: the catalog of the manager that runs now, for the
///   lookups of the codecs
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn catalog(pool: Pool(attachment)) -> Result(Catalog, PoolNotRunning) {
  ask(pool, CatalogRequest)
}

/// A pool that does not run refuses a hold with `PoolStopped`.
fn stopped_hold(_not_running: PoolNotRunning) -> HoldError {
  PoolStopped
}

/// The value that the pool's user attached to the pool in its settings.
/// It is read from the pool process, so a handle of a name gives the value
/// of the pool that runs under the name now: after a restart by a
/// supervisor, the one of the child spec again.
///
/// ## Parameters
///
/// - `pool`: the pool, or a handle of its name
///
/// ## Returns
///
/// - `Ok(attachment)`: the value of the pool's settings
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn attachment(
  pool: Pool(attachment),
) -> Result(attachment, PoolNotRunning) {
  ask(pool, AttachmentRequest)
}

/// The state of the pool now: its connections, its holds, its queue and
/// its last connect error.
///
/// ## Parameters
///
/// - `pool`: the pool
///
/// ## Returns
///
/// - `Ok(PoolStatus)`: the counts and the last connect error
/// - `Error(PoolNotRunning)`: the pool is gone, or no pool runs under the
///   name now
pub fn status(pool: Pool(attachment)) -> Result(PoolStatus, PoolNotRunning) {
  ask(pool, StatusRequest)
}

/// Sends a request to the manager and waits for its answer. The manager
/// answers each request; a manager that is gone, or a name that no
/// manager has, gives `PoolStopped`. The request goes to the process ID
/// that the subject has now, never to the name, so a manager that exits
/// at that moment gives `PoolStopped` too, not a crash of the caller.
pub fn ask(
  pool: Pool(attachment),
  make: fn(Subject(reply)) -> PoolMessage(attachment),
) -> Result(reply, PoolNotRunning) {
  use manager <- try(manager_pid(pool))
  let reply_to = process.new_subject()
  let monitor = process.monitor(manager)
  deliver(manager, make(reply_to))
  let answer =
    process.new_selector()
    |> process.select_map(reply_to, Ok)
    |> process.select_specific_monitor(monitor, pool_down)
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

/// The manager process of the pool, or of its name now.
fn manager_pid(pool: Pool(attachment)) -> Result(Pid, PoolNotRunning) {
  process.subject_owner(pool.subject) |> result.replace_error(PoolNotRunning)
}

fn pool_down(_down: Down) -> Result(reply, PoolNotRunning) {
  Error(PoolNotRunning)
}
