//// The client side of the SASL mechanisms SCRAM-SHA-256 and
//// SCRAM-SHA-256-PLUS (RFC 5802, RFC 7677), as pure functions.
////
//// An exchange has three steps:
////
//// 1. `client_first` gives the client-first-message.
//// 2. `client_final` reads the server-first-message and gives the
////    client-final-message, with the client's proof.
//// 3. `verify_server_final` reads the server-final-message and checks the
////    server's signature, which proves that the server knows the password's
////    key.
////
//// No value of this module holds the password: `client_final` takes it and
//// keeps only the server signature that it expects.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/crypto.{
  Sha256, equal_in_constant_time, exclusive_or, hash, hmac, pbkdf2_hmac,
}
import dream_postgres/driver/saslprep.{saslprep}
import gleam/bit_array.{base64_decode, base64_encode, byte_size, to_string}
import gleam/bool.{guard}
import gleam/int.{parse}
import gleam/result.{replace_error, try}
import gleam/string.{replace, split, starts_with}

/// The length in bytes of a SHA-256 key and of each SCRAM-SHA-256 proof.
const key_length = 32

/// The channel binding of an exchange: the gs2-header of RFC 5802 section
/// 7.
pub type ChannelBinding {
  /// `n`: the client does not use channel binding, because it has no TLS
  /// or the caller turned channel binding off.
  ClientWithoutChannelBinding
  /// `y`: the client can bind to the channel, but the server did not offer
  /// a mechanism that does.
  ServerWithoutChannelBinding
  /// `p=tls-server-end-point`: the exchange binds to the TLS connection,
  /// with the hash of the server's certificate (RFC 5929 section 4.1).
  ServerEndPoint(certificate_hash: BitArray)
}

/// Why `client_final` refuses the server-first-message.
pub type ServerFirstError {
  /// The server-first-message does not have the form
  /// `r=<nonce>,s=<salt>,i=<iteration count>`, with optional extensions
  /// after it (RFC 5802 section 7).
  InvalidServerFirstMessage(message: BitArray)
  /// The server-first-message starts with the reserved attribute `m=`. RFC
  /// 5802 section 5.1 says that a client must then fail the exchange.
  MandatoryExtension(attribute: String)
  /// The server's nonce does not start with the client's nonce, or adds
  /// nothing to it.
  ServerNonceMismatch(server_nonce: String)
  /// The salt is not base64.
  InvalidSalt(salt: String)
  /// The iteration count is not a whole number of 1 or more.
  InvalidIterationCount(iteration_count: String)
}

/// Why `verify_server_final` refuses the server-final-message.
pub type ServerFinalError {
  /// The server-final-message is not `v=<signature>` or `e=<error>`, with
  /// optional extensions after it.
  InvalidServerFinalMessage(message: BitArray)
  /// The server ended the exchange with an error (`e=`), for example
  /// `invalid-proof`.
  ServerReportedError(error: String)
  /// The server's signature is not the one that the password's key gives,
  /// so the server does not know the key.
  ServerSignatureMismatch
}

/// The client-first-message, and what the next step needs from it.
pub opaque type ClientFirst {
  ClientFirst(
    gs2_header: String,
    bare_message: String,
    client_nonce: String,
    channel_binding: ChannelBinding,
  )
}

/// The client-final-message, and the server signature that it expects.
pub opaque type ClientFinal {
  ClientFinal(message: String, server_signature: BitArray)
}

/// The values of a server-first-message.
type ServerChallenge {
  ServerChallenge(nonce: String, salt: BitArray, iteration_count: Int)
}

