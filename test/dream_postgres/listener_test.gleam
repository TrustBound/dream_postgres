//// The listener of the client: LISTEN and NOTIFY on PostgreSQL 16 to 19,
//// and the mapping of each message and error of the driver's listener.

import dream_postgres/driver/cell.{Idle}
import dream_postgres/driver/connection/event as connection_event
import dream_postgres/driver/connection/outcome as connection_outcome
import dream_postgres/driver/listener
import dream_postgres/error
import dream_postgres/listener.{
  ListenFailed, Listening, NotListening, NotificationArrived, listen,
  monitor_listener, named_listener, stop_listener, unlisten,
} as postgres_listener
import dream_postgres/query.{run_sql}
import dream_test/context
import dream_test/matchers.{
  be_empty, be_equal, be_error, be_ok, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import driver/listener_gate
import driver/server_named_listener
import fixtures/listen_messages
import fixtures/postgres_failure
import fixtures/server_pools
import fixtures/server_reports
import fixtures/server_versions
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/result
import matchers/collect_with_listener.{collect_with_listener}
import matchers/extract_listen_payloads.{extract_listen_payloads}
import matchers/have_cause.{have_cause}
import matchers/have_reason.{have_reason}
import matchers/map_listen_failure.{map_listen_failure}
import matchers/map_listen_message.{map_listen_message}
import matchers/map_listener_error.{map_listener_error}
import matchers/map_listener_start_error.{map_listener_start_error}
import matchers/map_unsubscribe_error.{map_unsubscribe_error}
import matchers/run_with_listener.{run_with_listener}
import matchers/run_with_supervised_listener.{run_with_supervised_listener}

/// A channel name of 64 bytes: one more than PostgreSQL keeps.
const too_long_channel =
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

/// The listener on each driver server, with one pool for each server to
/// send the NOTIFY.
pub fn tests() -> TestSuite {
  describe(
    "the listener on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        it("a NOTIFY from a pool connection arrives", fn(pools) {
          // Arrange
          let messages = process.new_subject()

          // Act and assert
          pools
          |> should
          |> collect_with_listener(
            messages,
            within: 500,
            work: fn(listener, connection) {
              use _subscription <- result.try(listen(
                listener,
                "arriving_jobs",
                messages,
              ))
              run_sql("NOTIFY arriving_jobs, 'hello'", connection)
            },
          )
          |> extract_listen_payloads()
          |> be_equal([#("arriving_jobs", "hello")])
          |> or_fail_with("Expected the notification on jobs")
        }),
        it("unlisten stops the notifications", fn(pools) {
          // Arrange
          let messages = process.new_subject()

          // Act and assert
          pools
          |> should
          |> collect_with_listener(
            messages,
            within: 500,
            work: fn(listener, connection) {
              use subscription <- result.try(listen(
                listener,
                "ended_jobs",
                messages,
              ))
              use Nil <- result.try(unlisten(listener, subscription))
              run_sql("NOTIFY ended_jobs, 'after the end'", connection)
            },
          )
          |> be_empty()
          |> or_fail_with("Expected no notification after unlisten")
        }),
        it(
          "a supervised listener answers through its name, after NotListening and Listening",
          fn(pools) {
            // Arrange
            let messages = process.new_subject()
            let name = process.new_name("supervised_listener")

            // Act and assert
            pools
            |> should
            |> run_with_supervised_listener(name, fn(gate, connection) {
              use _subscription <- result.try(
                listen(named_listener(name), "named_jobs", messages)
                |> result.map_error(error.describe),
              )
              listener_gate.open_gate(gate)
              use states <- result.try(listen_messages.receive_messages(
                messages,
                count: 2,
                within: 5000,
              ))
              use Nil <- result.try(
                run_sql("NOTIFY named_jobs, 'by name'", connection)
                |> result.map_error(error.describe),
              )
              listen_messages.receive_messages(messages, count: 1, within: 5000)
              |> result.map(list.append(states, _))
            })
            |> extract_listen_payloads()
            |> be_equal([
              #("NotListening", ""),
              #("Listening named_jobs", ""),
              #("named_jobs", "by name"),
            ])
            |> or_fail_with(
              "Expected NotListening, Listening and the notification through the name",
            )
          },
        ),
        it(
          "after a session crash the subject hears NotListening, then Listening, then NOTIFY",
          fn(pools) {
            // Arrange
            let messages = process.new_subject()
            let name = process.new_name("crashed_session_listener")

            // Act and assert
            pools
            |> should
            |> run_with_supervised_listener(name, fn(gate, connection) {
              use _subscription <- result.try(
                listen(named_listener(name), "revived_jobs", messages)
                |> result.map_error(error.describe),
              )
              listener_gate.open_gate(gate)
              use first_states <- result.try(listen_messages.receive_messages(
                messages,
                count: 2,
                within: 5000,
              ))
              process.kill(
                server_named_listener.listener_session_pid(listener.from_name(
                  name,
                )),
              )
              use crash_states <- result.try(listen_messages.receive_messages(
                messages,
                count: 2,
                within: 5000,
              ))
              use Nil <- result.try(
                run_sql("NOTIFY revived_jobs, 'after the crash'", connection)
                |> result.map_error(error.describe),
              )
              listen_messages.receive_messages(messages, count: 1, within: 5000)
              |> result.map(fn(notified) {
                list.flatten([first_states, crash_states, notified])
              })
            })
            |> extract_listen_payloads()
            |> be_equal([
              #("NotListening", ""),
              #("Listening revived_jobs", ""),
              #("NotListening", ""),
              #("Listening revived_jobs", ""),
              #("revived_jobs", "after the crash"),
            ])
            |> or_fail_with(
              "Expected NotListening and Listening, again after the crash, then the notification",
            )
          },
        ),
        it("the monitor of a listener fires when it stops", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_listener(fn(listener, _connection) {
            use monitor <- result.try(monitor_listener(listener))
            stop_listener(listener)
            Ok(listen_messages.wait_for_down(monitor, within: 5000))
          })
          |> be_ok()
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with("Expected the Down of the listener")
        }),
        it("a channel name of 64 bytes is ChannelTooLong", fn(pools) {
          // Arrange
          let messages = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_with_listener(fn(listener, _connection) {
            listen(listener, too_long_channel, messages)
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.ChannelTooLong(too_long_channel))
          |> or_fail_with("Expected ChannelTooLong")
        }),
        it("a subject with no process is SubscriberHasNoProcess", fn(pools) {
          // Arrange
          let nobody = process.named_subject(process.new_name("nobody_listens"))

          // Act and assert
          pools
          |> should
          |> run_with_listener(fn(listener, _connection) {
            listen(listener, "jobs", nobody)
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.SubscriberHasNoProcess)
          |> or_fail_with("Expected SubscriberHasNoProcess")
        }),
        it("unlisten on a stopped listener is ListenerStopped", fn(pools) {
          // Arrange
          let messages = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_with_listener(fn(listener, _connection) {
            use subscription <- result.try(listen(listener, "jobs", messages))
            stop_listener(listener)
            unlisten(listener, subscription)
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.ListenerStopped)
          |> or_fail_with("Expected ListenerStopped")
        }),
      ])
    }),
  )
}

