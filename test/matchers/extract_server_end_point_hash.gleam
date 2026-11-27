//// Gives the tls-server-end-point hash of a certificate.

import dream_postgres/driver/channel_binding.{
  type CertificateError, server_end_point_hash,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the result of `server_end_point_hash` for the DER bytes of a
/// certificate: the hash that RFC 5929 section 4.1 gives, or the error.
///
/// ```gleam
/// read_certificate("ed25519.der")
/// |> should
/// |> be_ok
/// |> extract_server_end_point_hash
/// |> be_error
/// |> be_equal(UnsupportedSignatureAlgorithm([1, 3, 101, 112]))
/// |> or_fail_with("Expected no hash for Ed25519")
/// ```
pub fn extract_server_end_point_hash(
  result: MatchResult(BitArray),
) -> MatchResult(Result(BitArray, CertificateError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(certificate) -> MatchOk(server_end_point_hash(certificate))
  }
}