/// Starts an exchange.
///
/// ## Parameters
///
/// - `user_name`: the user name of the message. PostgreSQL ignores it and
///   uses the user of the StartupMessage, so libpq sends the empty name.
/// - `client_nonce`: random bytes from `crypto:strong_rand_bytes/1`, 18 or
///   more, new for each exchange. The message holds them as base64.
/// - `channel_binding`: the channel binding of the exchange
///
/// ## Returns
///
/// The client-first-message and what the next step needs.
pub fn client_first(
  user_name: String,
  client_nonce: BitArray,
  channel_binding: ChannelBinding,
) -> ClientFirst {
  let nonce = base64_encode(client_nonce, True)
  ClientFirst(
    gs2_header: gs2_header(channel_binding),
    bare_message: "n=" <> sasl_name(user_name) <> ",r=" <> nonce,
    client_nonce: nonce,
    channel_binding:,
  )
}

/// Gives the bytes of the client-first-message, for a SASLInitialResponse.
///
/// ## Parameters
///
/// - `first`: the result of `client_first`
///
/// ## Returns
///
/// The gs2-header and the client-first-message-bare.
pub fn client_first_message(first: ClientFirst) -> BitArray {
  <<first.gs2_header:utf8, first.bare_message:utf8>>
}

/// Reads the server-first-message and makes the client-final-message.
///
/// The password goes through SASLprep. When SASLprep refuses it, the
/// password is used as given, as PostgreSQL does: libpq's
/// `scram_init` and `pg_fe_scram_build_secret`
/// (`src/interfaces/libpq/fe-auth-scram.c`) and the server's
/// `src/backend/libpq/auth-scram.c` all fall back to the raw password, so
/// the key matches the one that the server stored.
///
/// ## Parameters
///
/// - `first`: the result of `client_first`
/// - `password`: the password
/// - `server_first_message`: the data of the server's SASLContinue
///
/// ## Returns
///
/// - `Ok(ClientFinal)`: the client-final-message and the server signature
///   to expect
/// - `Error(ServerFirstError)`: the server-first-message is not valid
pub fn client_final(
  first: ClientFirst,
  password: String,
  server_first_message: BitArray,
) -> Result(ClientFinal, ServerFirstError) {
  use text <- try(
    to_string(server_first_message)
    |> replace_error(InvalidServerFirstMessage(server_first_message)),
  )
  use challenge <- try(read_server_first(text, server_first_message))
  use _ <- try(check_nonce(challenge.nonce, first.client_nonce))
  let binding = base64_encode(channel_binding_input(first), True)
  let without_proof = "c=" <> binding <> ",r=" <> challenge.nonce
  let authentication_message = <<
    first.bare_message:utf8,
    ",",
    text:utf8,
    ",",
    without_proof:utf8,
  >>
  Ok(final_message(password, challenge, without_proof, authentication_message))
}

/// Gives the bytes of the client-final-message, for a SASLResponse.
///
/// ## Parameters
///
/// - `final`: the result of `client_final`
///
/// ## Returns
///
/// The client-final-message, with the proof.
pub fn client_final_message(final: ClientFinal) -> BitArray {
  <<final.message:utf8>>
}

/// Reads the server-final-message and checks the server's signature.
///
/// ## Parameters
///
/// - `final`: the result of `client_final`
/// - `server_final_message`: the data of the server's SASLFinal
///
/// ## Returns
///
/// - `Ok(Nil)`: the signature is the expected one, so the server knows the
///   password's key
/// - `Error(ServerFinalError)`: the server sent an error, a signature that is
///   wrong, or a message that is not valid
pub fn verify_server_final(
  final: ClientFinal,
  server_final_message: BitArray,
) -> Result(Nil, ServerFinalError) {
  let attributes = to_string(server_final_message) |> result.map(split(_, ","))
  case attributes {
    Ok(["v=" <> signature, ..]) ->
      check_signature(final, signature, server_final_message)
    Ok(["e=" <> error, ..]) -> Error(ServerReportedError(error))
    _ -> Error(InvalidServerFinalMessage(server_final_message))
  }
}

fn gs2_header(channel_binding: ChannelBinding) -> String {
  case channel_binding {
    ClientWithoutChannelBinding -> "n,,"
    ServerWithoutChannelBinding -> "y,,"
    ServerEndPoint(_) -> "p=tls-server-end-point,,"
  }
}

