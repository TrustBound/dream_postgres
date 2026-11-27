//// Tests for `dream_postgres/driver/listener`, LISTEN and NOTIFY, on the
//// driver servers of PostgreSQL 16 to 19. A second connection controls
//// the server: it sends the notifications, ends the listener's backend,
//// and reads the listener's last statement from `pg_stat_activity`. A gate
//// proxy between a listener and the server keeps the connection lost while
//// a test subscribes. Each listener has its own application name and its
//// own channels, so tests that run at the same time do not meet, and no
//// test sleeps. Setup hooks start each listener and stop it after the
//// test.

import dream_postgres/driver/connection.{
  Backoff, InvalidRequest, Notification, TransportRefused,
}
import dream_postgres/driver/listener.{
  type ListenerConfig, type ListenerMessage, ChannelTooLong, ConnectFailed,
  ListenFailed, ListenedAgain, ListenerProcessDown, ListeningLost,
  NotificationArrived, SubscriberHasNoProcess, start, stop, subscribe,
  supervised, unsubscribe,
}
import dream_postgres/driver/message.{ZeroByteInString}
import dream_postgres/driver/transport.{ConnectRefused}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{after_each, before_each, describe, group, it}
import driver/fake_server.{free_port}
import driver/listener_gate.{break_gate, open_gate, wait_refused}
import driver/server_connection.{
  caller_answer, start_caller, start_in_ended_owner,
}
import driver/server_listener.{
  type GatedListener, type GatedOutcome, type ListenerOutcome,
  type ListenerSession, type SubscribedListener, end_session_backend,
  end_subscription, gated_act_setup, listener_act_setup, listener_config,
  listener_session_setup, listener_statement, receive_message, send_notification,
  start_test_listener, start_test_subscribed, stop_listener_session,
  stop_subscribed_listener, subscribe_and_unsubscribe_first, subscribe_first,
  subscribe_first_to, subscribe_second, subscribe_second_to_other, subscribe_to,
  subscribed_setup, wait_for_first_message, wait_for_statement,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/static_supervisor
import gleam/result.{flatten, try}
import gleam/string.{repeat}
import matchers/extract_arrived_notification.{extract_arrived_notification}
import matchers/extract_channel_and_payload.{extract_channel_and_payload}

/// The tests of the listener. The describes run one after the other; the
/// tests of one group run at the same time.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/listener", [
    session_tests(),
    suite.group(
      "listening again after the backend ends",
      map(driver_servers(), reconnect_tests),
    ),
    gate_tests(),
    subscription_tests(),
    start_tests(),
  ])
}

// With a listener of its own --------------------------------------------------

fn session_tests() -> TestSuite {
  describe(
    "with a listener of its own",
    listener_session_setup(first_driver_server),
    [
      after_each(stop_listener_session),
      group("on each driver server", map(driver_servers(), server_tests)),
      group("subscribing", subscribe_tests()),
      group("while the connection is lost", lost_tests()),
    ],
  )
}

