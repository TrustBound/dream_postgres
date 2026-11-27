//// The TLS settings of the driver tests. The driver servers have the
//// certificate `test/fixtures/ssl/server.crt`, which the test CA signs.

import dream_postgres/driver/transport.{
  type Tls, AuthorityFile, CheckAuthorityAndHost, PostgresNegotiation,
  RequireTls,
}

/// The file of the test CA.
pub const certificate_authority = "test/fixtures/ssl/ca.crt"

/// TLS that checks the test CA and the host name, after an SSLRequest.
pub fn verify_full() -> Tls {
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(certificate_authority)),
    PostgresNegotiation,
  )
}
