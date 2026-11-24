//// Connecting guide: trust a private certificate authority
////
//// Starts a pool that trusts the CA certificates of one PEM file, with
//// `pog.SslVerifiedCaFile` in the config.

import dream_pog as pog
import dream_postgres/client as postgres
import gleam/otp/actor

pub fn connect_with_private_ca(
  config: postgres.Config,
  ca_file: String,
) -> Result(postgres.Connection, actor.StartError) {
  config
  |> pog.ssl(pog.SslVerifiedCaFile(ca_file))
  |> postgres.connect()
}
