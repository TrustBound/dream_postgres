//// Connecting guide: trust a private certificate authority
////
//// Starts a pool that trusts the CA certificates of one PEM file, with
//// `dream_postgres_client.SslVerifiedCaFile` in the config.

import dream_postgres/client as postgres
import dream_postgres_client
import gleam/otp/actor

pub fn connect_with_private_ca(
  config: postgres.Config,
  ca_file: String,
) -> Result(postgres.Connection, actor.StartError) {
  config
  |> dream_postgres_client.ssl(dream_postgres_client.SslVerifiedCaFile(ca_file))
  |> postgres.connect()
}
