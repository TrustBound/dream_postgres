//// The channel binding data of SCRAM-SHA-256-PLUS: the hash of the
//// server's TLS certificate, for the channel binding type
//// `tls-server-end-point`.
////
//// RFC 5929 section 4.1 gives the hash function: the one of the
//// certificate's signature algorithm, but SHA-256 when that is MD5 or
//// SHA-1. A signature algorithm that names no single hash, such as
//// Ed25519, has no `tls-server-end-point` data. PostgreSQL does the same
//// (`pgtls_get_peer_certificate_hash` in libpq's `fe-secure-openssl.c`).
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/crypto.{
  type HashAlgorithm, Sha224, Sha256, Sha384, Sha512, hash,
}
import gleam/list.{key_find}
import gleam/result.{replace_error, try}

/// Why a certificate gives no channel binding data.
pub type CertificateError {
  /// The bytes are not the DER form of an X.509 certificate.
  InvalidCertificate
  /// The certificate's signature algorithm names no hash function that
  /// RFC 5929 section 4.1 can use, for example Ed25519. The value is the
  /// object identifier of the signature algorithm, or of the hash of an
  /// RSASSA-PSS signature, as its list of numbers.
  UnsupportedSignatureAlgorithm(object_identifier: List(Int))
}

/// The hash function of each signature algorithm, by the object identifier
/// that names its hash. MD5 and SHA-1 give SHA-256 (RFC 5929 section 4.1).
const hash_of_identifier: List(#(List(Int), HashAlgorithm)) = [
  // md5WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 4], Sha256),
  // sha1WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 5], Sha256),
  // ecdsa-with-SHA1
  #([1, 2, 840, 10_045, 4, 1], Sha256),
  // id-dsa-with-sha1
  #([1, 2, 840, 10_040, 4, 3], Sha256),
  // sha224WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 14], Sha224),
  // sha256WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 11], Sha256),
  // sha384WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 12], Sha384),
  // sha512WithRSAEncryption
  #([1, 2, 840, 113_549, 1, 1, 13], Sha512),
  // ecdsa-with-SHA224
  #([1, 2, 840, 10_045, 4, 3, 1], Sha224),
  // ecdsa-with-SHA256
  #([1, 2, 840, 10_045, 4, 3, 2], Sha256),
  // ecdsa-with-SHA384
  #([1, 2, 840, 10_045, 4, 3, 3], Sha384),
  // ecdsa-with-SHA512
  #([1, 2, 840, 10_045, 4, 3, 4], Sha512),
  // id-dsa-with-sha224
  #([2, 16, 840, 1, 101, 3, 4, 3, 1], Sha224),
  // id-dsa-with-sha256
  #([2, 16, 840, 1, 101, 3, 4, 3, 2], Sha256),
  // The hash of an RSASSA-PSS signature: id-md5
  #([1, 2, 840, 113_549, 2, 5], Sha256),
  // id-sha1
  #([1, 3, 14, 3, 2, 26], Sha256),
  // id-sha224
  #([2, 16, 840, 1, 101, 3, 4, 2, 4], Sha224),
  // id-sha256
  #([2, 16, 840, 1, 101, 3, 4, 2, 1], Sha256),
  // id-sha384
  #([2, 16, 840, 1, 101, 3, 4, 2, 2], Sha384),
  // id-sha512
  #([2, 16, 840, 1, 101, 3, 4, 2, 3], Sha512),
]

@external(erlang, "dream_postgres_driver_ffi", "certificate_hash_identifier")
fn certificate_hash_identifier(certificate: BitArray) -> Result(List(Int), Nil)

/// Gives the `tls-server-end-point` channel binding data of a server
/// certificate (RFC 5929 section 4.1).
///
/// ## Parameters
///
/// - `certificate`: the DER bytes of the server's TLS certificate
///
/// ## Returns
///
/// - `Ok(hash)`: the hash of `certificate`, with the hash function of its
///   signature algorithm
/// - `Error(CertificateError)`: the bytes are not a certificate, or its
///   signature algorithm names no hash that RFC 5929 can use
pub fn server_end_point_hash(
  certificate: BitArray,
) -> Result(BitArray, CertificateError) {
  use identifier <- try(
    certificate_hash_identifier(certificate)
    |> replace_error(InvalidCertificate),
  )
  use algorithm <- try(
    key_find(hash_of_identifier, identifier)
    |> replace_error(UnsupportedSignatureAlgorithm(identifier)),
  )
  Ok(hash(algorithm, certificate))
}
