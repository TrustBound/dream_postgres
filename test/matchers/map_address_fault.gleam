//// A matcher that gives the config fault of an error of a server address.

import dream_postgres/driver/transport.{type AddressError}
import dream_postgres/error.{type ConfigFault}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the config fault of an error of a server address, as the client
/// sees it.
///
/// ## Example
///
/// ```gleam
/// transport.InvalidPort(0)
/// |> should
/// |> map_address_fault()
/// |> be_equal(error.InvalidPort(0))
/// |> or_fail_with("Expected InvalidPort(0)")
/// ```
pub fn map_address_fault(
  result: MatchResult(AddressError),
) -> MatchResult(ConfigFault) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(address_error) ->
      MatchOk(driver_executor.address_fault(address_error))
  }
}
