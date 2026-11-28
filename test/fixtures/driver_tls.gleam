//// The TLS settings of the driver tests, and the transport settings of a
//// host and a port. The driver servers have the certificate
//// `test/fixtures/ssl/server.crt`, which the test CA signs.

import dream_postgres/driver/transport.{
  type Tls, type TransportConfig, type TransportError, AuthorityCertificates,
  AuthorityFile, CheckAuthorityAndHost, ConnectUnlisted, PostgresNegotiation,
  RequireTls, TransportConfig, address,
}
import driver/test_files.{read_pem_certificate}
import gleam/result.{map, map_error, replace_error, try}
import gleam/string.{inspect}

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
  |> replace_error(ConnectUnlisted("test address"))
}

/// The transport settings for a host and a port, with TLS that checks the
/// host name and the test CA, which the settings hold as DER bytes. An
/// unreadable CA file or a refused address gives an error.
pub fn der_authority_config(
  host: String,
  port: Int,
) -> Result(TransportConfig, String) {
  use certificate <- try(read_pem_certificate(certificate_authority))
  let authorities = AuthorityCertificates([certificate])
  let tls = RequireTls(CheckAuthorityAndHost(authorities), PostgresNegotiation)
  transport_config(host, port, tls) |> map_error(inspect)
}
