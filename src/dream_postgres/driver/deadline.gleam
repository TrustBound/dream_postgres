//// A point in time by which a step must end. It reads the monotonic clock
//// of the VM, so a change of the system time does not move it.
////
//// The setup of a connection has one deadline for the TCP connect, TLS and
//// the login together. Each blocking step waits only for the time that is
//// left, so the whole setup ends by the deadline.

import gleam/int.{max, min}

/// A point in time on the monotonic clock, in milliseconds.
pub opaque type Deadline {
  Deadline(at_milliseconds: Int)
}

/// A deadline `milliseconds` from now.
///
/// ## Parameters
///
/// - `milliseconds`: how long from now the deadline is
///
/// ## Returns
///
/// The deadline.
pub fn from_now(milliseconds: Int) -> Deadline {
  Deadline(at_milliseconds: monotonic_milliseconds() + milliseconds)
}

/// The time that is left until the deadline.
///
/// ## Parameters
///
/// - `deadline`: the deadline
///
/// ## Returns
///
/// The milliseconds until the deadline, or 0 when it has passed.
pub fn time_left(deadline: Deadline) -> Int {
  max(deadline.at_milliseconds - monotonic_milliseconds(), 0)
}

/// The time that a step with its own timeout may wait: its timeout, or the
/// time that is left until the deadline when that is shorter.
///
/// ## Parameters
///
/// - `deadline`: the deadline
/// - `timeout_milliseconds`: the step's own timeout
///
/// ## Returns
///
/// The shorter of the two, in milliseconds.
pub fn bounded_wait(deadline: Deadline, timeout_milliseconds: Int) -> Int {
  min(timeout_milliseconds, time_left(deadline))
}

/// Says whether the deadline has passed.
///
/// ## Parameters
///
/// - `deadline`: the deadline
///
/// ## Returns
///
/// `True` when no time is left.
pub fn has_passed(deadline: Deadline) -> Bool {
  time_left(deadline) == 0
}

@external(erlang, "dream_postgres_driver_ffi", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int
