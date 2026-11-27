//// Connections whose notices go to a subscriber of the test, and the wait
//// for the next notice.

import dream_postgres/driver/connection.{type Connection, ConnectionConfig}
import dream_postgres/internal/cell.{type ServerReport}
import driver/server_connection.{connection_config, start_configured}
import fixtures/identity_sink.{identity_sink}
import gleam/erlang/process.{type Subject}
import gleam/option.{Some}
import gleam/result.{map, replace_error, try}

/// Starts a connection to the server on `port` that sends each notice to
/// `notices`.
pub fn start_noticed_connection(
  port: Int,
  notices: Subject(ServerReport),
) -> Result(Connection, String) {
  connection_config(port)
  |> map(fn(config) {
    ConnectionConfig(..config, notices: Some(identity_sink(notices)))
  })
  |> try(start_configured)
}

/// The next notice that `notices` gets, waiting at most 5 seconds.
pub fn next_notice(
  notices: Subject(ServerReport),
) -> Result(ServerReport, String) {
  process.receive(notices, 5000)
  |> replace_error("no notice within 5 seconds")
}
