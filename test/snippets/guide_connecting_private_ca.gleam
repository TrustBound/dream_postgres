//// Connecting guide: trust a private certificate authority
////
//// Loads the CA certificates of a PEM file into OTP's CA list, and then
//// starts a pool from a URL with sslmode=verify-full.

import dream_postgres/client as postgres
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/result
import pog

pub fn connect_with_private_ca(
  url: String,
  ca_file: String,
) -> Result(pog.Connection, String) {
  case load_ca_certificates(ca_file) == atom.to_dynamic(atom.create("ok")) {
    False -> Error("Can't read the CA certificates in " <> ca_file)
    True ->
      postgres.from_url(url)
      |> result.replace_error("The pool did not start")
  }
}

// Replaces the CA list of the whole BEAM with the certificates of the
// file. Pog reads that list when a pool starts.
@external(erlang, "public_key", "cacerts_load")
fn load_ca_certificates(path: String) -> Dynamic
