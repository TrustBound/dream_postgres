//// Tests for `dream_postgres/driver/listener`, LISTEN and NOTIFY, on the
//// driver servers of PostgreSQL 16 to 19. A second connection controls
//// the server: it sends the notifications, ends the listener's backend,
//// and reads the listener's last statement from `pg_stat_activity`. A gate
//// proxy between a listener and the server keeps the connection lost while
//// a test subscribes. Each listener has its own application name and its
//// own channels, so tests that run at the same time do not meet, and no
//// test sleeps. Setup hooks start each listener and stop it after the
//// test.

import dream_postgres/driver/connection.{Backoff, Notification, TransportRefused}
import dream_postgres/driver/listener.{
  type Listener, type ListenerConfig, type ListenerMessage, ChannelHasZeroByte,
  ChannelTooLong, ConnectFailed, ListenAnswerUnexpected, ListenDeadlinePassed,
  ListenFailed, ListenRefused, ListenerConnectionDown, ListenerGone,
  ListenerNotStarted, ListenerProcessDown, Listening, NotListening,
  NotificationArrived, SubscribeFailed, SubscriberHasNoProcess, start, stop,
  subscribe, supervised, unsubscribe,
}
import dream_postgres/driver/transport.{ConnectRefused}
import dream_postgres/internal/cell.{Idle}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/fake_server.{free_port}
import driver/listener_gate.{
  answer_first_query, break_gate, cut_first_query, hold_first_query, open_gate,
  wait_held, wait_refused,
}
import driver/proxy.{answer_next_request}
import driver/reconnect_server.{
  kill_linked_process, start_forwarder, start_watched_silent_server,
  wait_for_connection,
}
import driver/server_connection.{
  caller_answer, start_caller, start_in_ended_owner,
}
import driver/server_listener.{
  type GatedListener, type GatedOutcome, type ListenerOutcome,
  type ListenerSession, type ProxiedListener, type SubscribedListener,
  end_session_backend, end_subscription, gated_act_setup, listener_act_setup,
  listener_config, listener_connection_pid, listener_session_setup,
  listener_statement, proxied_listener_setup, receive_message, refusal_bytes,
  result_then_refusal_bytes, resume_listener_connection, send_notification,
  short_gated_act_setup, start_test_listener, start_test_proxied_listener,
  start_test_subscribed, stop_connection_process, stop_listener_connection,
  stop_listener_session, stop_proxied_listener, stop_subscribed_listener,
  subscribe_and_unsubscribe_first, subscribe_first, subscribe_first_to,
  subscribe_second, subscribe_second_to_other, subscribe_to, subscribed_setup,
  suspend_listener_connection, wait_for_first_message, wait_for_statement,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/backoff_strategies.{capped_delay}
import fixtures/server_report.{server_report}
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result.{flatten, map_error, replace_error, try}
import gleam/string.{inspect, repeat}
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
    cut_query_tests(),
    reconnect_listen_failure_tests(),
    listen_failure_tests(),
    subscription_tests(),
    start_tests(),
    late_server_tests(),
    killed_start_tests(),
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
        |> be_equal(SubscribeFailed(ChannelHasZeroByte))
        |> or_fail_with("Expected SubscribeFailed with the zero byte")
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
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening at once")
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
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening for the new subscriber")
        },
      ),
    ]),
  ]
}

// Listening again after the backend ends: one act for three tests -------------

/// What the subscriber got after the control connection ended the
/// listener's backend: the loss, the new LISTEN, and a notification sent
/// after it.
type ListeningAgainOutcome {
  ListeningAgainOutcome(
    lost: Result(ListenerMessage, String),
    again: Result(ListenerMessage, String),
    back: Result(ListenerMessage, String),
  )
}

fn lose_and_listen_again(
  session: ListenerSession,
) -> Result(ListeningAgainOutcome, String) {
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
  Ok(ListeningAgainOutcome(lost:, again:, back:))
}