/// The mapping of each message and error of the driver's listener, with
/// no server.
pub fn mapping_tests() -> TestSuite {
  unit.describe("the listener, with no server", [
    unit.group("a start with no server", [
      unit.it("is ConnectFailed", fn() {
        // Act and assert
        // Nothing listens on port 5449 on localhost.
        server_pools.config(5449)
        |> postgres_listener.start_listener
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(
          error.ConnectFailed(error.ConnectionRefused("localhost", 5449)),
        )
        |> or_fail_with("Expected ConnectionRefused")
      }),
    ]),
    unit.group("a listener that does not run", [
      unit.it("gives ListenerStopped to monitor_listener", fn() {
        // Act and assert
        named_listener(process.new_name("no_listener_runs"))
        |> monitor_listener
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(error.ListenerStopped)
        |> or_fail_with("Expected ListenerStopped")
      }),
      unit.it("refuses a config that cannot start, before any supervisor", fn() {
        // Act and assert
        server_pools.config(70_000)
        |> postgres_listener.supervised_listener(name: process.new_name(
          "supervised_listener_bad_port",
        ))
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(error.InvalidConfig(error.InvalidPort(70_000)))
        |> or_fail_with("Expected InvalidConfig(InvalidPort(70000))")
      }),
    ]),
    listen_message_tests(),
    listen_failure_tests(),
    listener_error_tests(),
    unit.group("unsubscribe errors", [
      unit.it("a listener that is gone is ListenerStopped", fn() {
        // Act and assert
        listener.ListenerGone
        |> should
        |> map_unsubscribe_error()
        |> be_equal(error.ListenerStopped)
        |> or_fail_with("Expected ListenerStopped")
      }),
    ]),
    listener_start_error_tests(),
  ])
}

fn listen_message_tests() {
  unit.group("listen messages", [
    unit.it("a notification keeps its channel, payload and process", fn() {
      // Act and assert
      listener.NotificationArrived(connection_outcome.Notification(
        process_id: 42,
        channel: "jobs",
        payload: "hello",
      ))
      |> should
      |> map_listen_message()
      |> be_equal(NotificationArrived(
        channel: "jobs",
        payload: "hello",
        process_id: 42,
      ))
      |> or_fail_with("Expected the notification")
    }),
    unit.it("NotListening stays NotListening", fn() {
      // Act and assert
      listener.NotListening
      |> should
      |> map_listen_message()
      |> be_equal(NotListening)
      |> or_fail_with("Expected NotListening")
    }),
    unit.it("Listening keeps its channel", fn() {
      // Act and assert
      listener.Listening("jobs")
      |> should
      |> map_listen_message()
      |> be_equal(Listening("jobs"))
      |> or_fail_with("Expected Listening(jobs)")
    }),
    unit.it("a failed LISTEN keeps its channel and its reason", fn() {
      // Act and assert
      listener.ListenFailed("jobs", listener.ListenDeadlinePassed(True))
      |> should
      |> map_listen_message()
      |> be_equal(ListenFailed(
        channel: "jobs",
        error: postgres_failure.without_query(error.QueryTimeout(
          stopped_on_server: True,
        )),
      ))
      |> or_fail_with("Expected ListenFailed with QueryTimeout")
    }),
  ])
}

