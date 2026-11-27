//// Tests for `dream_postgres/driver/channel_binding`: the
//// `tls-server-end-point` hash of a certificate of each signature
//// algorithm.
////
//// The certificates are in `test/fixtures/channel_binding`, in DER. They
//// are for the tests only, and their keys are gone. `rsa_sha256.der` is
//// `test/fixtures/ssl/server.crt`. OpenSSL 4.1.0 made the others, each
//// with `openssl req -x509 -newkey <key> -nodes -days 36500 -outform DER`
//// and:
////
//// - `rsa_sha1.der`: `rsa:2048`, `-sha1`
//// - `rsa_sha512.der`: `rsa:2048`, `-sha512`
//// - `rsa_pss_sha384.der`: `rsa:2048`, `-sha384 -sigopt
////   rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1`
//// - `ecdsa_sha224.der`: `ec -pkeyopt ec_paramgen_curve:P-256`, `-sha224`
//// - `ecdsa_sha384.der`: `ec -pkeyopt ec_paramgen_curve:P-384`, `-sha384`
//// - `ed25519.der`: `ed25519`
////
//// Each expected hash is the output of `openssl dgst` with the hash that
//// RFC 5929 section 4.1 gives.

import dream_postgres/driver/channel_binding.{
  InvalidCertificate, UnsupportedSignatureAlgorithm, server_end_point_hash,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/test_files.{read_certificate}
import gleam/list.{map}
import matchers/extract_base16.{extract_base16}
import matchers/extract_server_end_point_hash.{extract_server_end_point_hash}

/// The tests of the channel binding data.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/channel_binding", [
    group("the hash of each signature algorithm", map(hash_cases(), hash_test)),
    group("certificates without channel binding data", [
      it("refuses an Ed25519 certificate", fn() {
        // Act
        let certificate = read_certificate("ed25519.der")

        // Assert
        certificate
        |> should
        |> be_ok
        |> extract_server_end_point_hash
        |> be_error
        |> be_equal(UnsupportedSignatureAlgorithm([1, 3, 101, 112]))
        |> or_fail_with("Expected Ed25519 to have no tls-server-end-point hash")
      }),
      it("refuses bytes that are not a certificate", fn() {
        // Act
        let hash = server_end_point_hash(<<1, 2, 3>>)

        // Assert
        hash
        |> should
        |> be_error
        |> be_equal(InvalidCertificate)
        |> or_fail_with("Expected bytes that are not a certificate to fail")
      }),
    ]),
  ])
}

type HashCase {
  HashCase(name: String, file: String, expected_hash: String)
}

fn hash_test(test_case: HashCase) {
  it(test_case.name, fn() {
    // Act
    let certificate = read_certificate(test_case.file)

    // Assert
    certificate
    |> should
    |> be_ok
    |> extract_server_end_point_hash
    |> be_ok
    |> extract_base16
    |> be_equal(test_case.expected_hash)
    |> or_fail_with("Expected the hash of " <> test_case.file)
  })
}

fn hash_cases() -> List(HashCase) {
  [
    HashCase(
      "SHA-1 with RSA gives SHA-256",
      "rsa_sha1.der",
      "C0F574FBF38AA74A9B2692EDC2D5EAC587E46C45C03E450935EF842AFCB2250E",
    ),
    HashCase(
      "SHA-256 with RSA gives SHA-256",
      "rsa_sha256.der",
      "196B6924B0FE3D952F50D1E49779CF1FD45FB0C1FA201D6232C6A993392A18D5",
    ),
    HashCase(
      "SHA-512 with RSA gives SHA-512",
      "rsa_sha512.der",
      "D63A4ED6FBB2EC52FA2DE675C8D11C0326F6D2F4DC39B5319C391D92B9EA00958FC493E9D717F3633D9213C261782A157D1861C28E3C9D563C3E6D287168AEF4",
    ),
    HashCase(
      "RSASSA-PSS with SHA-384 gives SHA-384",
      "rsa_pss_sha384.der",
      "B7DEE92ABA9E0225CC0FBC924E68F332290909D8B742E24A2276B749EA7D0F9342D6694CE0E35CF52FF800ADA99CDA83",
    ),
    HashCase(
      "ECDSA with SHA-224 gives SHA-224",
      "ecdsa_sha224.der",
      "0ED41AAC43E01CB1FF656DE45EA8E406B1BB79FAA2E84EF301419A36",
    ),
    HashCase(
      "ECDSA with SHA-384 gives SHA-384",
      "ecdsa_sha384.der",
      "BAEF2447C599C1453840F03226F820A449D2B13E4E4CE37266BD75715183423497088240F1A6A468905B06C3DFC02281",
    ),
  ]
}
