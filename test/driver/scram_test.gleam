//// Tests for `dream_postgres/driver/scram`: the SCRAM-SHA-256 example of
//// RFC 7677 section 3, the channel binding flags, and each way that a
//// server message can be wrong.
////
//// The values of the channel binding cases come from a separate Python
//// implementation (`hashlib.pbkdf2_hmac` and `hmac`), which gives the RFC
//// 7677 example exactly.

import dream_postgres/driver/scram.{
  type ServerFinalError, type ServerFirstError, ClientWithoutChannelBinding,
  InvalidIterationCount, InvalidSalt, InvalidServerFinalMessage,
  InvalidServerFirstMessage, MandatoryExtension, ServerEndPoint,
  ServerFirstTooLong, ServerNonceMismatch, ServerReportedError,
  ServerSignatureMismatch, ServerWithoutChannelBinding, client_final,
  client_first, client_first_message,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/list.{map}
import matchers/extract_client_final_message.{extract_client_final_message}
import matchers/extract_server_final_check.{extract_server_final_check}

/// The tests of SCRAM.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/scram", [
    group("the example of RFC 7677", [
      it("gives the client-first-message", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

        // Act
        let message = client_first_message(first)

        // Assert
        message
        |> should
        |> be_equal(<<"n,,n=user,r=rOprNGfwEbeRWgbNEkqO">>)
        |> or_fail_with("Expected the client-first-message of RFC 7677")
      }),
      it("gives the client-final-message", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

        // Act
        let final = client_final(first, "pencil", <<rfc_server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        >>)
        |> or_fail_with("Expected the client-final-message of RFC 7677")
      }),
      it("accepts the server-final-message", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)
        let server_final = <<"v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=">>

        // Act
        let final = client_final(first, "pencil", <<rfc_server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_server_final_check(server_final)
        |> be_ok
        |> be_equal(Nil)
        |> or_fail_with("Expected the server signature of RFC 7677 to verify")
      }),
      it("applies SASLprep to the password", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

        // Act
        let final =
          client_final(first, "pen\u{00AD}cil", <<rfc_server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        >>)
        |> or_fail_with("Expected SASLprep to remove the SOFT HYPHEN")
      }),
    ]),
    group("the client messages", [
      it("escapes = and , in the user name", fn() {
        // Arrange
        let first =
          client_first("a=b,c", <<1, 2, 3>>, ClientWithoutChannelBinding)

        // Act
        let message = client_first_message(first)

        // Assert
        message
        |> should
        |> be_equal(<<"n,,n=a=3Db=2Cc,r=AQID">>)
        |> or_fail_with("Expected the escaped user name")
      }),
      it("gives the y flag in the client-first-message", fn() {
        // Arrange
        let first = client_first("", nonce, ServerWithoutChannelBinding)

        // Act
        let message = client_first_message(first)

        // Assert
        message
        |> should
        |> be_equal(<<"y,,n=,r=AAECAwQFBgcICQoLDA0ODxAR">>)
        |> or_fail_with("Expected the client-first-message with the y flag")
      }),
      it("gives the y flag in the client-final-message", fn() {
        // Arrange
        let first = client_first("", nonce, ServerWithoutChannelBinding)

        // Act
        let final = client_final(first, "pencil", <<server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=eSws,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=msyn1LY0Oxyf+gll/EK7CSRK3qevfV2WO+EnTVvsmtY=",
        >>)
        |> or_fail_with("Expected the client-final-message with the y flag")
      }),
      it("gives the channel binding data in the client-first-message", fn() {
        // Arrange
        let first = client_first("", nonce, ServerEndPoint(certificate_hash))

        // Act
        let message = client_first_message(first)

        // Assert
        message
        |> should
        |> be_equal(<<"p=tls-server-end-point,,n=,r=AAECAwQFBgcICQoLDA0ODxAR">>)
        |> or_fail_with(
          "Expected the client-first-message with tls-server-end-point",
        )
      }),
      it("gives the channel binding data in the client-final-message", fn() {
        // Arrange
        let first = client_first("", nonce, ServerEndPoint(certificate_hash))

        // Act
        let final = client_final(first, "pencil", <<server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=cD10bHMtc2VydmVyLWVuZC1wb2ludCwsGWtpJLD+PZUvUNHkl3nPH9RfsMH6IB1iMsapkzkqGNU=,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=Fx0VuA3kaR3WQ4pqLtQ5uy0fXOuvt6uaMPY0dBUxApk=",
        >>)
        |> or_fail_with(
          "Expected the client-final-message with tls-server-end-point",
        )
      }),
      it("uses a password that SASLprep refuses as given", fn() {
        // Arrange
        let first = client_first("", nonce, ClientWithoutChannelBinding)

        // Act
        let final = client_final(first, "pen\u{0007}cil", <<server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=biws,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=9AArJk5GJUOIRDIF6gJUvBRZKrmbM6JmnoXb02vz+1Y=",
        >>)
        |> or_fail_with("Expected the proof of the raw password")
      }),
    ]),
    group("the extensions of RFC 5802 section 7", [
      it("reads a server-first-message with an extension after it", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

        // Act
        let final =
          client_final(first, "pencil", <<
            rfc_server_first:utf8,
            ",x=later-extension",
          >>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_client_final_message
        |> be_equal(<<
          "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=Eki7g8gSabXzUcBbHMW0YjX8eKNV2eh2a8/mpS4wvj0=",
        >>)
        |> or_fail_with(
          "Expected the proof over the message with its extension",
        )
      }),
      it("reads a server-final-message with an extension after it", fn() {
        // Arrange
        let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)
        let server_final = <<
          "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,x=later-extension",
        >>

        // Act
        let final = client_final(first, "pencil", <<rfc_server_first:utf8>>)

        // Assert
        final
        |> should
        |> be_ok
        |> extract_server_final_check(server_final)
        |> be_ok
        |> be_equal(Nil)
        |> or_fail_with("Expected the signature to verify before the extension")
      }),
    ]),
    group(
      "server-first-messages that are wrong",
      map(server_first_cases(), server_first_test),
    ),
    group(
      "server-final-messages that are wrong",
      map(server_final_cases(), server_final_test),
    ),
  ])
}

