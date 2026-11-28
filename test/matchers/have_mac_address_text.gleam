//// A matcher that gives the text of the MAC address of the chain, as
//// PostgreSQL writes it.

import dream_postgres/network.{type MacAddress}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the text of the MAC address: lower case hex bytes with colons. The
/// chain goes on with the text.
///
/// ## Example
///
/// ```gleam
/// network.mac_address_from_string("08-00-2B-01-02-03")
/// |> should
/// |> be_ok()
/// |> have_mac_address_text()
/// |> be_equal("08:00:2b:01:02:03")
/// |> or_fail_with("Expected the text with colons")
/// ```
pub fn have_mac_address_text(
  result: MatchResult(MacAddress),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(network.mac_address_to_string(value))
  }
}