fn listen_failure_tests() {
  unit.group("failed LISTENs", [
    unit.it("a refused LISTEN is Server", fn() {
      // Arrange
      let report = server_reports.administrator_shutdown()

      // Act and assert
      listener.ListenRefused(report, Idle)
      |> should
      |> map_listen_failure()
      |> be_equal(error.Server(error.server_error_from_report(report)))
      |> or_fail_with("Expected the report as a Server reason")
    }),
    unit.it("an unexpected answer is UnexpectedListenAnswer", fn() {
      // Act and assert
      listener.ListenAnswerUnexpected
      |> should
      |> map_listen_failure()
      |> be_equal(error.UnexpectedListenAnswer)
      |> or_fail_with("Expected UnexpectedListenAnswer")
    }),
    unit.it("a passed deadline is QueryTimeout", fn() {
      // Act and assert
      listener.ListenDeadlinePassed(False)
      |> should
      |> map_listen_failure()
      |> be_equal(error.QueryTimeout(stopped_on_server: False))
      |> or_fail_with("Expected QueryTimeout(False)")
    }),
    unit.it("a zero byte in the channel is RequestNotWritable", fn() {
      // Act and assert
      listener.ChannelHasZeroByte
      |> should
      |> map_listen_failure()
      |> be_equal(
        error.RequestNotWritable(error.ZeroByteInString("channel name")),
      )
      |> or_fail_with("Expected RequestNotWritable for the channel name")
    }),
    unit.it("a connection process that is gone is ConnectionProcessDown", fn() {
      // Act and assert
      listener.ListenerConnectionDown
      |> should
      |> map_listen_failure()
      |> be_equal(error.ConnectionProcessDown)
      |> or_fail_with("Expected ConnectionProcessDown")
    }),
  ])
}

fn listener_error_tests() {
  unit.group("refused subscribes", [
    unit.it("a long channel name is ChannelTooLong", fn() {
      // Act and assert
      listener.ChannelTooLong(too_long_channel)
      |> should
      |> map_listener_error()
      |> be_equal(error.ChannelTooLong(too_long_channel))
      |> or_fail_with("Expected ChannelTooLong")
    }),
    unit.it("a subject with no process is SubscriberHasNoProcess", fn() {
      // Act and assert
      listener.SubscriberHasNoProcess
      |> should
      |> map_listener_error()
      |> be_equal(error.SubscriberHasNoProcess)
      |> or_fail_with("Expected SubscriberHasNoProcess")
    }),
    unit.it("a failed LISTEN gives the reason of its failure", fn() {
      // Act and assert
      listener.SubscribeFailed(listener.ListenAnswerUnexpected)
      |> should
      |> map_listener_error()
      |> be_equal(error.UnexpectedListenAnswer)
      |> or_fail_with("Expected UnexpectedListenAnswer")
    }),
    unit.it("a listener that is gone is ListenerStopped", fn() {
      // Act and assert
      listener.ListenerProcessDown
      |> should
      |> map_listener_error()
      |> be_equal(error.ListenerStopped)
      |> or_fail_with("Expected ListenerStopped")
    }),
  ])
}

fn listener_start_error_tests() {
  unit.group("listener start errors", [
    unit.it("a failed connect is ConnectFailed", fn() {
      // Act and assert
      listener.ConnectFailed(connection_event.SetupTimedOut)
      |> should
      |> map_listener_start_error("db", 5432)
      |> be_equal(error.ConnectFailed(error.SetupTimedOut))
      |> or_fail_with("Expected ConnectFailed(SetupTimedOut)")
    }),
    unit.it("a start that timed out is ListenerStartTimedOut", fn() {
      // Act and assert
      listener.ListenerNotStarted(actor.InitTimeout)
      |> should
      |> map_listener_start_error("db", 5432)
      |> be_equal(error.ListenerStartFailed(error.ListenerStartTimedOut))
      |> or_fail_with("Expected ListenerStartTimedOut")
    }),
    unit.it("a refused start is ListenerInitFailed", fn() {
      // Act and assert
      listener.ListenerNotStarted(actor.InitFailed("no connection"))
      |> should
      |> map_listener_start_error("db", 5432)
      |> be_equal(
        error.ListenerStartFailed(error.ListenerInitFailed("no connection")),
      )
      |> or_fail_with("Expected ListenerInitFailed")
    }),
    unit.it("an exit during the start is ListenerProcessExited", fn() {
      // Act and assert
      listener.ListenerNotStarted(actor.InitExited(process.Killed))
      |> should
      |> map_listener_start_error("db", 5432)
      |> be_equal(
        error.ListenerStartFailed(error.ListenerProcessExited("killed")),
      )
      |> or_fail_with("Expected ListenerProcessExited(killed)")
    }),
  ])
}
