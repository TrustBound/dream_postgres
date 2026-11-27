//// Tests for `dream_postgres/driver/scram`: the SCRAM-SHA-256 example of
//// RFC 7677 section 3, the channel binding flags, and each way that a
//// server message can be wrong.
////
//// The values of the channel binding cases come from a separate Python
//// implementation (`hashlib.pbkdf2_hmac` and `hmac`), which gives the RFC
//// 7677 example exactly.

import dream_postgres/driver/scram.{
  type ClientFinal, type ScramError, ClientWithoutChannelBinding,
  InvalidIterationCount, InvalidSalt, InvalidServerFinalMessage,
  InvalidServerFirstMessage, ServerEndPoint, ServerNonceMismatch,
  ServerReportedError, ServerSignatureMismatch, ServerWithoutChannelBinding,
  client_final, client_final_message, client_first, client_first_message,
  verify_server_final,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array.{base16_decode}
import gleam/list.{map}
import gleam/result.{try}

/// The tests of SCRAM.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/scram", [
    group("the example of RFC 7677", [
      it("gives the client-first-message", check_rfc_client_first),
      it("gives the client-final-message", check_rfc_client_final),
      it("accepts the server-final-message", check_rfc_server_final),
      it("applies SASLprep to the password", check_saslprep_password),
    ]),
    group("the client messages", [
      it("escapes = and , in the user name", check_user_name),
      it("gives the y flag", check_flag_y),
      it("gives the channel binding data", check_end_point),
      it(
        "uses a password that SASLprep refuses as given",
        check_refused_password,
      ),
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

/// The SHA-256 of `test/fixtures/channel_binding/rsa_sha256.der`.
const certificate_hash =
  "196B6924B0FE3D952F50D1E49779CF1FD45FB0C1FA201D6232C6A993392A18D5"

fn rfc_final(password: String) -> Result(BitArray, ScramError) {
  let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)
  client_final(first, password, <<rfc_server_first:utf8>>)
  |> result.map(client_final_message)
}

fn rfc_client_final() -> Result(ClientFinal, ScramError) {
  let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)
  client_final(first, "pencil", <<rfc_server_first:utf8>>)
}

fn check_rfc_client_first() {
  // Arrange
  let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

  // Act
  let message = client_first_message(first)

  // Assert
  message
  |> should
  |> be_equal(<<"n,,n=user,r=rOprNGfwEbeRWgbNEkqO">>)
  |> or_fail_with("Expected the client-first-message of RFC 7677")
}

fn check_rfc_client_final() {
  // Act
  let message = rfc_final("pencil")

  // Assert
  message
  |> should
  |> be_equal(
    Ok(<<
      "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
    >>),
  )
  |> or_fail_with("Expected the client-final-message of RFC 7677")
}

fn check_rfc_server_final() {
  // Arrange
  let server_final = <<"v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=">>

  // Act
  let verified = {
    use final <- try(rfc_client_final())
    verify_server_final(final, server_final)
  }

  // Assert
  verified
  |> should
  |> be_equal(Ok(Nil))
  |> or_fail_with("Expected the server signature of RFC 7677 to verify")
}

fn check_saslprep_password() {
  // Act
  let message = rfc_final("pen\u{00AD}cil")

  // Assert
  message
  |> should
  |> be_equal(rfc_final("pencil"))
  |> or_fail_with("Expected SASLprep to remove the SOFT HYPHEN")
}

fn check_user_name() {
  // Arrange
  let first = client_first("a=b,c", <<1, 2, 3>>, ClientWithoutChannelBinding)

  // Act
  let message = client_first_message(first)

  // Assert
  message
  |> should
  |> be_equal(<<"n,,n=a=3Db=2Cc,r=AQID">>)
  |> or_fail_with("Expected the escaped user name")
}

fn check_flag_y() {
  // Arrange
  let first = client_first("", nonce, ServerWithoutChannelBinding)

  // Act
  let messages = #(
    client_first_message(first),
    client_final(first, "pencil", <<server_first:utf8>>)
      |> result.map(client_final_message),
  )

  // Assert
  messages
  |> should
  |> be_equal(#(
    <<"y,,n=,r=AAECAwQFBgcICQoLDA0ODxAR">>,
    Ok(<<
      "c=eSws,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=msyn1LY0Oxyf+gll/EK7CSRK3qevfV2WO+EnTVvsmtY=",
    >>),
  ))
  |> or_fail_with("Expected the messages with the y flag")
}

fn check_end_point() {
  // Arrange
  let binding = ServerEndPoint(hash_bytes(certificate_hash))
  let first = client_first("", nonce, binding)

  // Act
  let messages = #(
    client_first_message(first),
    client_final(first, "pencil", <<server_first:utf8>>)
      |> result.map(client_final_message),
  )

  // Assert
  messages
  |> should
  |> be_equal(#(
    <<"p=tls-server-end-point,,n=,r=AAECAwQFBgcICQoLDA0ODxAR">>,
    Ok(<<
      "c=cD10bHMtc2VydmVyLWVuZC1wb2ludCwsGWtpJLD+PZUvUNHkl3nPH9RfsMH6IB1iMsapkzkqGNU=,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=Fx0VuA3kaR3WQ4pqLtQ5uy0fXOuvt6uaMPY0dBUxApk=",
    >>),
  ))
  |> or_fail_with("Expected the messages with tls-server-end-point")
}

fn hash_bytes(hexadecimal: String) -> BitArray {
  case base16_decode(hexadecimal) {
    Ok(bytes) -> bytes
    Error(Nil) -> <<>>
  }
}

fn check_refused_password() {
  // Arrange
  let first = client_first("", nonce, ClientWithoutChannelBinding)

  // Act
  let message =
    client_final(first, "pen\u{0007}cil", <<server_first:utf8>>)
    |> result.map(client_final_message)

  // Assert
  message
  |> should
  |> be_equal(
    Ok(<<
      "c=biws,r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=9AArJk5GJUOIRDIF6gJUvBRZKrmbM6JmnoXb02vz+1Y=",
    >>),
  )
  |> or_fail_with("Expected the proof of the raw password")
}

type ServerMessageCase {
  ServerMessageCase(name: String, message: BitArray, error: ScramError)
}

fn server_first_test(test_case: ServerMessageCase) {
  it(test_case.name, fn() { check_server_first(test_case) })
}

fn check_server_first(test_case: ServerMessageCase) {
  // Arrange
  let first = client_first("user", rfc_nonce, ClientWithoutChannelBinding)

  // Act
  let final =
    client_final(first, "pencil", test_case.message)
    |> result.map(client_final_message)

  // Assert
  final
  |> should
  |> be_equal(Error(test_case.error))
  |> or_fail_with("Expected an error for " <> test_case.name)
}

fn server_first_cases() -> List(ServerMessageCase) {
  [
    ServerMessageCase(
      "bytes that are not UTF-8",
      <<255>>,
      InvalidServerFirstMessage(<<255>>),
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

fn server_final_test(test_case: ServerMessageCase) {
  it(test_case.name, fn() { check_server_final(test_case) })
}

fn check_server_final(test_case: ServerMessageCase) {
  // Act
  let verified = {
    use final <- try(rfc_client_final())
    verify_server_final(final, test_case.message)
  }

  // Assert
  verified
  |> should
  |> be_equal(Error(test_case.error))
  |> or_fail_with("Expected an error for " <> test_case.name)
}

fn server_final_cases() -> List(ServerMessageCase) {
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
