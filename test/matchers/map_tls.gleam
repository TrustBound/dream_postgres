//// A matcher that maps a TLS setting of the client to the TLS setting of the driver.

import dream_postgres.{type Tls}
import dream_postgres/driver/transport
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Map a TLS setting of the client to the TLS setting of the driver. The chain goes on with the result.
///
/// ## Example
///
/// ```gleam
/// TlsOff
/// |> should
/// |> map_tls()
/// |> be_equal(transport.NoTls)
/// |> or_fail_with("Expected NoTls")
/// ```
pub fn map_tls(result: MatchResult(Tls)) -> MatchResult(transport.Tls) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> MatchOk(dream_postgres.transport_tls(value))
  }
}
