//// Erlang atoms, for the tests that give a reason the way OTP gives it.

import gleam/dynamic.{type Dynamic}

/// The atom with this name, as a dynamic value.
///
/// ## Example
///
/// ```gleam
/// posix.from_reason(atom.from_name("econnrefused"))
/// // -> Ok(Econnrefused)
/// ```
@external(erlang, "erlang", "binary_to_atom")
pub fn from_name(name: String) -> Dynamic
