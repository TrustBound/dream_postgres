//// Proves the first event of a connection process.

import dream_postgres/driver/connection.{Connected}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import driver/server_connection.{
  connection_config, next_event, start_configured, stop_connection,
  watched_config,
}
import driver/servers.{first_driver_server}
import gleam/erlang/process
import gleam/result.{map_error, try}

/// The tests of the events of a connection process.
pub fn tests() -> TestSuite {
  describe("the events of a connection process", [
    it("tells Connected first, once the process logged in", fn() {
      // Act
      let first_event = {
        let events = process.new_subject()
        use config <- try(connection_config(first_driver_server.port))
        use connection <- try(
          start_configured(watched_config(config, events, 10)),
        )
        let event = next_event(events) |> map_error(fn(_nothing) { "no event" })
        use Nil <- try(stop_connection(connection))
        event
      }

      // Assert
      first_event
      |> should
      |> be_equal(Ok(Connected))
      |> or_fail_with("Expected Connected as the first event")
    }),
  ])
}