fn server_tests(server: Server) {
  let exact_channel = "Svc827 \"Quoted\" " <> to_string(server.version)
  group("PostgreSQL " <> to_string(server.version), [
    before_each(start_test_listener(server, 10)),
    group("with one subscriber", [
      before_each(subscribe_first),
      it(
        "gives a notification with the channel, payload and sender",
        fn(session: ListenerSession) {
          // Act
          let message = {
            use _sent <- try(send_notification(
              session.control,
              session.channel,
              "hello",
            ))
            receive_message(session.first)
          }

          // Assert
          message
          |> should
          |> be_ok
          |> be_equal(
            NotificationArrived(Notification(
              session.control_process_id,
              session.channel,
              "hello",
            )),
          )
          |> or_fail_with("Expected the notification of the control connection")
        },
      ),
    ]),
    group("on an exact channel", [
      before_each(subscribe_first_to(exact_channel)),
      it(
        "keeps a channel name exact, with capitals and quotes",
        fn(session: ListenerSession) {
          // Act
          let message = {
            use _sent <- try(send_notification(
              session.control,
              exact_channel,
              "it's exact",
            ))
            receive_message(session.first)
          }

          // Assert
          message
          |> should
          |> be_ok
          |> extract_arrived_notification
          |> extract_channel_and_payload
          |> be_equal(#(exact_channel, "it's exact"))
          |> or_fail_with("Expected the notification on the exact channel")
        },
      ),
    ]),
    group("after the only subscriber left", [
      before_each(subscribe_and_unsubscribe_first),
      it(
        "sends UNLISTEN when the last subscriber unsubscribes",
        fn(session: ListenerSession) {
          // Act
          let statement =
            listener_statement(session.control, session.application_name)

          // Assert
          statement
          |> should
          |> be_ok
          |> be_equal("UNLISTEN \"" <> session.channel <> "\"")
          |> or_fail_with("Expected UNLISTEN as the last statement")
        },
      ),
    ]),
    group("after one of two subscribers left", remaining_subscriber_tests()),
    it(
      "removes a subscriber whose process stopped",
      fn(session: ListenerSession) {
        // Arrange
        let unlisten = "UNLISTEN \"" <> session.channel <> "\""

        // Act
        let statement = {
          let caller =
            start_caller(fn() {
              subscribe_to(
                session.listener,
                session.channel,
                process.new_subject(),
              )
            })
          use _subscription <- try(caller_answer(caller) |> flatten)
          wait_for_statement(
            session.control,
            session.application_name,
            unlisten,
          )
        }

        // Assert
        statement
        |> should
        |> be_ok
        |> be_equal(unlisten)
        |> or_fail_with("Expected UNLISTEN after the subscriber stopped")
      },
    ),
  ])
}

fn remaining_subscriber_tests() {
  [
    before_each(subscribe_second),
    before_each(subscribe_and_unsubscribe_first),
    it(
      "keeps listening while another subscriber remains",
      fn(session: ListenerSession) {
        // Act
        let message = {
          use _sent <- try(send_notification(
            session.control,
            session.channel,
            "still here",
          ))
          receive_message(session.second)
        }

        // Assert
        message
        |> should
        |> be_ok
        |> extract_arrived_notification
        |> extract_channel_and_payload
        |> be_equal(#(session.channel, "still here"))
        |> or_fail_with("Expected the notification for the second subscriber")
      },
    ),
    it(
      "gives no notification to the subscriber that unsubscribed",
      fn(session: ListenerSession) {
        // Act
        let first_message = {
          use _sent <- try(send_notification(
            session.control,
            session.channel,
            "still here",
          ))
          use _second_message <- try(receive_message(session.second))
          Ok(process.receive(session.first, 0))
        }

        // Assert
        first_message
        |> should
        |> be_ok
        |> be_error
        |> or_fail_with("Expected no notification for the first subscriber")
      },
    ),
  ]
}

// Subscribing -----------------------------------------------------------------

fn subscribe_tests() {
  let longest_channel = "svc827_" <> repeat("b", 56)
  [
    before_each(start_test_listener(first_driver_server, 10)),
    group("on two channels", two_channel_tests()),
    group("on a channel of 63 bytes", [
      before_each(subscribe_first_to(longest_channel)),
      it("takes a channel name of 63 bytes", fn(session: ListenerSession) {
        // Act
        let message = {
          use _sent <- try(send_notification(
            session.control,
            longest_channel,
            "fits",
          ))
          receive_message(session.first)
        }

        // Assert
        message
        |> should
        |> be_ok
        |> extract_arrived_notification
        |> extract_channel_and_payload
        |> be_equal(#(longest_channel, "fits"))
        |> or_fail_with("Expected the notification on the longest channel")
      }),
    ]),
    it(
      "refuses a channel name of more than 63 bytes",
      fn(session: ListenerSession) {
        // Arrange
        let channel = repeat("a", 64)

        // Act
        let answer = subscribe(session.listener, channel, process.new_subject())

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ChannelTooLong(channel))
        |> or_fail_with("Expected ChannelTooLong")
      },
    ),
    it(
      "refuses a named subject that no process has",
      fn(session: ListenerSession) {
        // Arrange
        let subscriber = process.named_subject(process.new_name("svc827"))

        // Act
        let answer = subscribe(session.listener, session.channel, subscriber)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(SubscriberHasNoProcess)
        |> or_fail_with("Expected SubscriberHasNoProcess")
      },
    ),
    it(
      "refuses a channel that the LISTEN cannot carry",
      fn(session: ListenerSession) {
        // Act
        let answer =
          subscribe(session.listener, "svc827\u{0}zero", process.new_subject())

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenFailed(InvalidRequest(ZeroByteInString("query"))))
        |> or_fail_with("Expected ListenFailed with the zero byte")
      },
    ),
  ]
}

fn two_channel_tests() {
  [
    before_each(subscribe_first),
    before_each(subscribe_second_to_other),
    it(
      "gives a notification only to the subscribers of its channel",
      fn(session: ListenerSession) {
        // Act
        let message = {
          use _sent <- try(send_notification(
            session.control,
            session.channel,
            "one",
          ))
          receive_message(session.first)
        }

        // Assert
        message
        |> should
        |> be_ok
        |> extract_arrived_notification
        |> extract_channel_and_payload
        |> be_equal(#(session.channel, "one"))
        |> or_fail_with("Expected the notification on the first channel")
      },
    ),
    it(
      "gives no notification to a subscriber of another channel",
      fn(session: ListenerSession) {
        // Act
        let second_message = {
          use _sent <- try(send_notification(
            session.control,
            session.channel,
            "one",
          ))
          use _first_message <- try(receive_message(session.first))
          Ok(process.receive(session.second, 0))
        }

        // Assert
        second_message
        |> should
        |> be_ok
        |> be_error
        |> or_fail_with("Expected no notification on the second channel")
      },
    ),
  ]
}

// While the connection is lost ------------------------------------------------

/// The listeners wait a minute before they reconnect, so the connection
/// stays lost while the test subscribes.
fn lost_tests() {
  [
    before_each(start_test_listener(first_driver_server, 60_000)),
    group("with no subscriber before the loss", [
      before_each(end_session_backend),
      it(
        "keeps a subscription made while the connection is lost",
        fn(session: ListenerSession) {
          // Act
          let message = {
            use _subscription <- try(subscribe_to(
              session.listener,
              session.channel,
              session.first,
            ))
            receive_message(session.first)
          }

          // Assert
          message
          |> should
          |> be_ok
          |> be_equal(ListeningLost)
          |> or_fail_with("Expected ListeningLost at once")
        },
      ),
    ]),
    group("with a subscriber before the loss", [
      before_each(subscribe_first),
      before_each(end_session_backend),
      before_each(wait_for_first_message),
      it(
        "tells a new subscriber of a lost channel at once",
        fn(session: ListenerSession) {
          // Act
          let message = {
            use _subscription <- try(subscribe_to(
              session.listener,
              session.channel,
              session.second,
            ))
            receive_message(session.second)
          }

          // Assert
          message
          |> should
          |> be_ok
          |> be_equal(ListeningLost)
          |> or_fail_with("Expected ListeningLost for the new subscriber")
        },
      ),
    ]),
  ]
}

// Listening again after the backend ends: one act for three tests -------------

/// What the subscriber got after the control connection ended the
/// listener's backend: the loss, the new LISTEN, and a notification sent
/// after it.
type ListenedAgainOutcome {
  ListenedAgainOutcome(
    lost: Result(ListenerMessage, String),
    again: Result(ListenerMessage, String),
    back: Result(ListenerMessage, String),
  )
}

fn lose_and_listen_again(
  session: ListenerSession,
) -> Result(ListenedAgainOutcome, String) {
  use _subscription <- try(subscribe_to(
    session.listener,
    session.channel,
    session.first,
  ))
  use _ended <- try(end_session_backend(session))
  let lost = receive_message(session.first)
  let again = receive_message(session.first)
  use _sent <- try(send_notification(session.control, session.channel, "back"))
  let back = receive_message(session.first)
  Ok(ListenedAgainOutcome(lost:, again:, back:))
}

fn reconnect_tests(server: Server) -> TestSuite {
  describe(
    "PostgreSQL " <> to_string(server.version),
    listener_act_setup(server, 10, lose_and_listen_again),
    [
      it(
        "says ListeningLost when the backend ends",
        fn(shared: ListenerOutcome(ListenedAgainOutcome)) {
          shared.outcome.lost
          |> should
          |> be_ok
          |> be_equal(ListeningLost)
          |> or_fail_with("Expected ListeningLost first")
        },
      ),
      it(
        "listens again after a reconnect and says so",
        fn(shared: ListenerOutcome(ListenedAgainOutcome)) {
          shared.outcome.again
          |> should
          |> be_ok
          |> be_equal(ListenedAgain(shared.session.channel, Ok(Nil)))
          |> or_fail_with("Expected ListenedAgain after ListeningLost")
        },
      ),
      it(
        "gives notifications after a reconnect",
        fn(shared: ListenerOutcome(ListenedAgainOutcome)) {
          shared.outcome.back
          |> should
          |> be_ok
          |> extract_arrived_notification
          |> extract_channel_and_payload
          |> be_equal(#(shared.session.channel, "back"))
          |> or_fail_with("Expected the notification on the new session")
        },
      ),
    ],
  )
}

// A subscription while the connection is lost: one act for three tests --------

/// What the two subscribers got: the gate keeps the connection lost while
/// a second subscriber comes on a second channel, and refuses one
/// reconnect. Both channels listen again when the gate opens.
type GateOutcome {
  GateOutcome(
    second_lost: Result(ListenerMessage, String),
    first_again: Result(ListenerMessage, String),
    second_again: Result(ListenerMessage, String),
  )
}

fn lose_behind_gate(gated: GatedListener) -> Result(GateOutcome, String) {
  use _first <- try(subscribe_to(gated.listener, "svc827_gate_one", gated.first))
  break_gate(gated.gate)
  use _first_lost <- try(receive_message(gated.first))
  use _second <- try(subscribe_to(
    gated.listener,
    "svc827_gate_two",
    gated.second,
  ))
  let second_lost = receive_message(gated.second)
  wait_refused(gated.gate)
  open_gate(gated.gate)
  let first_again = receive_message(gated.first)
  let second_again = receive_message(gated.second)
  Ok(GateOutcome(second_lost:, first_again:, second_again:))
}

fn gate_tests() -> TestSuite {
  describe(
    "a subscription while the connection is lost",
    gated_act_setup(first_driver_server, lose_behind_gate),
    [
      it(
        "listens at the reconnect for a subscription made while lost",
        fn(shared: GatedOutcome(GateOutcome)) {
          shared.outcome.second_again
          |> should
          |> be_ok
          |> be_equal(ListenedAgain("svc827_gate_two", Ok(Nil)))
          |> or_fail_with("Expected the second channel to listen again")
        },
      ),
      it(
        "listens again for a subscription made before the loss",
        fn(shared: GatedOutcome(GateOutcome)) {
          shared.outcome.first_again
          |> should
          |> be_ok
          |> be_equal(ListenedAgain("svc827_gate_one", Ok(Nil)))
          |> or_fail_with("Expected the first channel to listen again")
        },
      ),
      it(
        "gives ListeningLost to a subscription made while lost",
        fn(shared: GatedOutcome(GateOutcome)) {
          shared.outcome.second_lost
          |> should
          |> be_ok
          |> be_equal(ListeningLost)
          |> or_fail_with("Expected ListeningLost for the second subscriber")
        },
      ),
    ],
  )
}

// With a subscription ---------------------------------------------------------

fn subscription_tests() -> TestSuite {
  describe("with a subscription", subscribed_setup(first_driver_server), [
    after_each(stop_subscribed_listener),
    before_each(start_test_subscribed(first_driver_server)),
    group("that ended", [
      before_each(end_subscription),
      it(
        "ends a subscription that ended already without an error",
        fn(subscribed: SubscribedListener) {
          // Act
          let answer = unsubscribe(subscribed.listener, subscribed.subscription)

          // Assert
          answer
          |> should
          |> be_ok
          |> or_fail_with("Expected Ok for the second unsubscribe")
        },
      ),
    ]),
    it(
      "gives ListenerProcessDown to a subscribe after the stop",
      fn(subscribed: SubscribedListener) {
        // Act
        stop(subscribed.listener)
        let answer =
          subscribe(
            subscribed.listener,
            "svc827_stopped",
            subscribed.subscriber,
          )

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenerProcessDown)
        |> or_fail_with("Expected ListenerProcessDown")
      },
    ),
    it(
      "gives ListenerProcessDown to an unsubscribe after the stop",
      fn(subscribed: SubscribedListener) {
        // Act
        stop(subscribed.listener)
        let answer = unsubscribe(subscribed.listener, subscribed.subscription)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenerProcessDown)
        |> or_fail_with("Expected ListenerProcessDown")
      },
    ),
  ])
}

// Starting --------------------------------------------------------------------

/// The configs of the start tests: one to a port with no server, one to
/// the first driver server.
type StartInputs {
  StartInputs(refused: ListenerConfig, served: ListenerConfig)
}

fn build_start_inputs() -> Result(StartInputs, String) {
  use refused <- try(listener_config(
    free_port(),
    "svc827_refused",
    Backoff(10, 60_000),
  ))
  use served <- try(listener_config(
    first_driver_server.port,
    "svc827_supervised",
    Backoff(10, 60_000),
  ))
  Ok(StartInputs(refused:, served:))
}

fn start_tests() -> TestSuite {
  describe(
    "starting",
    context.setup(setup: build_start_inputs, teardown: fn(_inputs) { Ok(Nil) }),
    [
      it(
        "gives ConnectFailed for a port with no server",
        fn(inputs: StartInputs) {
          // Act
          let started = start(inputs.refused)

          // Assert
          started
          |> should
          |> be_error
          |> be_equal(ConnectFailed(TransportRefused(ConnectRefused)))
          |> or_fail_with("Expected ConnectFailed")
        },
      ),
      it("starts under a supervisor", fn(inputs: StartInputs) {
        // Arrange
        let supervisor =
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.add(supervised(inputs.served))

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
    ],
  )
}
