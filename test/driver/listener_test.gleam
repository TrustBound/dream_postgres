//// Tests for `dream_postgres/driver/listener`, LISTEN and NOTIFY, on the
//// driver servers of PostgreSQL 16 to 19. A second connection controls
//// the server: it sends the notifications, ends the listener's backend,
//// and reads the listener's last statement from `pg_stat_activity`. A gate
//// proxy between a listener and the server keeps the connection lost while
//// a test subscribes. Each listener has its own application name and its
//// own channels, so tests that run at the same time do not meet, and no
//// test sleeps.

import dream_postgres/driver/connection.{
  Backoff, InvalidRequest, Notification, TransportRefused,
}
import dream_postgres/driver/listener.{
  ChannelTooLong, ConnectFailed, ListenFailed, ListenedAgain,
  ListenerProcessDown, ListeningLost, NotificationArrived,
  SubscriberHasNoProcess, start, stop, subscribe, supervised, unsubscribe,
}
import dream_postgres/driver/message.{ZeroByteInString}
import dream_postgres/driver/transport.{ConnectRefused}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/fake_server.{free_port}
import driver/listener_gate.{
  break_gate, open_gate, start_gate, stop_gate, wait_refused,
}
import driver/server_connection.{
  caller_answer, start_caller, start_connection, start_in_ended_owner,
}
import driver/server_listener.{
  backend_process_id, end_listener_backend, listener_config, listener_statement,
  send_notification, start_configured_listener, start_listener, subscribe_to,
  wait_for_statement,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/static_supervisor
import gleam/string.{repeat}
import matchers/extract_arrived_notification.{extract_arrived_notification}
import matchers/extract_channel_and_payload.{extract_channel_and_payload}

/// The tests of the listener.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/listener", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("subscribing", subscribe_tests()),
    group("a subscription while the connection is lost", gate_tests()),
    group("starting and stopping", start_tests()),
  ])
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("gives a notification with the channel, payload and sender", fn() {
      // Arrange
      let channel = "svc827_jobs_" <> to_string(server.version)
      let application_name = "svc827_notify_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)
      let sender = backend_process_id(control)

      // Act
      send_notification(control, channel, "hello")
      let message = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> be_equal(NotificationArrived(Notification(sender, channel, "hello")))
      |> or_fail_with("Expected the notification of the control connection")
    }),
    it("keeps a channel name exact, with capitals and quotes", fn() {
      // Arrange
      let channel = "Svc827 \"Quoted\" " <> to_string(server.version)
      let application_name = "svc827_exact_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)

      // Act
      send_notification(control, channel, "it's exact")
      let message = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> extract_arrived_notification
      |> extract_channel_and_payload
      |> be_equal(#(channel, "it's exact"))
      |> or_fail_with("Expected the notification on the exact channel")
    }),
    it("sends UNLISTEN when the last subscriber unsubscribes", fn() {
      // Arrange
      let channel = "svc827_unlisten_" <> to_string(server.version)
      let application_name = "svc827_unlisten_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscription = subscribe_to(listener, channel, process.new_subject())

      // Act
      let _unsubscribed = unsubscribe(listener, subscription)
      let statement = listener_statement(control, application_name)
      connection.stop(control)
      stop(listener)

      // Assert
      statement
      |> should
      |> be_equal("UNLISTEN \"" <> channel <> "\"")
      |> or_fail_with("Expected UNLISTEN as the last statement")
    }),
    it("keeps listening while another subscriber remains", fn() {
      // Arrange
      let channel = "svc827_shared_" <> to_string(server.version)
      let application_name = "svc827_shared_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let first = process.new_subject()
      let second = process.new_subject()
      let subscription = subscribe_to(listener, channel, first)
      let _other = subscribe_to(listener, channel, second)

      // Act
      let _unsubscribed = unsubscribe(listener, subscription)
      send_notification(control, channel, "still here")
      let message = process.receive(second, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> extract_arrived_notification
      |> extract_channel_and_payload
      |> be_equal(#(channel, "still here"))
      |> or_fail_with("Expected the notification for the second subscriber")
    }),
    it("gives no notification to the subscriber that unsubscribed", fn() {
      // Arrange
      let channel = "svc827_left_" <> to_string(server.version)
      let application_name = "svc827_left_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let first = process.new_subject()
      let second = process.new_subject()
      let subscription = subscribe_to(listener, channel, first)
      let _other = subscribe_to(listener, channel, second)

      // Act
      let _unsubscribed = unsubscribe(listener, subscription)
      send_notification(control, channel, "still here")
      let _second_message = process.receive(second, 5000)
      let first_message = process.receive(first, 0)
      connection.stop(control)
      stop(listener)

      // Assert
      first_message
      |> should
      |> be_error
      |> or_fail_with("Expected no notification for the first subscriber")
    }),
    it("removes a subscriber whose process stopped", fn() {
      // Arrange
      let channel = "svc827_down_" <> to_string(server.version)
      let application_name = "svc827_down_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)

      // Act
      let caller =
        start_caller(fn() {
          subscribe(listener, channel, process.new_subject())
        })
      let _subscribed = caller_answer(caller)
      let statement =
        wait_for_statement(
          control,
          application_name,
          "UNLISTEN \"" <> channel <> "\"",
        )
      connection.stop(control)
      stop(listener)

      // Assert
      statement
      |> should
      |> be_equal("UNLISTEN \"" <> channel <> "\"")
      |> or_fail_with("Expected UNLISTEN after the subscriber stopped")
    }),
    it("listens again after a reconnect and says so", fn() {
      // Arrange
      let channel = "svc827_again_" <> to_string(server.version)
      let application_name = "svc827_again_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)

      // Act
      end_listener_backend(control, application_name)
      let _lost = process.receive(subscriber, 5000)
      let again = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      again
      |> should
      |> be_ok
      |> be_equal(ListenedAgain(channel, Ok(Nil)))
      |> or_fail_with("Expected ListenedAgain after ListeningLost")
    }),
    it("says ListeningLost when the backend ends", fn() {
      // Arrange
      let channel = "svc827_lost_" <> to_string(server.version)
      let application_name = "svc827_lost_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)

      // Act
      end_listener_backend(control, application_name)
      let lost = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      lost
      |> should
      |> be_ok
      |> be_equal(ListeningLost)
      |> or_fail_with("Expected ListeningLost first")
    }),
    it("gives notifications after a reconnect", fn() {
      // Arrange
      let channel = "svc827_after_" <> to_string(server.version)
      let application_name = "svc827_after_" <> to_string(server.version)
      let listener = start_listener(server.port, application_name, 10)
      let control = start_connection(server.port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)

      // Act
      end_listener_backend(control, application_name)
      let _lost = process.receive(subscriber, 5000)
      let _again = process.receive(subscriber, 5000)
      send_notification(control, channel, "back")
      let message = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> extract_arrived_notification
      |> extract_channel_and_payload
      |> be_equal(#(channel, "back"))
      |> or_fail_with("Expected the notification on the new session")
    }),
  ])
}

// Subscribing -----------------------------------------------------------------

fn subscribe_tests() {
  [
    it("gives a notification only to the subscribers of its channel", fn() {
      // Arrange
      let port = first_driver_server.port
      let listener = start_listener(port, "svc827_routing", 10)
      let control = start_connection(port)
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_routing_one", first)
      let _second = subscribe_to(listener, "svc827_routing_two", second)

      // Act
      send_notification(control, "svc827_routing_one", "one")
      let message = process.receive(first, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> extract_arrived_notification
      |> extract_channel_and_payload
      |> be_equal(#("svc827_routing_one", "one"))
      |> or_fail_with("Expected the notification on the first channel")
    }),
    it("gives no notification to a subscriber of another channel", fn() {
      // Arrange
      let port = first_driver_server.port
      let listener = start_listener(port, "svc827_other", 10)
      let control = start_connection(port)
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_other_one", first)
      let _second = subscribe_to(listener, "svc827_other_two", second)

      // Act
      send_notification(control, "svc827_other_one", "one")
      let _first_message = process.receive(first, 5000)
      let second_message = process.receive(second, 0)
      connection.stop(control)
      stop(listener)

      // Assert
      second_message
      |> should
      |> be_error
      |> or_fail_with("Expected no notification on the second channel")
    }),
    it("refuses a channel name of more than 63 bytes", fn() {
      // Arrange
      let channel = repeat("a", 64)
      let listener = start_listener(first_driver_server.port, "svc827_long", 10)

      // Act
      let answer = subscribe(listener, channel, process.new_subject())
      stop(listener)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ChannelTooLong(channel))
      |> or_fail_with("Expected ChannelTooLong")
    }),
    it("takes a channel name of 63 bytes", fn() {
      // Arrange
      let channel = "svc827_" <> repeat("b", 56)
      let port = first_driver_server.port
      let listener = start_listener(port, "svc827_longest", 10)
      let control = start_connection(port)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, channel, subscriber)

      // Act
      send_notification(control, channel, "fits")
      let message = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> extract_arrived_notification
      |> extract_channel_and_payload
      |> be_equal(#(channel, "fits"))
      |> or_fail_with("Expected the notification on the longest channel")
    }),
    it("refuses a named subject that no process has", fn() {
      // Arrange
      let subscriber = process.named_subject(process.new_name("svc827"))
      let listener =
        start_listener(first_driver_server.port, "svc827_named", 10)

      // Act
      let answer = subscribe(listener, "svc827_named", subscriber)
      stop(listener)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(SubscriberHasNoProcess)
      |> or_fail_with("Expected SubscriberHasNoProcess")
    }),
    it("refuses a channel that the LISTEN cannot carry", fn() {
      // Arrange
      let listener = start_listener(first_driver_server.port, "svc827_zero", 10)

      // Act
      let answer = subscribe(listener, "svc827\u{0}zero", process.new_subject())
      stop(listener)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ListenFailed(InvalidRequest(ZeroByteInString("query"))))
      |> or_fail_with("Expected ListenFailed with the zero byte")
    }),
    it("keeps a subscription made while the connection is lost", fn() {
      // Arrange
      let port = first_driver_server.port
      let listener = start_listener(port, "svc827_lost", 60_000)
      let control = start_connection(port)
      let subscriber = process.new_subject()

      // Act
      end_listener_backend(control, "svc827_lost")
      let _subscription = subscribe(listener, "svc827_lost", subscriber)
      let message = process.receive(subscriber, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> be_equal(ListeningLost)
      |> or_fail_with("Expected ListeningLost at once")
    }),
    it("tells a new subscriber of a lost channel at once", fn() {
      // Arrange
      let port = first_driver_server.port
      let listener = start_listener(port, "svc827_joined", 60_000)
      let control = start_connection(port)
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_joined", first)

      // Act
      end_listener_backend(control, "svc827_joined")
      let _lost = process.receive(first, 5000)
      let _second = subscribe(listener, "svc827_joined", second)
      let message = process.receive(second, 5000)
      connection.stop(control)
      stop(listener)

      // Assert
      message
      |> should
      |> be_ok
      |> be_equal(ListeningLost)
      |> or_fail_with("Expected ListeningLost for the new subscriber")
    }),
    it("ends a subscription that ended already without an error", fn() {
      // Arrange
      let listener =
        start_listener(first_driver_server.port, "svc827_twice", 10)
      let subscription =
        subscribe_to(listener, "svc827_twice", process.new_subject())

      // Act
      let _first_answer = unsubscribe(listener, subscription)
      let answer = unsubscribe(listener, subscription)
      stop(listener)

      // Assert
      answer
      |> should
      |> be_ok
      |> or_fail_with("Expected Ok for the second unsubscribe")
    }),
  ]
}

// A subscription while the connection is lost ---------------------------------

/// A gate keeps the connection lost while a second subscriber comes on a
/// second channel, and refuses one reconnect. Both channels listen again
/// when the gate opens.
fn gate_tests() {
  [
    it("listens at the reconnect for a subscription made while lost", fn() {
      // Arrange
      let #(port, gate) = start_gate(first_driver_server.port)
      let listener =
        start_configured_listener(listener_config(
          port,
          "svc827_gate",
          Backoff(10, 50),
        ))
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_gate_one", first)

      // Act
      break_gate(gate)
      let _first_lost = process.receive(first, 5000)
      let _second = subscribe(listener, "svc827_gate_two", second)
      let _second_lost = process.receive(second, 5000)
      wait_refused(gate)
      open_gate(gate)
      let _first_again = process.receive(first, 5000)
      let second_again = process.receive(second, 5000)
      stop(listener)
      stop_gate(gate)

      // Assert
      second_again
      |> should
      |> be_ok
      |> be_equal(ListenedAgain("svc827_gate_two", Ok(Nil)))
      |> or_fail_with("Expected the second channel to listen again")
    }),
    it("listens again for a subscription made before the loss", fn() {
      // Arrange
      let #(port, gate) = start_gate(first_driver_server.port)
      let listener =
        start_configured_listener(listener_config(
          port,
          "svc827_gate_before",
          Backoff(10, 50),
        ))
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_gate_before_one", first)

      // Act
      break_gate(gate)
      let _first_lost = process.receive(first, 5000)
      let _second = subscribe(listener, "svc827_gate_before_two", second)
      let _second_lost = process.receive(second, 5000)
      wait_refused(gate)
      open_gate(gate)
      let first_again = process.receive(first, 5000)
      let _second_again = process.receive(second, 5000)
      stop(listener)
      stop_gate(gate)

      // Assert
      first_again
      |> should
      |> be_ok
      |> be_equal(ListenedAgain("svc827_gate_before_one", Ok(Nil)))
      |> or_fail_with("Expected the first channel to listen again")
    }),
    it("gives ListeningLost to a subscription made while lost", fn() {
      // Arrange
      let #(port, gate) = start_gate(first_driver_server.port)
      let listener =
        start_configured_listener(listener_config(
          port,
          "svc827_gate_while",
          Backoff(10, 50),
        ))
      let first = process.new_subject()
      let second = process.new_subject()
      let _first = subscribe_to(listener, "svc827_gate_while_one", first)

      // Act
      break_gate(gate)
      let _first_lost = process.receive(first, 5000)
      let _second = subscribe(listener, "svc827_gate_while_two", second)
      let second_lost = process.receive(second, 5000)
      wait_refused(gate)
      open_gate(gate)
      let _first_again = process.receive(first, 5000)
      let _second_again = process.receive(second, 5000)
      stop(listener)
      stop_gate(gate)

      // Assert
      second_lost
      |> should
      |> be_ok
      |> be_equal(ListeningLost)
      |> or_fail_with("Expected ListeningLost for the second subscriber")
    }),
  ]
}

// Starting and stopping -------------------------------------------------------

fn start_tests() {
  [
    it("gives ConnectFailed for a port with no server", fn() {
      // Arrange
      let config =
        listener_config(free_port(), "svc827_refused", Backoff(10, 60_000))

      // Act
      let started = start(config)

      // Assert
      started
      |> should
      |> be_error
      |> be_equal(ConnectFailed(TransportRefused(ConnectRefused)))
      |> or_fail_with("Expected ConnectFailed")
    }),
    it("gives ListenerProcessDown to a subscribe after the stop", fn() {
      // Arrange
      let listener =
        start_listener(first_driver_server.port, "svc827_stopped", 10)
      let subscriber = process.new_subject()
      let _subscription = subscribe_to(listener, "svc827_stopped", subscriber)

      // Act
      stop(listener)
      let answer = subscribe(listener, "svc827_stopped", subscriber)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ListenerProcessDown)
      |> or_fail_with("Expected ListenerProcessDown")
    }),
    it("gives ListenerProcessDown to an unsubscribe after the stop", fn() {
      // Arrange
      let listener =
        start_listener(first_driver_server.port, "svc827_stopped_end", 10)
      let subscription =
        subscribe_to(listener, "svc827_stopped_end", process.new_subject())

      // Act
      stop(listener)
      let answer = unsubscribe(listener, subscription)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ListenerProcessDown)
      |> or_fail_with("Expected ListenerProcessDown")
    }),
    it("starts under a supervisor", fn() {
      // Arrange
      let config =
        listener_config(
          first_driver_server.port,
          "svc827_supervised",
          Backoff(10, 60_000),
        )
      let supervisor =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(supervised(config))

      // Act
      let started =
        start_in_ended_owner(fn() { static_supervisor.start(supervisor) })

      // Assert
      started
      |> should
      |> be_ok
      |> be_ok
      |> or_fail_with("Expected the supervisor to start the listener")
    }),
  ]
}
