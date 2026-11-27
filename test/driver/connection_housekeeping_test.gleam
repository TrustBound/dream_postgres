//// Proves the errors of `run_housekeeping` and `run_housekeeping_script`
//// on a proxied connection to the first driver server. The proxy answers
//// in place of the server, as no PostgreSQL server answers a housekeeping
//// statement, or breaks the connection.

import dream_postgres/driver/connection.{
  ConnectionEnded, ConnectionLost, HousekeepingAnswerUnexpected,
  HousekeepingFailed, SocketFailed, run_housekeeping, run_housekeeping_script,
}
import dream_postgres/driver/housekeeping_sql.{catalog_load, health_check}
import dream_postgres/driver/transport.{SocketClosed}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/proxy.{answer_next_request, close_client, freeze, next_kept}
import driver/server_connection.{
  type ProxiedConnection, break_session, caller_answer, proxied_setup,
  start_caller, start_test_proxied, stop_proxied,
}
import driver/server_listener.{result_then_refusal_bytes}
import driver/servers.{first_driver_server}
import gleam/result.{try}

/// The tests of the housekeeping statements of a connection.
pub fn tests() -> TestSuite {
  describe(
    "the housekeeping statements of a proxied connection",
    proxied_setup(first_driver_server, 60_000),
    [
      after_each(stop_proxied),
      before_each(start_test_proxied(first_driver_server, 60_000)),
      it(
        "gives HousekeepingAnswerUnexpected when a housekeeping run gets a COPY",
        fn(proxied: ProxiedConnection) {
          // Arrange
          answer_next_request(proxied.proxy, <<
            "1", 4:32, "2", 4:32, "n", 4:32, "H", 7:32, 0, 0:16, "c", 4:32, "C",
            11:32, "COPY 0":utf8, 0, "Z", 5:32, "I",
          >>)

          // Act
          let answer = run_housekeeping(proxied.connection, catalog_load, 5000)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(HousekeepingAnswerUnexpected)
          |> or_fail_with("Expected HousekeepingAnswerUnexpected")
        },
      ),
      it(
        "gives HousekeepingAnswerUnexpected when a housekeeping script gets two answers",
        fn(proxied: ProxiedConnection) {
          // Arrange
          answer_next_request(proxied.proxy, result_then_refusal_bytes())

          // Act
          let answer =
            run_housekeeping_script(proxied.connection, health_check, 5000)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(HousekeepingAnswerUnexpected)
          |> or_fail_with("Expected HousekeepingAnswerUnexpected")
        },
      ),
      it(
        "fails a running housekeeping run when the network closes",
        fn(proxied: ProxiedConnection) {
          // Act
          let answer = {
            let kept = freeze(proxied.proxy)
            let running =
              start_caller(fn() {
                run_housekeeping(proxied.connection, catalog_load, 5000)
              })
            use _run <- try(next_kept(kept))
            close_client(proxied.proxy)
            caller_answer(running)
          }

          // Assert
          answer
          |> should
          |> be_ok
          |> be_error
          |> be_equal(
            HousekeepingFailed(
              ConnectionEnded(ConnectionLost(SocketFailed(SocketClosed))),
            ),
          )
          |> or_fail_with("Expected the loss for the running housekeeping run")
        },
      ),
      lost_session_tests(),
    ],
  )
}

fn lost_session_tests() -> ContextNode(ProxiedConnection) {
  group("after the network closed", [
    before_each(break_session(close_client)),
    it(
      "fails a housekeeping script while the connection is lost",
      fn(proxied: ProxiedConnection) {
        // Act
        let answer =
          run_housekeeping_script(proxied.connection, health_check, 5000)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(
          HousekeepingFailed(
            ConnectionEnded(ConnectionLost(SocketFailed(SocketClosed))),
          ),
        )
        |> or_fail_with("Expected the error of the loss")
      },
    ),
  ])
}