/// The input of the `c=` attribute: the gs2-header, then the channel
/// binding data when the exchange binds to the channel.
fn channel_binding_input(first: ClientFirst) -> BitArray {
  case first.channel_binding {
    ServerEndPoint(certificate_hash:) -> <<
      first.gs2_header:utf8,
      certificate_hash:bits,
    >>
    ClientWithoutChannelBinding | ServerWithoutChannelBinding -> <<
      first.gs2_header:utf8,
    >>
  }
}

/// A saslname of RFC 5802 section 7: `=` becomes `=3D` and `,` becomes
/// `=2C`.
fn sasl_name(user_name: String) -> String {
  user_name
  |> replace("=", "=3D")
  |> replace(",", "=2C")
}

fn read_server_first(
  text: String,
  message: BitArray,
) -> Result(ServerChallenge, ServerFirstError) {
  case split(text, ",") {
    ["m=" <> _, ..] -> Error(MandatoryExtension(text))
    ["r=" <> nonce, "s=" <> salt, "i=" <> iteration_count, ..] ->
      server_challenge(nonce, salt, iteration_count)
    _ -> Error(InvalidServerFirstMessage(message))
  }
}

fn server_challenge(
  nonce: String,
  salt: String,
  iteration_count: String,
) -> Result(ServerChallenge, ServerFirstError) {
  use salt_bytes <- try(base64_decode(salt) |> replace_error(InvalidSalt(salt)))
  use count <- try(read_iteration_count(iteration_count))
  Ok(ServerChallenge(nonce:, salt: salt_bytes, iteration_count: count))
}

fn read_iteration_count(text: String) -> Result(Int, ServerFirstError) {
  case parse(text) {
    Ok(count) if count >= 1 -> Ok(count)
    _ -> Error(InvalidIterationCount(text))
  }
}

fn check_nonce(
  server_nonce: String,
  client_nonce: String,
) -> Result(Nil, ServerFirstError) {
  let extends_client_nonce =
    starts_with(server_nonce, client_nonce)
    && string.byte_size(server_nonce) > string.byte_size(client_nonce)
  use <- guard(!extends_client_nonce, Error(ServerNonceMismatch(server_nonce)))
  Ok(Nil)
}

/// The keys of RFC 5802 section 3, the proof, and the server signature.
fn final_message(
  password: String,
  challenge: ServerChallenge,
  without_proof: String,
  authentication_message: BitArray,
) -> ClientFinal {
  let salted_password =
    pbkdf2_hmac(
      Sha256,
      scram_password(password),
      challenge.salt,
      challenge.iteration_count,
      key_length,
    )
  let client_key = hmac(Sha256, salted_password, <<"Client Key">>)
  let stored_key = hash(Sha256, client_key)
  let client_signature = hmac(Sha256, stored_key, authentication_message)
  let proof = exclusive_or(client_key, client_signature)
  let server_key = hmac(Sha256, salted_password, <<"Server Key">>)
  ClientFinal(
    message: without_proof <> ",p=" <> base64_encode(proof, True),
    server_signature: hmac(Sha256, server_key, authentication_message),
  )
}

/// The password that SCRAM hashes: the SASLprep form, or the password as
/// given when SASLprep refuses it, as PostgreSQL does (see
/// `client_final`). The refusal is not an error of the login.
fn scram_password(password: String) -> String {
  case saslprep(password) {
    Ok(prepared) -> prepared
    Error(_refused) -> password
  }
}

fn check_signature(
  final: ClientFinal,
  signature: String,
  message: BitArray,
) -> Result(Nil, ServerFinalError) {
  case base64_decode(signature) {
    Ok(received) -> compare_signature(received, final.server_signature)
    Error(Nil) -> Error(InvalidServerFinalMessage(message))
  }
}

fn compare_signature(
  received: BitArray,
  expected: BitArray,
) -> Result(Nil, ServerFinalError) {
  let same =
    byte_size(received) == byte_size(expected)
    && equal_in_constant_time(received, expected)
  use <- guard(!same, Error(ServerSignatureMismatch))
  Ok(Nil)
}
