//// Extracts the server certificate of a transport connection.

import dream_postgres/driver/transport.{
  type Connection, close, server_certificate,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option}

/// Gives the DER bytes of the server certificate, `None` on plain TCP,
/// then closes the connection.
///
/// ```gleam
/// connect(config)
/// |> should
/// |> be_ok
/// |> extract_server_certificate
/// |> be_equal(None)
/// |> or_fail_with("Expected a plain connection")
/// ```
pub fn extract_server_certificate(
  result: MatchResult(Connection),
) -> MatchResult(Option(BitArray)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(connection) -> MatchOk(certificate_and_close(connection))
  }
}

fn certificate_and_close(connection: Connection) -> Option(BitArray) {
  let certificate = server_certificate(connection)
  close(connection)
  certificate
}
