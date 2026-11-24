//// A monotonic clock for the tests that check how long a call takes.

import gleam/erlang/atom

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

/// Returns the monotonic time of the BEAM in milliseconds.
///
/// Subtract two values to get the time between them. The value itself has
/// no meaning.
pub fn now_in_milliseconds() -> Int {
  monotonic_time(atom.create("millisecond"))
}