/// The nonce of the example, as the bytes that give it in base64.
const rfc_nonce = <<
  0xAC, 0xEA, 0x6B, 0x34, 0x67, 0xF0, 0x11, 0xB7, 0x91, 0x5A, 0x06, 0xCD, 0x12,
  0x4A, 0x8E,
>>

const rfc_server_first =
  "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

/// The nonce of the other cases: the bytes 0 to 17.
const nonce = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17>>

const server_first =
  "r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

/// The SHA-256 of `test/fixtures/channel_binding/rsa_sha256.der`:
/// 196B6924B0FE3D952F50D1E49779CF1FD45FB0C1FA201D6232C6A993392A18D5.
const certificate_hash = <<
  0x19,
  0x6B,
  0x69,
  0x24,
  0xB0,
  0xFE,
  0x3D,
  0x95,
  0x2F,
  0x50,
  0xD1,
  0xE4,
  0x97,
  0x79,
  0xCF,
  0x1F,
  0xD4,
  0x5F,
  0xB0,
  0xC1,
  0xFA,
  0x20,
  0x1D,
  0x62,
  0x32,
  0xC6,
  0xA9,
  0x93,
  0x39,
  0x2A,
  0x18,
  0xD5,
>>

type ServerMessageCase(error) {
  ServerMessageCase(name: String, message: BitArray, error: error)
}

fn server_first_test(test_case: ServerMessageCase(ServerFirstError)) {
  it(test_case.name, fn() {
    // Arrange
    let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

    // Act
    let final = client_final(first, "pencil", test_case.message)

    // Assert
    final
    |> should
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn server_first_cases() -> List(ServerMessageCase(ServerFirstError)) {
  [
    ServerMessageCase(
      "a message of 16385 bytes, one more than longest_server_first",
      <<0:size(131_080)>>,
      ServerFirstTooLong(16_385),
    ),
    ServerMessageCase(
      "a message of 16384 bytes is read, and has no nonce",
      <<0:size(131_072)>>,
      InvalidServerFirstMessage(<<0:size(131_072)>>),
    ),
    ServerMessageCase(
      "bytes that are not UTF-8",
      <<255>>,
      InvalidServerFirstMessage(<<255>>),
    ),
    ServerMessageCase(
      "a message that starts with the mandatory extension m=",
      <<"m=future,r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA,i=4096">>,
      MandatoryExtension("m=future,r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA,i=4096"),
    ),
    ServerMessageCase(
      "a message without the iteration count",
      <<"r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA">>,
      InvalidServerFirstMessage(<<"r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA">>),
    ),
    ServerMessageCase(
      "a nonce that does not start with the client's nonce",
      <<"r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096">>,
      ServerNonceMismatch("other"),
    ),
    ServerMessageCase(
      "a nonce that adds nothing to the client's nonce",
      <<"r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096">>,
      ServerNonceMismatch("rOprNGfwEbeRWgbNEkqO"),
    ),
    ServerMessageCase(
      "a salt that is not base64",
      <<"r=rOprNGfwEbeRWgbNEkqOabc,s=***,i=4096">>,
      InvalidSalt("***"),
    ),
    ServerMessageCase(
      "an iteration count of 0",
      <<"r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0">>,
      InvalidIterationCount("0"),
    ),
    ServerMessageCase(
      "an iteration count that is not a number",
      <<"r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=many">>,
      InvalidIterationCount("many"),
    ),
  ]
}

fn server_final_test(test_case: ServerMessageCase(ServerFinalError)) {
  it(test_case.name, fn() {
    // Arrange
    let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

    // Act
    let final = client_final(first, "pencil", <<rfc_server_first:utf8>>)

    // Assert
    final
    |> should
    |> be_ok
    |> extract_server_final_check(test_case.message)
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn server_final_cases() -> List(ServerMessageCase(ServerFinalError)) {
  [
    ServerMessageCase(
      "an error of the server",
      <<"e=invalid-proof">>,
      ServerReportedError("invalid-proof"),
    ),
    ServerMessageCase(
      "a wrong signature",
      <<"v=XWerSOwJj3Jipqf9+ifSFHLsATHu/Paues7tk7jd0vc=">>,
      ServerSignatureMismatch,
    ),
    ServerMessageCase(
      "a signature that is too short",
      <<"v=AQID">>,
      ServerSignatureMismatch,
    ),
    ServerMessageCase(
      "a signature that is not base64",
      <<"v=***">>,
      InvalidServerFinalMessage(<<"v=***">>),
    ),
    ServerMessageCase(
      "a message with another attribute",
      <<"x=1">>,
      InvalidServerFinalMessage(<<"x=1">>),
    ),
  ]
}
