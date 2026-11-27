//// The transport FFI's own reading of a certificate check's reason, for
//// the tests of the reasons that no test server can make.

import dream_postgres/driver/transport.{type SocketFailure}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

/// The name of a reason: the atom itself, or the first element of a tuple
/// such as `{revoked, keyCompromise}`.
@external(erlang, "dream_postgres_transport_ffi", "reason_name")
pub fn reason_name(reason: #(Atom, Atom)) -> Atom

/// The transport FFI's reading of the reason of a failed socket call.
@external(erlang, "dream_postgres_transport_ffi", "failure")
pub fn socket_failure(reason: Dynamic) -> SocketFailure