fn reconnect_tests(server: Server) -> TestSuite {
  describe(
    "PostgreSQL " <> to_string(server.version),
    listener_act_setup(server, 10, lose_and_listen_again),
    [
      it(
        "says NotListening when the backend ends",
        fn(shared: ListenerOutcome(ListeningAgainOutcome)) {
          shared.outcome.lost
          |> should
          |> be_ok
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening first")
        },
      ),
      it(
        "listens again after a reconnect and says so",
        fn(shared: ListenerOutcome(ListeningAgainOutcome)) {
          shared.outcome.again
          |> should
          |> be_ok
          |> be_equal(Listening(shared.session.channel))
          |> or_fail_with("Expected Listening after NotListening")
        },
      ),
      it(
        "gives notifications after a reconnect",
        fn(shared: ListenerOutcome(ListeningAgainOutcome)) {
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
          |> be_equal(Listening("svc827_gate_two"))
          |> or_fail_with("Expected the second channel to listen again")
        },
      ),
      it(
        "listens again for a subscription made before the loss",
        fn(shared: GatedOutcome(GateOutcome)) {
          shared.outcome.first_again
          |> should
          |> be_ok
          |> be_equal(Listening("svc827_gate_one"))
          |> or_fail_with("Expected the first channel to listen again")
        },
      ),
      it(
        "gives NotListening to a subscription made while lost",
        fn(shared: GatedOutcome(GateOutcome)) {
          shared.outcome.second_lost
          |> should
          |> be_ok
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening for the second subscriber")
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
      "gives ListenerGone to an unsubscribe after the stop",
      fn(subscribed: SubscribedListener) {
        // Act
        stop(subscribed.listener)
        let answer = unsubscribe(subscribed.listener, subscribed.subscription)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ListenerGone)
        |> or_fail_with("Expected ListenerGone")
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
    Backoff(10, 60_000, capped_delay),
  ))
  use served <- try(listener_config(
    first_driver_server.port,
    "svc827_supervised",
    Backoff(10, 60_000, capped_delay),
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
          |> static_supervisor.add(supervised(
            inputs.served,
            process.new_name("listener_test_supervised"),
          ))

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

// A supervised listener whose server is down at first: one act, four tests --

/// What two subscribers of a supervised listener got: one subscribed to a
/// plain channel, one to a channel with a zero byte, whose `LISTEN` cannot
/// be written. Both subscribed before the server listened.
type LateListener {
  LateListener(
    listener: Listener,
    plain_first: Result(ListenerMessage, String),
    plain_after: Result(ListenerMessage, String),
    zero_byte_first: Result(ListenerMessage, String),
    zero_byte_after: Result(ListenerMessage, String),
  )
}

fn start_listener_before_server() -> Result(LateListener, String) {
  let port = free_port()
  use config <- try(listener_config(
    port,
    "svc827_late",
    Backoff(10, 100, capped_delay),
  ))
  use started <- try(
    supervised(config, process.new_name("svc827_late_listener")).start()
    |> map_error(inspect),
  )
  watch_late_listener(started.data, port)
  |> map_error(fn(error) {
    stop(started.data)
    error
  })
}

fn watch_late_listener(
  listener: Listener,
  port: Int,
) -> Result(LateListener, String) {
  let plain = process.new_subject()
  let zero_byte = process.new_subject()
  use _plain_subscription <- try(subscribe_to(listener, "svc827_late", plain))
  use _zero_byte_subscription <- try(subscribe_to(
    listener,
    "svc827_late\u{0000}zero",
    zero_byte,
  ))
  let plain_first = receive_message(plain)
  let zero_byte_first = receive_message(zero_byte)
  use Nil <- try(start_forwarder(port, first_driver_server.port))
  let plain_after = receive_message(plain)
  let zero_byte_after = receive_message(zero_byte)
  Ok(LateListener(
    listener:,
    plain_first:,
    plain_after:,
    zero_byte_first:,
    zero_byte_after:,
  ))
}

fn stop_late_listener(outcome: LateListener) -> Result(Nil, String) {
  Ok(stop(outcome.listener))
}

fn late_server_tests() -> TestSuite {
  describe(
    "a supervised listener whose server is down at first",
    context.setup(
      setup: start_listener_before_server,
      teardown: stop_late_listener,
    ),
    [
      it(
        "says NotListening to a subscriber before the server listens",
        fn(outcome: LateListener) {
          outcome.plain_first
          |> should
          |> be_ok
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening at once")
        },
      ),
      it("says Listening once the server listens", fn(outcome: LateListener) {
        outcome.plain_after
        |> should
        |> be_ok
        |> be_equal(Listening("svc827_late"))
        |> or_fail_with("Expected Listening after the first login")
      }),
      it(
        "keeps a subscription whose LISTEN was not written yet",
        fn(outcome: LateListener) {
          outcome.zero_byte_first
          |> should
          |> be_ok
          |> be_equal(NotListening)
          |> or_fail_with("Expected NotListening for the zero-byte channel")
        },
      ),
      it(
        "says ListenFailed when the LISTEN fails on the session",
        fn(outcome: LateListener) {
          outcome.zero_byte_after
          |> should
          |> be_ok
          |> be_equal(ListenFailed(
            "svc827_late\u{0000}zero",
            ChannelHasZeroByte,
          ))
          |> or_fail_with("Expected ListenFailed with the zero byte")
        },
      ),
    ],
  )
}

// A LISTEN after a reconnect: one act, one test for each message --------------

/// The two messages that a subscriber gets after the gate cut its
/// connection: the one of the loss, and the one after the reconnect.
type ReconnectMessages {
  ReconnectMessages(lost: ListenerMessage, next: ListenerMessage)
}

/// What the subscriber got after the gate cut its connection and then
/// cut the first `LISTEN` after the reconnect.
fn lose_listen_after_reconnect(
  gated: GatedListener,
) -> Result(ReconnectMessages, String) {
  use _first <- try(subscribe_to(gated.listener, "svc895_cut", gated.first))
  cut_first_query(gated.gate)
  use lost <- try(receive_message(gated.first))
  use next <- try(receive_message(gated.first))
  Ok(ReconnectMessages(lost:, next:))
}

fn cut_query_tests() -> TestSuite {
  describe(
    "a LISTEN that meets a loss after a reconnect",
    gated_act_setup(first_driver_server, lose_listen_after_reconnect),
    [
      not_listening_at_loss_test(),
      it(
        "gives no ListenFailed, only Listening after the next reconnect",
        fn(shared: GatedOutcome(ReconnectMessages)) {
          shared.outcome.next
          |> should
          |> be_equal(Listening("svc895_cut"))
          |> or_fail_with("Expected Listening")
        },
      ),
    ],
  )
}

// A LISTEN that fails after a reconnect: one act per failure -------------------

/// What the subscriber got after the gate cut its connection and answered
/// the first `LISTEN` after the reconnect with a refusal.
fn refuse_listen_after_reconnect(
  gated: GatedListener,
) -> Result(ReconnectMessages, String) {
  use _first <- try(subscribe_to(gated.listener, "svc895_refused", gated.first))
  answer_first_query(gated.gate, refusal_bytes())
  use lost <- try(receive_message(gated.first))
  use next <- try(receive_message(gated.first))
  Ok(ReconnectMessages(lost:, next:))
}

/// What the subscriber got after the gate cut its connection and kept the
/// first `LISTEN` after the reconnect from the server, so the deadline of
/// 100 milliseconds passed.
fn hold_listen_after_reconnect(
  gated: GatedListener,
) -> Result(ReconnectMessages, String) {
  use _first <- try(subscribe_to(gated.listener, "svc895_held", gated.first))
  hold_first_query(gated.gate)
  use lost <- try(receive_message(gated.first))
  use next <- try(receive_message(gated.first))
  Ok(ReconnectMessages(lost:, next:))
}

/// What the subscriber got after the gate cut its connection, kept the
/// first `LISTEN` after the reconnect, and the connection process was
/// stopped while the listener waited for that `LISTEN`.
fn stop_connection_in_listen_after_reconnect(
  gated: GatedListener,
) -> Result(ReconnectMessages, String) {
  use _first <- try(subscribe_to(gated.listener, "svc895_down", gated.first))
  let connection = listener_connection_pid(gated.listener)
  hold_first_query(gated.gate)
  use lost <- try(receive_message(gated.first))
  wait_held(gated.gate)
  stop_connection_process(connection)
  use next <- try(receive_message(gated.first))
  Ok(ReconnectMessages(lost:, next:))
}

/// The first message of each act after a reconnect: the loss.
fn not_listening_at_loss_test() -> ContextNode(GatedOutcome(ReconnectMessages)) {
  it(
    "gives NotListening at the loss",
    fn(shared: GatedOutcome(ReconnectMessages)) {
      shared.outcome.lost
      |> should
      |> be_equal(NotListening)
      |> or_fail_with("Expected NotListening")
    },
  )
}

fn reconnect_listen_failure_tests() -> TestSuite {
  suite.group("a LISTEN that fails after a reconnect", [
    describe(
      "a refused LISTEN after a reconnect",
      gated_act_setup(first_driver_server, refuse_listen_after_reconnect),
      [
        not_listening_at_loss_test(),
        it(
          "gives ListenRefused with the report after the reconnect",
          fn(shared: GatedOutcome(ReconnectMessages)) {
            shared.outcome.next
            |> should
            |> be_equal(ListenFailed(
              "svc895_refused",
              ListenRefused(
                server_report("ERROR", "42501", "permission denied"),
                Idle,
              ),
            ))
            |> or_fail_with("Expected ListenRefused")
          },
        ),
      ],
    ),
    describe(
      "a LISTEN with no answer after a reconnect",
      short_gated_act_setup(first_driver_server, hold_listen_after_reconnect),
      [
        not_listening_at_loss_test(),
        it(
          "gives ListenDeadlinePassed after the reconnect",
          fn(shared: GatedOutcome(ReconnectMessages)) {
            shared.outcome.next
            |> should
            |> be_equal(ListenFailed(
              "svc895_held",
              ListenDeadlinePassed(cancelled: False),
            ))
            |> or_fail_with("Expected ListenDeadlinePassed")
          },
        ),
      ],
    ),
    describe(
      "a LISTEN after a reconnect whose connection process stops",
      gated_act_setup(
        first_driver_server,
        stop_connection_in_listen_after_reconnect,
      ),
      [
        not_listening_at_loss_test(),
        it(
          "gives ListenerConnectionDown after the reconnect",
          fn(shared: GatedOutcome(ReconnectMessages)) {
            shared.outcome.next
            |> should
            |> be_equal(ListenFailed("svc895_down", ListenerConnectionDown))
            |> or_fail_with("Expected ListenerConnectionDown")
          },
        ),
      ],
    ),
  ])
}

// A LISTEN that fails on a session that is up -----------------------------------

fn listen_failure_tests() -> TestSuite {
  describe(
    "a LISTEN that fails on a session that is up",
    proxied_listener_setup(first_driver_server),
    [
      before_each(start_test_proxied_listener(first_driver_server)),
      after_each(stop_proxied_listener),
      it(
        "gives ListenRefused when the server refuses the LISTEN",
        fn(proxied: ProxiedListener) {
          // Arrange
          answer_next_request(proxied.proxy, refusal_bytes())

          // Act
          let answer =
            subscribe(proxied.listener, proxied.channel, proxied.subscriber)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(
            SubscribeFailed(ListenRefused(
              server_report("ERROR", "42501", "permission denied"),
              Idle,
            )),
          )
          |> or_fail_with("Expected ListenRefused with the report")
        },
      ),
      it(
        "gives ListenAnswerUnexpected when one LISTEN gets two answers",
        fn(proxied: ProxiedListener) {
          // Arrange
          answer_next_request(proxied.proxy, result_then_refusal_bytes())

          // Act
          let answer =
            subscribe(proxied.listener, proxied.channel, proxied.subscriber)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(SubscribeFailed(ListenAnswerUnexpected))
          |> or_fail_with("Expected ListenAnswerUnexpected")
        },
      ),
      it(
        "gives ListenDeadlinePassed when the connection does not answer",
        fn(proxied: ProxiedListener) {
          // Arrange
          suspend_listener_connection(proxied.listener)

          // Act
          let answer =
            subscribe(proxied.listener, proxied.channel, proxied.subscriber)
          resume_listener_connection(proxied.listener)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(SubscribeFailed(ListenDeadlinePassed(cancelled: False)))
          |> or_fail_with("Expected ListenDeadlinePassed")
        },
      ),
      it(
        "gives ListenerConnectionDown when the connection process is gone",
        fn(proxied: ProxiedListener) {
          // Arrange
          stop_listener_connection(proxied.listener)

          // Act
          let answer =
            subscribe(proxied.listener, proxied.channel, proxied.subscriber)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(SubscribeFailed(ListenerConnectionDown))
          |> or_fail_with("Expected ListenerConnectionDown")
        },
      ),
    ],
  )
}

// A start that the listener's end cuts short ------------------------------------

fn killed_start_tests() -> TestSuite {
  unit.describe("a start that the listener's end cuts short", [
    unit.it("gives ListenerNotStarted with the exit of the listener", fn() {
      // Act
      let started = {
        use #(port, server) <- try(start_watched_silent_server())
        use config <- try(listener_config(
          port,
          "svc827_killed",
          Backoff(10, 60_000, capped_delay),
        ))
        let answers = process.new_subject()
        let starter =
          process.spawn_unlinked(fn() {
            process.trap_exits(True)
            process.send(answers, start(config))
          })
        use Nil <- try(wait_for_connection(server))
        use Nil <- try(kill_linked_process(starter))
        process.receive(answers, 5000)
        |> replace_error("no answer of the start")
      }

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> be_equal(ListenerNotStarted(actor.InitExited(process.Killed)))
      |> or_fail_with("Expected ListenerNotStarted with the kill")
    }),
  ])
}
