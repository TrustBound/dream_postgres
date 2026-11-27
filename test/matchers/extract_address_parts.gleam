//// Extracts the host and the port of a transport address.

import dream_postgres/driver/transport.{type Address, host, port}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives `#(host, port)` of the address.
///
/// ```gleam
/// address("db.example.com", 6543)
/// |> should
/// |> be_ok
/// |> extract_address_parts
/// |> be_equal(#("db.example.com", 6543))
/// |> or_fail_with("Expected the host and the port")
/// ```
pub fn extract_address_parts(
  result: MatchResult(Address),
) -> MatchResult(#(String, Int)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(address) -> MatchOk(#(host(address), port(address)))
  }
}
