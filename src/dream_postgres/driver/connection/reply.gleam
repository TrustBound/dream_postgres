//// The reply of a connection process to a caller: the alias that a caller waits
//// on, and the call that waits for it.

import gleam/erlang/process.{type Pid}

/// A reply target: an alias of the caller (see the FFI module).
pub type ReplyTo(reply)

pub type CallFailure {
  CallProcessDown
  CallDeadlinePassed
}

@external(erlang, "dream_postgres_connection_ffi", "call")
pub fn call_process(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
  timeout: Int,
) -> Result(reply, CallFailure)

/// Waits for the answer of the process, or for its end, with no timer.
/// Only for a request that the process answers by a deadline of its own.
@external(erlang, "dream_postgres_connection_ffi", "call_until_answer")
pub fn call_process_until_answer(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
) -> Result(reply, CallFailure)

@external(erlang, "dream_postgres_connection_ffi", "reply")
pub fn reply(to: ReplyTo(reply), value: reply) -> Nil
