//// The TLS settings of the driver tests, and the transport settings of a
//// host and a port. The driver servers have the certificate
//// `test/fixtures/ssl/server.crt`, which the test CA signs.

import dream_postgres/driver/transport.{
  type Tls, type TransportConfig, type TransportError, AuthorityFile,
  CheckAuthorityAndHost, PostgresNegotiation, RequireTls, TransportConfig,
  Unlisted, address,
}
import gleam/result.{map, replace_error}

/// The file of the test CA.
pub const certificate_authority = "test/fixtures/ssl/ca.crt"

/// TLS that checks the test CA and the host name, after an SSLRequest.
pub fn verify_full() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
    PostgresNegotiation,
  )
}

/// The transport settings for a host and a port, with a timeout of five
/// seconds. An address that the transport refuses gives an error.
pub fn transport_config(
  host: String,
  port: Int,
  tls: Tls,
) -> Result(TransportConfig, TransportError) {
  address(host, port)
  |> map(TransportConfig(_, tls, 5000, 5000))
  |> replace_error(Unlisted("test address"))
}
