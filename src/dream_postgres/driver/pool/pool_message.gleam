//// The messages that the pool manager receives, and the handle of a pool that
//// sends them.

import dream_postgres/driver/catalog.{type Catalog}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/pool/pool_failure.{type HoldError}
import dream_postgres/driver/pool/pool_status.{type PoolStatus}
import dream_postgres/driver/pool_member.{type MemberReport}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{
  type ExitMessage, type Monitor, type Pid, type Subject,
}

/// A connection that a checkout gives, with the ID of the hold and the
/// manager process that gave it.
pub type Lease {
  Lease(id: Int, connection: Connection, manager: Pid)
}

/// Sends a request to the manager's process (see the FFI module).
@external(erlang, "dream_postgres_pool_ffi", "deliver")
pub fn deliver(manager: Pid, message: PoolMessage(attachment)) -> Nil

/// The request inside a message of `deliver`.
@external(erlang, "dream_postgres_pool_ffi", "request_of")
pub fn request_of(message: Dynamic) -> PoolMessage(attachment)

/// A pool: the subject of its manager process. For a pool that started
/// under a name, the subject is the name's, so a handle stays valid when a
/// supervisor starts the pool again under the same name.
pub type Pool(attachment) {
  Pool(subject: Subject(PoolMessage(attachment)))
}

/// A message to the manager process of a pool. A name for `start_named`
/// is a name for these messages.
pub type PoolMessage(attachment) {
  CheckOut(
    caller: Pid,
    deadline_milliseconds: Int,
    reply: Subject(Result(Lease, HoldError)),
  )
  CheckIn(lease_id: Int)
  WaiterExpired(waiter_id: Int)
  StatusRequest(reply: Subject(PoolStatus))
  CatalogRequest(reply: Subject(Catalog))
  AttachmentRequest(reply: Subject(attachment))
  StopRequest(deadline_milliseconds: Int, reply: Subject(Nil))
  DrainDeadlinePassed
  HealthCheckDue
  MemberReported(report: MemberReport)
  MonitorFired(monitor: Monitor)
  ExitReceived(exit: ExitMessage)
}
