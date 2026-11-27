//// Calls to a supervisor that a test started, for the tests of a child:
//// start it again, and read its restart type.

import gleam/erlang/process.{type Pid}

/// Stops the first child of the supervisor and starts it again, as the
/// supervisor does after the child failed, and returns once the new child
/// runs.
@external(erlang, "driver_listener_test_ffi", "restart_first_child")
pub fn restart_first_child(supervisor: Pid) -> Result(Nil, String)

/// The restart type of the first child of the supervisor, for example
/// `transient`.
@external(erlang, "driver_listener_test_ffi", "first_child_restart")
pub fn first_child_restart_type(supervisor: Pid) -> Result(String, String)
