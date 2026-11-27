//// The supervisor calls of the supervision tests.

import gleam/erlang/process.{type Name, type Pid}

/// Wait until the supervisor has restarted the children that ended before
/// this call.
@external(erlang, "dream_postgres_supervision_ffi", "wait_for_restarts")
pub fn wait_for_restarts(supervisor: Pid) -> Nil

/// Stop the supervisor and its children, and wait until it is gone.
@external(erlang, "dream_postgres_supervision_ffi", "stop_supervisor")
pub fn stop_supervisor(supervisor: Pid) -> Nil

/// Kills the pool under the name, so its supervisor starts it again, and
/// waits up to one second until a new pool runs under the name.
///
/// ## Example
///
/// ```gleam
/// supervisors.restart_named_pool(pool_name)
/// ```
pub fn restart_named_pool(pool_name: Name(message)) -> Result(Nil, String) {
  case process.named(pool_name) {
    Ok(pool_pid) -> {
      process.kill(pool_pid)
      wait_for_new_pool(pool_name, pool_pid, 100)
    }
    Error(Nil) -> Error("no pool runs under the name")
  }
}

fn wait_for_new_pool(
  pool_name: Name(message),
  old_pid: Pid,
  attempts: Int,
) -> Result(Nil, String) {
  case process.named(pool_name), attempts > 0 {
    Ok(pool_pid), _ if pool_pid != old_pid -> Ok(Nil)
    _, True -> {
      process.sleep(10)
      wait_for_new_pool(pool_name, old_pid, attempts - 1)
    }
    _, False -> Error("no new pool ran under the name")
  }
}
