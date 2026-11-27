//// Tests for `dream_postgres/driver/sink`: a connection, a pool and a
//// listener send each event through a sink that maps it, and drop a sink
//// whose map crashes while they keep working. The tests run on the first
//// driver server. Each test waits for the message it expects, and no test
//// sleeps.

import dream_postgres/driver/connection.{Connected, stop}
import dream_postgres/driver/pool.{type PoolEvent, MemberConnected}
import dream_postgres/driver/sink
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{after_each, before_each, describe, it}
import driver/server_connection.{
  caller_answer, query_text, run_control_script, start_caller,
}
import driver/server_listener.{
  type ListenerSession, listener_session_setup, send_notification,
  start_test_listener, stop_listener_session, wait_for_statement,
}
import driver/server_sink.{
  ConnectionSinks, hold_text, notify_self, raise_across_replacement,
  raise_notice, raise_notification, receive_sent, replace_after_events_crash,
  start_sunk_connection, start_sunk_pool, subscribe_sink,
}
import driver/servers.{first_driver_server}
import fixtures/sink_maps.{
  type Wrapped, Wrapped, crash, crash_after_telling, listener_message_text,
  notification_payload, report_code,
}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/result.{flatten, map_error, try}
import gleam/string.{inspect}
import matchers/extract_later_call.{extract_later_call}
import matchers/extract_replaced_answers.{extract_replaced_answers}

/// The tests of the sinks.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/sink", [
    connection_tests(),
    pool_tests(),
    listener_tests(),
  ])
}

/// A statement whose notice has the SQLSTATE 01000.
const warning_sql = "DO $$BEGIN RAISE WARNING 'through a sink'; END$$"

// Connections -----------------------------------------------------------------

fn connection_tests() -> TestSuite {
  unit.describe("the sinks of a connection", [
    unit.it("send each event, mapped", fn() {
      // Arrange
      let events = process.new_subject()
      let sinks = ConnectionSinks(Some(sink.to(events, Wrapped)), None, None)

      // Act
      let first_event = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let event = receive_sent(events)
        stop(connection)
        event
      }

      // Assert
      first_event
      |> should
      |> be_ok
      |> be_equal(Wrapped(Connected))
      |> or_fail_with("Expected Wrapped(Connected)")
    }),
    unit.it("send each notice, mapped", fn() {
      // Arrange
      let codes = process.new_subject()
      let sinks = ConnectionSinks(None, Some(sink.to(codes, report_code)), None)

      // Act
      let code = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let code = {
          use Nil <- try(run_control_script(connection, warning_sql))
          receive_sent(codes)
        }
        stop(connection)
        code
      }

      // Assert
      code
      |> should
      |> be_ok
      |> be_equal("01000")
      |> or_fail_with("Expected the code of the warning")
    }),
    unit.it("send each notification, mapped", fn() {
      // Arrange
      let payloads = process.new_subject()
      let sinks =
        ConnectionSinks(
          None,
          None,
          Some(sink.to(payloads, notification_payload)),
        )

      // Act
      let payload = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let payload = {
          use Nil <- try(notify_self(connection, "svc895_sink_mapped", "mapped"))
          receive_sent(payloads)
        }
        stop(connection)
        payload
      }

      // Assert
      payload
      |> should
      |> be_ok
      |> be_equal("mapped")
      |> or_fail_with("Expected the payload of the notification")
    }),
    unit.it("still send notices after the events map crashed", fn() {
      // Arrange
      let codes = process.new_subject()
      let sinks =
        ConnectionSinks(
          Some(sink.to(process.new_subject(), crash)),
          Some(sink.to(codes, report_code)),
          None,
        )

      // Act
      let code = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let code = {
          use Nil <- try(run_control_script(connection, warning_sql))
          receive_sent(codes)
        }
        stop(connection)
        code
      }

      // Assert
      code
      |> should
      |> be_ok
      |> be_equal("01000")
      |> or_fail_with("Expected the notice after the events map crashed")
    }),
    unit.it("still answer after the notices map crashed", fn() {
      // Arrange
      let sinks =
        ConnectionSinks(None, Some(sink.to(process.new_subject(), crash)), None)

      // Act
      let answer = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let answer = {
          use Nil <- try(run_control_script(connection, warning_sql))
          query_text(connection, "SELECT 'still here'")
        }
        stop(connection)
        answer
      }

      // Assert
      answer
      |> should
      |> be_ok
      |> be_equal("still here")
      |> or_fail_with("Expected an answer after the notices map crashed")
    }),
    unit.it("still send notices after the notifications map crashed", fn() {
      // Arrange
      let codes = process.new_subject()
      let sinks =
        ConnectionSinks(
          None,
          Some(sink.to(codes, report_code)),
          Some(sink.to(process.new_subject(), crash)),
        )

      // Act
      let code = {
        use connection <- try(start_sunk_connection(
          first_driver_server.port,
          sinks,
        ))
        let code = {
          use Nil <- try(notify_self(connection, "svc895_sink_crash", "lost"))
          use Nil <- try(run_control_script(connection, warning_sql))
          receive_sent(codes)
        }
        stop(connection)
        code
      }

      // Assert
      code
      |> should
      |> be_ok
      |> be_equal("01000")
      |> or_fail_with("Expected the notice after the notifications map crashed")
    }),
  ])
}

