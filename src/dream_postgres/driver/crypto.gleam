//// The hash functions that the login needs, from the Erlang `crypto`
//// application.
////
//// The functions are pure: each one gives the same bytes for the same
//// input. The application must start `crypto`, so `gleam.toml` names it in
//// `extra_applications`.
////
//// This module is internal to dream_postgres.

/// A hash function of the Erlang `crypto` application. Each name is the
/// atom that `crypto` uses for it.
pub type HashAlgorithm {
  /// MD5, for the MD5 login only.
  Md5
  /// SHA-224.
  Sha224
  /// SHA-256.
  Sha256
  /// SHA-384.
  Sha384
  /// SHA-512.
  Sha512
}

/// The kind of message authentication code that `crypto:mac/4` makes.
type MacKind {
  Hmac
}

/// Hashes bytes.
///
/// ## Parameters
///
/// - `algorithm`: the hash function
/// - `data`: the bytes to hash
///
/// ## Returns
///
/// The digest of `data`.
@external(erlang, "crypto", "hash")
pub fn hash(algorithm: HashAlgorithm, data: BitArray) -> BitArray

/// Makes the HMAC of bytes (RFC 2104).
///
/// ## Parameters
///
/// - `algorithm`: the hash function of the HMAC
/// - `key`: the key
/// - `data`: the bytes to authenticate
///
/// ## Returns
///
/// The HMAC of `data` with `key`.
pub fn hmac(
  algorithm: HashAlgorithm,
  key: BitArray,
  data: BitArray,
) -> BitArray {
  mac(Hmac, algorithm, key, data)
}

@external(erlang, "crypto", "mac")
fn mac(
  kind: MacKind,
  algorithm: HashAlgorithm,
  key: BitArray,
  data: BitArray,
) -> BitArray

/// Derives a key from a password with PBKDF2 and HMAC (RFC 8018). SCRAM
/// calls this function `Hi` (RFC 5802 section 2.2).
///
/// ## Parameters
///
/// - `algorithm`: the hash function of the HMAC
/// - `password`: the password, as UTF-8
/// - `salt`: the salt
/// - `iterations`: the iteration count, 1 or more
/// - `key_length`: the length of the key in bytes
///
/// ## Returns
///
/// The derived key.
@external(erlang, "crypto", "pbkdf2_hmac")
pub fn pbkdf2_hmac(
  algorithm: HashAlgorithm,
  password: String,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> BitArray

/// Gives the exclusive or of two byte strings of the same length.
///
/// ## Parameters
///
/// - `first`: the first bytes
/// - `second`: the second bytes, as long as `first`
///
/// ## Returns
///
/// Each byte of `first` exclusive-ored with the byte of `second` at the
/// same position.
@external(erlang, "crypto", "exor")
pub fn exclusive_or(first: BitArray, second: BitArray) -> BitArray

/// Compares two byte strings of the same length in a time that does not
/// depend on where they differ.
///
/// ## Parameters
///
/// - `first`: the first bytes
/// - `second`: the second bytes, as long as `first`
///
/// ## Returns
///
/// `True` when the bytes are equal.
@external(erlang, "crypto", "hash_equals")
pub fn equal_in_constant_time(first: BitArray, second: BitArray) -> Bool

/// Random bytes from the operating system's secure source, for example the
/// client nonce of a SCRAM login.
///
/// ## Parameters
///
/// - `count`: how many bytes
///
/// ## Returns
///
/// `count` random bytes.
@external(erlang, "crypto", "strong_rand_bytes")
pub fn random_bytes(count: Int) -> BitArray
