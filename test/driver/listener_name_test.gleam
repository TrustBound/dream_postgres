//// Proves a listener under a name: a handle of the name works, stays
//// valid when the supervisor starts the listener again, and gives
//// `ListenerProcessDown` while no listener has the name. A crash of the
//// session keeps the subscriptions, and a crash of the registry reaches a
//// monitor of it.

import dream_postgres/driver/listener.{
  ListenerProcessDown, Listening, NotListening, from_name, monitor_registry,
  subscribe,
}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{describe, it}
import driver/server_named_listener.{
  type CrashOutcome, type GatedNamedListener, type NamedListener, crash_registry,
  listener_restart_type, restart_listener, session_crash_setup,
  start_gated_named_listener, start_named_listener, stop_gated_named_listener,
  stop_named_listener, subscribe_before_up_report,
  subscribe_during_unreported_loss,
}
import driver/servers.{first_driver_server}
import fixtures/identity_sink.{identity_sink}
import gleam/erlang/process
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}
import matchers/extract_arrived_notification.{extract_arrived_notification}
import matchers/extract_channel_and_payload.{extract_channel_and_payload}

/// The tests of a listener under a name.
pub fn tests() -> TestSuite {
  suite.group("a listener under a name", [
    named_tests(),
    restarted_tests(),
    session_crash_tests(),
    registry_crash_tests(),
    up_rule_tests(),
    unreported_loss_tests(),
    unit.describe("with no listener under the name", [
      unit.it("gives ListenerProcessDown for a subscribe", fn() {
        // Arrange
        let handle = from_name(process.new_name("listener_test_unused"))

        // Act
        let answer =
          subscribe(handle, "svc_unused", identity_sink(process.new_subject()))
          |> replace(Nil)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenerProcessDown)
        |> or_fail_with("Expected ListenerProcessDown")
      }),
      unit.it("gives ListenerProcessDown for a monitor of the registry", fn() {
        // Arrange
        let handle = from_name(process.new_name("listener_test_unmonitored"))

        // Act
        let answer = monitor_registry(handle) |> replace(Nil)

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
          subscribe(
            named.handle,
            "svc_named_first",
            identity_sink(process.new_subject()),
          )
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
            subscribe(
              named.handle,
              "svc_named_again",
              identity_sink(process.new_subject()),
            )
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

/// One act: the session crashes while the subscriber listens. Each test
/// checks one message that the subscriber got after the crash.
fn session_crash_tests() -> TestSuite {
  describe(
    "with a session that crashes",
    session_crash_setup(first_driver_server),
    [
      it("says NotListening at the crash", fn(outcome: CrashOutcome) {
        outcome.crash.lost
        |> should
        |> be_ok
        |> be_equal(NotListening)
        |> or_fail_with("Expected NotListening when the session stopped")
      }),
      it(
        "says Listening once the new session listens, with no new subscribe",
        fn(outcome: CrashOutcome) {
          outcome.crash.again
          |> should
          |> be_ok
          |> be_equal(Listening(outcome.gated.channel))
          |> or_fail_with("Expected Listening from the new session")
        },
      ),
      it(
        "gives a notification sent after the new session listens",
        fn(outcome: CrashOutcome) {
          outcome.crash.notified
          |> should
          |> be_ok
          |> extract_arrived_notification
          |> extract_channel_and_payload
          |> be_equal(#(outcome.gated.channel, "again"))
          |> or_fail_with("Expected the notification on the new session")
        },
      ),
    ],
  )
}

fn registry_crash_tests() -> TestSuite {
  describe(
    "with a registry that crashes",
    context.setup(
      setup: fn() { start_named_listener(first_driver_server) },
      teardown: stop_named_listener,
    ),
    [
      it("fires a monitor of the registry", fn(named: NamedListener) {
        // Act
        let reason = crash_registry(named)

        // Assert
        reason
        |> should
        |> be_ok
        |> be_equal(process.Killed)
        |> or_fail_with("Expected the Down of the killed registry")
      }),
    ],
  )
}

/// A subscriber gets `NotListening` first if and only if the session is
/// not up when the registry handles its subscribe: here the connection
/// has logged in, but the registry has not handled the report of it yet.
fn up_rule_tests() -> TestSuite {
  describe(
    "a subscribe that the registry handles before the report of the login",
    context.setup(
      setup: fn() { start_gated_named_listener(first_driver_server) },
      teardown: stop_gated_named_listener,
    ),
    [
      it("gives NotListening, then Listening", fn(gated: GatedNamedListener) {
        subscribe_before_up_report(gated)
        |> should
        |> be_equal(Ok(#(NotListening, Listening(gated.channel))))
        |> or_fail_with("Expected NotListening, then Listening")
      }),
    ],
  )
}

/// A `LISTEN` that meets a loss the registry has not handled yet gives
/// `NotListening`, then `Listening` after the reconnect.
fn unreported_loss_tests() -> TestSuite {
  describe(
    "a subscribe whose LISTEN meets a loss that the registry has not handled",
    context.setup(
      setup: fn() { start_gated_named_listener(first_driver_server) },
      teardown: stop_gated_named_listener,
    ),
    [
      it("gives NotListening, then Listening", fn(gated: GatedNamedListener) {
        subscribe_during_unreported_loss(gated)
        |> should
        |> be_equal(Ok(#(NotListening, Listening(gated.channel <> "_second"))))
        |> or_fail_with("Expected NotListening, then Listening")
      }),
    ],
  )
}