// Pools -----------------------------------------------------------------------

fn pool_tests() -> TestSuite {
  unit.describe("the sinks of a pool", [
    unit.it("send each pool event, mapped", fn() {
      // Arrange
      let pool_events = process.new_subject()

      // Act
      let first_event = {
        use started <- try(start_sunk_pool(
          first_driver_server.port,
          Some(sink.to(pool_events, Wrapped)),
          None,
        ))
        let event = receive_sent(pool_events)
        pool.stop(started, 1000)
        event
      }

      // Assert
      first_event
      |> should
      |> be_ok
      |> be_equal(Wrapped(MemberConnected(0)))
      |> or_fail_with("Expected Wrapped(MemberConnected(0))")
    }),
    unit.it("still serve a hold after the pool events map crashed", fn() {
      // Arrange
      let witness = process.new_subject()
      let receiver: Subject(Wrapped(PoolEvent)) = process.new_subject()
      let pool_events = sink.to(receiver, crash_after_telling(witness))

      // Act
      let answer = {
        use started <- try(start_sunk_pool(
          first_driver_server.port,
          Some(pool_events),
          None,
        ))
        let answer = {
          use _first_event <- try(receive_sent(witness))
          hold_text(started, "SELECT 'held'")
        }
        pool.stop(started, 1000)
        answer
      }

      // Assert
      answer
      |> should
      |> be_ok
      |> be_equal("held")
      |> or_fail_with("Expected the hold to work after the map crashed")
    }),
    unit.it("call a crashed pool events map no more", fn() {
      // Arrange
      let witness = process.new_subject()
      let receiver: Subject(Wrapped(PoolEvent)) = process.new_subject()
      let pool_events = sink.to(receiver, crash_after_telling(witness))

      // Act
      let later_event = {
        use started <- try(start_sunk_pool(
          first_driver_server.port,
          Some(pool_events),
          None,
        ))
        let later_event = {
          use _first_event <- try(receive_sent(witness))
          use _held <- try(hold_text(started, "SELECT 'held'"))
          use _status <- try(
            pool.status(started) |> map_error(fn(error) { inspect(error) }),
          )
          Ok(process.receive(witness, 0))
        }
        pool.stop(started, 1000)
        later_event
      }

      // Assert
      later_event
      |> should
      |> be_ok
      |> be_error
      |> or_fail_with("Expected no call of the map after its crash")
    }),
    unit.it("still serve a hold after the connection events map crashed", fn() {
      // Arrange
      let connection_events = sink.to(process.new_subject(), crash)

      // Act
      let answer = {
        use started <- try(start_sunk_pool(
          first_driver_server.port,
          None,
          Some(connection_events),
        ))
        let answer = hold_text(started, "SELECT 'held'")
        pool.stop(started, 1000)
        answer
      }

      // Assert
      answer
      |> should
      |> be_ok
      |> be_equal("held")
      |> or_fail_with("Expected the hold to work after the map crashed")
    }),
    unit.it(
      "still send pool events after the connection events map crashed",
      fn() {
        // Arrange
        let pool_events = process.new_subject()
        let connection_events = sink.to(process.new_subject(), crash)

        // Act
        let first_event = {
          use started <- try(start_sunk_pool(
            first_driver_server.port,
            Some(sink.to(pool_events, Wrapped)),
            Some(connection_events),
          ))
          let event = receive_sent(pool_events)
          pool.stop(started, 1000)
          event
        }

        // Assert
        first_event
        |> should
        |> be_ok
        |> be_equal(Wrapped(MemberConnected(0)))
        |> or_fail_with("Expected the pool event after the map crashed")
      },
    ),
    unit.it(
      "call a crashed connection events map no more, also after a connection is replaced",
      fn() {
        // Arrange
        let witness = process.new_subject()
        let receiver: Subject(Wrapped(String)) = process.new_subject()
        let events = sink.to(receiver, crash_after_telling(witness))

        // Act
        let later_call =
          replace_after_events_crash(first_driver_server.port, events, witness)

        // Assert
        later_call
        |> should
        |> be_ok
        |> be_error
        |> or_fail_with("Expected no call of the events map after its crash")
      },
    ),
    unit.it(
      "call a crashed notices map no more, also after a connection is replaced",
      fn() {
        // Arrange
        let witness = process.new_subject()
        let receiver: Subject(Wrapped(String)) = process.new_subject()
        let notices = sink.to(receiver, crash_after_telling(witness))
        let sinks = ConnectionSinks(None, Some(notices), None)

        // Act
        let run =
          raise_across_replacement(
            first_driver_server.port,
            sinks,
            witness,
            raise_notice,
          )

        // Assert
        run
        |> should
        |> be_ok
        |> extract_later_call
        |> be_error
        |> or_fail_with("Expected no call of the notices map after its crash")
      },
    ),
    unit.it("still serve each connection after the notices map crashed", fn() {
      // Arrange
      let witness = process.new_subject()
      let receiver: Subject(Wrapped(String)) = process.new_subject()
      let notices = sink.to(receiver, crash_after_telling(witness))
      let sinks = ConnectionSinks(None, Some(notices), None)

      // Act
      let run =
        raise_across_replacement(
          first_driver_server.port,
          sinks,
          witness,
          raise_notice,
        )

      // Assert
      run
      |> should
      |> be_ok
      |> extract_replaced_answers
      |> be_equal(#("answered", "answered"))
      |> or_fail_with("Expected both connections to answer")
    }),
    unit.it(
      "call a crashed notifications map no more, also after a connection is replaced",
      fn() {
        // Arrange
        let witness = process.new_subject()
        let receiver: Subject(Wrapped(String)) = process.new_subject()
        let notifications = sink.to(receiver, crash_after_telling(witness))
        let sinks = ConnectionSinks(None, None, Some(notifications))

        // Act
        let run =
          raise_across_replacement(
            first_driver_server.port,
            sinks,
            witness,
            raise_notification,
          )

        // Assert
        run
        |> should
        |> be_ok
        |> extract_later_call
        |> be_error
        |> or_fail_with(
          "Expected no call of the notifications map after its crash",
        )
      },
    ),
    unit.it(
      "still serve each connection after the notifications map crashed",
      fn() {
        // Arrange
        let witness = process.new_subject()
        let receiver: Subject(Wrapped(String)) = process.new_subject()
        let notifications = sink.to(receiver, crash_after_telling(witness))
        let sinks = ConnectionSinks(None, None, Some(notifications))

        // Act
        let run =
          raise_across_replacement(
            first_driver_server.port,
            sinks,
            witness,
            raise_notification,
          )

        // Assert
        run
        |> should
        |> be_ok
        |> extract_replaced_answers
        |> be_equal(#("answered", "answered"))
        |> or_fail_with("Expected both connections to answer")
      },
    ),
  ])
}

// Listeners -------------------------------------------------------------------

fn listener_tests() -> TestSuite {
  describe(
    "the sinks of a listener's subscribers",
    listener_session_setup(first_driver_server),
    [
      after_each(stop_listener_session),
      before_each(start_test_listener(first_driver_server, 10)),
      it("send each notification, mapped", fn(session: ListenerSession) {
        // Arrange
        let texts = process.new_subject()

        // Act
        let text = {
          use _subscription <- try(subscribe_sink(
            session.listener,
            session.channel,
            sink.to(texts, listener_message_text),
          ))
          use Nil <- try(send_notification(
            session.control,
            session.channel,
            "mapped",
          ))
          receive_sent(texts)
        }

        // Assert
        text
        |> should
        |> be_ok
        |> be_equal("mapped")
        |> or_fail_with("Expected the payload of the notification")
      }),
      it(
        "still give the notification to the other subscriber after a map crashed",
        fn(session: ListenerSession) {
          // Arrange
          let texts = process.new_subject()

          // Act
          let text = {
            use _crashing <- try(subscribe_sink(
              session.listener,
              session.channel,
              sink.to(process.new_subject(), crash),
            ))
            use _kept <- try(subscribe_sink(
              session.listener,
              session.channel,
              sink.to(texts, listener_message_text),
            ))
            use Nil <- try(send_notification(
              session.control,
              session.channel,
              "both",
            ))
            receive_sent(texts)
          }

          // Assert
          text
          |> should
          |> be_ok
          |> be_equal("both")
          |> or_fail_with("Expected the notification at the other subscriber")
        },
      ),
      it(
        "still answer a subscribe after a map crashed",
        fn(session: ListenerSession) {
          // Arrange
          let texts = process.new_subject()

          // Act
          let answer = {
            use _crashing <- try(subscribe_sink(
              session.listener,
              session.channel,
              sink.to(process.new_subject(), crash),
            ))
            use _kept <- try(subscribe_sink(
              session.listener,
              session.channel,
              sink.to(texts, listener_message_text),
            ))
            use Nil <- try(send_notification(
              session.control,
              session.channel,
              "both",
            ))
            use _text <- try(receive_sent(texts))
            subscribe_sink(
              session.listener,
              session.other_channel,
              sink.to(process.new_subject(), listener_message_text),
            )
          }

          // Assert
          answer
          |> should
          |> be_ok
          |> or_fail_with("Expected the listener to answer the subscribe")
        },
      ),
      it(
        "ends the subscription of a crashed map, with UNLISTEN for the last one",
        fn(session: ListenerSession) {
          // Arrange
          let unlisten = "UNLISTEN \"" <> session.channel <> "\""

          // Act
          let statement = {
            use _crashing <- try(subscribe_sink(
              session.listener,
              session.channel,
              sink.to(process.new_subject(), crash),
            ))
            use Nil <- try(send_notification(
              session.control,
              session.channel,
              "dropped",
            ))
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
          |> or_fail_with("Expected UNLISTEN after the map crashed")
        },
      ),
      it(
        "ends the subscription of a mapping sink whose process stopped",
        fn(session: ListenerSession) {
          // Arrange
          let unlisten = "UNLISTEN \"" <> session.channel <> "\""

          // Act
          let statement = {
            let caller =
              start_caller(fn() {
                subscribe_sink(
                  session.listener,
                  session.channel,
                  sink.to(process.new_subject(), listener_message_text),
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
    ],
  )
}
