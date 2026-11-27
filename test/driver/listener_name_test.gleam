//// Proves a listener under a name: a handle of the name works, stays
//// valid when the supervisor starts the listener again, and gives
//// `ListenerProcessDown` while no listener has the name.

import dream_postgres/driver/listener.{ListenerProcessDown, from_name, subscribe}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{describe, it}
import driver/server_named_listener.{
  type NamedListener, listener_restart_type, restart_listener,
  start_named_listener, stop_named_listener,
}
import driver/servers.{first_driver_server}
import gleam/erlang/process
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

/// The tests of a listener under a name.
pub fn tests() -> TestSuite {
  suite.group("a listener under a name", [
    named_tests(),
    restarted_tests(),
    unit.describe("with no listener under the name", [
      unit.it("gives ListenerProcessDown for a subscribe", fn() {
        // Arrange
        let handle = from_name(process.new_name("listener_test_unused"))

        // Act
        let answer =
          subscribe(handle, "svc_unused", process.new_subject())
          |> replace(Nil)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenerProcessDown)
        |> or_fail_with("Expected ListenerProcessDown")
      }),
    ]),
  ])
}

fn named_tests() -> TestSuite {
  describe(
    "under a supervisor",
    context.setup(
      setup: fn() { start_named_listener(first_driver_server) },
      teardown: stop_named_listener,
    ),
    [
      it("subscribes through a handle of its name", fn(named: NamedListener) {
        // Act
        let answer =
          subscribe(named.handle, "svc_named_first", process.new_subject())
          |> replace(Nil)
          |> map_error(inspect)

        // Assert
        answer
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("Expected a subscription through the handle")
      }),
      it("is a transient child of its supervisor", fn(named: NamedListener) {
        // Act
        let restart = listener_restart_type(named.supervisor)

        // Assert
        restart
        |> should
        |> be_ok
        |> be_equal("transient")
        |> or_fail_with("Expected a transient child")
      }),
    ],
  )
}

/// The restart has a listener of its own, so no other test of the group
/// meets the listener while it is down.
fn restarted_tests() -> TestSuite {
  describe(
    "started again by its supervisor",
    context.setup(
      setup: fn() { start_named_listener(first_driver_server) },
      teardown: stop_named_listener,
    ),
    [
      it(
        "subscribes through the same handle after a restart",
        fn(named: NamedListener) {
          // Act
          let answer = {
            use Nil <- try(restart_listener(named.supervisor))
            subscribe(named.handle, "svc_named_again", process.new_subject())
            |> replace(Nil)
            |> map_error(inspect)
          }

          // Assert
          answer
          |> should
          |> be_equal(Ok(Nil))
          |> or_fail_with("Expected a subscription to the new listener")
        },
      ),
    ],
  )
}
