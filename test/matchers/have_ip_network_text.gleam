//// A matcher that gives the text of the IP network of the chain, as
//// PostgreSQL writes it.

import dream_postgres/network.{type IpNetwork}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the text of the network. The chain goes on with the text.
///
/// ## Example
///
/// ```gleam
/// network.ip_network_from_string("2001:db8:0:0:0:0:0:1")
/// |> should
/// |> be_ok()
/// |> have_ip_network_text()
/// |> be_equal("2001:db8::1")
/// |> or_fail_with("Expected the short form 2001:db8::1")
/// ```
pub fn have_ip_network_text(
  result: MatchResult(IpNetwork),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(network.ip_network_to_string(value))
  }
}
