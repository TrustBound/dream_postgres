//// Tests for `dream_postgres/driver/connection`, the connection process,
//// on the driver servers of PostgreSQL 16 to 19. A test proxy between the
//// process and the server breaks the connection on purpose, and a second
//// connection controls the server, so no test sleeps.

import dream_postgres/driver/connection.{
  type ConnectionConfig, type ConnectionEvent, type DriverError,
  type StatementCaching, Backoff, CacheStatements, ConnectionConfig,
  ConnectionLost, ConnectionProcessDown, CopyStatementRefused, DeadlinePassed,
  InvalidRequest, LoginUndecodable, ProtocolViolation, Reconnected,
  SetupTimedOut, TransportRefused, UndecodableMessage, UnexpectedIdleMessage,
  UnnamedStatements, aborted_by, prepare, run, run_script, server_parameter,
  settled_transaction_status, start, stop, supervised, transaction_status,
}
import dream_postgres/driver/message.{
  BindComplete, Protocol32, TooManyItems, UnknownMessageType, ZeroByteInString,
}
import dream_postgres/driver/statement_cache.{default_limit}
import dream_postgres/driver/transport.{
  ConnectRefused, ConnectionReset, SendTimedOut, SocketClosed,
}
import dream_postgres/internal/cell.{
  Binary, BinaryFormat, ColumnDescription, CommandResult, Idle,
  InFailedTransaction, InTransaction, Null, ParameterDescription,
  StatementDescription, Text,
}
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should, start_with,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/cancel_gate.{
  CancelPassed, MainBytes, gate_events, record_gate, release_gate,
  start_cancel_gate, stop_cancel_gate,
}
import driver/fake_server.{
  Answer, free_port, start_fake_server, start_silent_server,
}
import driver/proxy.{
  type Proxy, answer_next_request, client_end, close_client, inject,
  reset_client, start_proxy, stop_listening, watch_client_end,
}
import driver/server_connection.{
  ask_transaction_status, backend_pid, caching_config, caller_answer,
  connection_config, lock_waiter_pid, next_event,
  next_event_after_refused_reconnects, protocol_config, resume_connection,
  send_stray_message, start_announced_caller, start_caller, start_configured,
  start_connection, start_in_ended_owner, start_proxied,
  start_proxied_with_caching, stop_proxied, suspend_connection,
  terminate_backend, tls_config, user_config, wait_for_lock_waiter,
  wait_for_parameter, wait_for_table_waiter, watched_config,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/driver_tls.{verify_full}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/static_supervisor
import gleam/string.{repeat}
import matchers/extract_changed_column_names.{extract_changed_column_names}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_command_tag.{extract_command_tag}
import matchers/extract_disconnect_error.{extract_disconnect_error}
import matchers/extract_driver_error_code.{extract_driver_error_code}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_first.{extract_first}
import matchers/extract_login_refusal_code.{extract_login_refusal_code}
import matchers/extract_outcome_notices.{extract_outcome_notices}
import matchers/extract_outcome_notifications.{extract_outcome_notifications}
import matchers/extract_outcome_tags.{extract_outcome_tags}
import matchers/extract_reconnect_error.{extract_reconnect_error}
import matchers/extract_refusal_status.{extract_refusal_status}
import matchers/extract_refused_copy_outcomes.{extract_refused_copy_outcomes}
import matchers/extract_report_code.{extract_report_code}
import matchers/extract_result_columns.{extract_result_columns}
import matchers/extract_script_failure_outcomes.{extract_script_failure_outcomes}
import matchers/extract_unexpected_server_message.{
  extract_unexpected_server_message,
}

/// The tests of the connection process.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/connection", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("starting", start_tests()),
    group("losing the connection", loss_tests()),
    group("a refused reconnect", refused_reconnect_tests()),
    group("callers", caller_tests()),
    group("more paths", more_tests()),
    group("the statement cache", map(driver_servers(), cache_tests)),
    group("deadlines on each server", map(driver_servers(), deadline_tests)),
    group("deadlines", more_deadline_tests()),
  ])
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("keeps the server_version that the login reported", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let version = server_parameter(connection, "server_version")
      stop(connection)

      // Assert
      version
      |> should
      |> be_ok
      |> be_some
      |> start_with(to_string(server.version) <> ".")
      |> or_fail_with("Expected the server_version of the server")
    }),
    it("prepares a statement", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let sql = "SELECT relname FROM pg_class WHERE oid = $1"

      // Act
      let description = prepare(connection, sql, 5000)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(
        StatementDescription(parameters: [ParameterDescription(26)], columns: [
          ColumnDescription("relname", 19, -1, 1259, 2),
        ]),
      )
      |> or_fail_with("Expected the description of the statement")
    }),
    it("runs a statement with a binary parameter and a binary result", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let outcome =
        run(
          connection,
          "SELECT $1::int4 + 1",
          [Binary(<<41:32>>)],
          [
            BinaryFormat,
          ],
          5000,
        )
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> be_equal(CommandResult(
        rows: [[Binary(<<42:32>>)]],
        tag: "SELECT 1",
        count: 1,
      ))
      |> or_fail_with("Expected 42 as a binary int4")
    }),
    it("describes the result column of a run", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let outcome =
        run(
          connection,
          "SELECT $1::int4 + 1",
          [Binary(<<41:32>>)],
          [
            BinaryFormat,
          ],
          5000,
        )
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_result_columns
      |> be_equal([ColumnDescription("?column?", 23, -1, 0, 0)])
      |> or_fail_with("Expected one int4 column")
    }),
    it("runs a script with one outcome for each statement", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let sql =
        "CREATE TEMP TABLE t (id int); INSERT INTO t VALUES (1); SELECT id FROM t"

      // Act
      let outcomes = run_script(connection, sql, 5000)
      stop(connection)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["CREATE TABLE", "INSERT 0 1", "SELECT 1"])
      |> or_fail_with("Expected one tag for each statement")
    }),
    group("a statement that fails inside a transaction", [
      it("fails the statement with 22012", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let failed = run(connection, "SELECT 1/0", [], [], 5000)
        stop(connection)

        // Assert
        failed
        |> should
        |> be_error
        |> extract_driver_error_code
        |> be_equal("22012")
        |> or_fail_with("Expected 22012")
      }),
      it("keeps the report of the statement that aborted it", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let _failed = run(connection, "SELECT 1/0", [], [], 5000)
        let aborting = aborted_by(connection)
        stop(connection)

        // Assert
        aborting
        |> should
        |> be_ok
        |> be_some
        |> extract_report_code
        |> be_equal("22012")
        |> or_fail_with("Expected the report 22012")
      }),
      it("answers a COMMIT of a failed transaction with ROLLBACK", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let _failed = run(connection, "SELECT 1/0", [], [], 5000)
        let committed = run_script(connection, "COMMIT", 5000)
        stop(connection)

        // Assert
        committed
        |> should
        |> be_ok
        |> extract_outcome_tags
        |> be_equal(["ROLLBACK"])
        |> or_fail_with("Expected the tag ROLLBACK")
      }),
      it("keeps no report after the COMMIT", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let _failed = run(connection, "SELECT 1/0", [], [], 5000)
        let _committed = run_script(connection, "COMMIT", 5000)
        let aborting = aborted_by(connection)
        stop(connection)

        // Assert
        aborting
        |> should
        |> be_ok
        |> be_none
        |> or_fail_with("Expected no report")
      }),
    ]),
    group("the transaction status", [
      it("knows the transaction status after BEGIN", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let status = transaction_status(connection)
        stop(connection)

        // Assert
        status
        |> should
        |> be_ok
        |> be_equal(InTransaction)
        |> or_fail_with("Expected InTransaction after BEGIN")
      }),
      it("knows the transaction status after a failed statement", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let _failed = run_script(connection, "SELECT 1/0", 5000)
        let status = transaction_status(connection)
        stop(connection)

        // Assert
        status
        |> should
        |> be_ok
        |> be_equal(InFailedTransaction)
        |> or_fail_with("Expected InFailedTransaction after the error")
      }),
      it("knows the transaction status after ROLLBACK", fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let _begun = run_script(connection, "BEGIN", 5000)
        let _failed = run_script(connection, "SELECT 1/0", 5000)
        let _rolled_back = run_script(connection, "ROLLBACK", 5000)
        let status = transaction_status(connection)
        stop(connection)

        // Assert
        status
        |> should
        |> be_ok
        |> be_equal(Idle)
        |> or_fail_with("Expected Idle after ROLLBACK")
      }),
    ]),
    it("gives the notices and notifications with the outcome", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let outcomes = run_script(connection, notice_script, 5000)
      stop(connection)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_notices
      |> be_equal([[], [], ["hello"]])
      |> or_fail_with("Expected the notice on the last outcome")
    }),
    it("gives the notifications with the outcome", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let outcomes = run_script(connection, notice_and_notify_script, 5000)
      stop(connection)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_notifications
      |> be_equal([[], [], [#("jobs", "done")]])
      |> or_fail_with("Expected the notification on the last outcome")
    }),
  ])
}

/// The notice test and the notification test run at the same time on the
/// same server, so each one listens on a channel of its own.
const notice_script =
  "LISTEN notice_jobs; DO $$ BEGIN RAISE NOTICE 'hello'; END $$; NOTIFY notice_jobs, 'done'"

const notice_and_notify_script =
  "LISTEN jobs; DO $$ BEGIN RAISE NOTICE 'hello'; END $$; NOTIFY jobs, 'done'"

// Starting --------------------------------------------------------------------

fn start_tests() {
  [
    it("gives the server's 28P01 for a wrong password", fn() {
      // Arrange
      let config = user_config(first_driver_server.port, "dream", "wrong")

      // Act
      let started = start(config)

      // Assert
      started
      |> should
      |> be_error
      |> extract_login_refusal_code
      |> be_equal("28P01")
      |> or_fail_with("Expected the login refusal 28P01")
    }),
    it("gives TransportRefused for a port with no listener", fn() {
      // Arrange
      let config = connection_config(free_port())

      // Act
      let started = start(config)

      // Assert
      started
      |> should
      |> be_error
      |> be_equal(TransportRefused(ConnectRefused))
      |> or_fail_with("Expected TransportRefused(ConnectRefused)")
    }),
    it("gives SetupTimedOut for a server that never answers", fn() {
      // Arrange
      let config =
        ConnectionConfig(
          ..connection_config(start_silent_server()),
          setup_timeout_milliseconds: 100,
        )

      // Act
      let started = start(config)

      // Assert
      started
      |> should
      |> be_error
      |> be_equal(SetupTimedOut)
      |> or_fail_with("Expected SetupTimedOut")
    }),
    it("sends Terminate when it stops", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_driver_server.port)
      let connection = start_connection(port)

      // Act
      let watch = watch_client_end(proxy)
      stop(connection)
      let last_bytes = client_end(watch)

      // Assert
      last_bytes
      |> should
      |> be_equal(<<"X", 4:32>>)
      |> or_fail_with("Expected a Terminate as the last bytes")
    }),
    it("gives ConnectionProcessDown after it stopped", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      stop(connection)
      let status = transaction_status(connection)

      // Assert
      status
      |> should
      |> be_error
      |> be_equal(ConnectionProcessDown)
      |> or_fail_with("Expected ConnectionProcessDown")
    }),
  ]
}

// Losing the connection ---------------------------------------------------------

fn loss_tests() {
  [
    it("notices at once when the server ends an idle session", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 10)
      let pid = backend_pid(proxied.connection)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let lost = next_event(proxied.events)
      stop_proxied(proxied)

      // Assert
      lost
      |> should
      |> be_ok
      |> extract_disconnect_error
      |> extract_ending_report
      |> extract_report_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the loss by 57P01")
    }),
    it("reconnects after the server ended an idle session", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 10)
      let pid = backend_pid(proxied.connection)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let _lost = next_event(proxied.events)
      let back = next_event(proxied.events)
      stop_proxied(proxied)

      // Assert
      back
      |> should
      |> be_ok
      |> be_equal(Reconnected)
      |> or_fail_with("Expected the reconnect after the loss")
    }),
    it("runs a statement again after it reconnected", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 10)
      let pid = backend_pid(proxied.connection)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let _lost = next_event(proxied.events)
      let _back = next_event(proxied.events)
      let outcomes = run_script(proxied.connection, "SELECT 1", 5000)
      stop_proxied(proxied)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected SELECT 1 on the new session")
    }),
    it("fails a request while the connection is lost", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let pid = backend_pid(proxied.connection)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let _lost = next_event(proxied.events)
      send_stray_message(proxied.connection)
      let answer = run_script(proxied.connection, "SELECT 1", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the error of the loss")
    }),
    loss_event_test(
      "a close by the network",
      close_client,
      ConnectionLost(SocketClosed),
    ),
    loss_event_test(
      "a reset by the network",
      reset_client,
      ConnectionLost(ConnectionReset),
    ),
    loss_event_test(
      "bytes that are not a message",
      fn(proxy) { inject(proxy, <<"x", 4:32>>) },
      ProtocolViolation(UndecodableMessage(UnknownMessageType(120))),
    ),
    loss_event_test(
      "a message between requests that is not allowed",
      fn(proxy) { inject(proxy, <<"2", 4:32>>) },
      ProtocolViolation(UnexpectedIdleMessage(BindComplete)),
    ),
    it("fails a running request with the loss", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(823)", 5000)
      let running =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(823)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 823)
      let _waiting =
        start_caller(fn() { run_script(proxied.connection, "SELECT 1", 5000) })
      let pid = lock_waiter_pid(proxied.control, 823)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let answer = caller_answer(running)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(823)", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> extract_driver_error_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the loss for the running request")
    }),
    it("fails a running request with the loss and the waiting ones too", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(831)", 5000)
      let _running =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(831)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 831)
      let waiting =
        start_caller(fn() { run_script(proxied.connection, "SELECT 1", 5000) })
      let pid = lock_waiter_pid(proxied.control, 831)

      // Act
      let _terminated = terminate_backend(proxied.control, pid)
      let answer = caller_answer(waiting)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(831)", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> extract_driver_error_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the loss for the waiting request")
    }),
    it("gives a violation to the running request", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(824)", 5000)
      let running =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(824)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 824)

      // Act
      inject(proxied.proxy, <<"2", 4:32>>)
      let answer = caller_answer(running)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(824)", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> extract_unexpected_server_message
      |> be_equal(BindComplete)
      |> or_fail_with("Expected a protocol violation for the running request")
    }),
    // The proxy reads the first bytes of a large script, answers them with
    // a CopyInResponse as if the server did, and reads nothing more. The
    // step answers with a CopyFail, whose send waits behind the rest of the
    // script in the socket's queue and fails after the send timeout of 500
    // milliseconds.
    it("fails a send that the server never reads", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let large = "SELECT '" <> repeat("x", 64_000_000) <> "'"

      // Act
      answer_next_request(proxied.proxy, <<"G", 7:32, 0, 0:16>>)
      let answer = run_script(proxied.connection, large, 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ConnectionLost(SendTimedOut))
      |> or_fail_with("Expected the loss by a send timeout")
    }),
    it("ignores a message that is not about its socket", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 10)

      // Act
      send_stray_message(proxied.connection)
      let outcomes = run_script(proxied.connection, "SELECT 1", 5000)
      stop_proxied(proxied)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the connection to work")
    }),
  ]
}

fn loss_event_test(
  name: String,
  breaking: fn(Proxy) -> Nil,
  expected: DriverError,
) {
  it("tells of " <> name, fn() {
    // Arrange
    let proxied = start_proxied(first_driver_server, 60_000)

    // Act
    breaking(proxied.proxy)
    let event = next_event(proxied.events)
    stop_proxied(proxied)

    // Assert
    event
    |> should
    |> be_ok
    |> extract_disconnect_error
    |> be_equal(expected)
    |> or_fail_with("Expected the event of " <> name)
  })
}

// A refused reconnect ---------------------------------------------------------

/// The password of dream_reconnect changes while it is logged in, so the
/// reconnect fails with 28P01. The password goes back, and the next attempt
/// works. Each test changes the password of the same role, so each one is
/// in a group of its own: the groups run one after the other.
fn refused_reconnect_tests() {
  [
    group("the loss", [
      it("tells of the loss before a refused reconnect", fn() {
        // Arrange
        let events = process.new_subject()
        let config =
          user_config(first_driver_server.port, "dream_reconnect", "dream")
        let connection = start_configured(watched_config(config, events, 10))
        let control = start_connection(first_driver_server.port)
        let pid = backend_pid(connection)

        // Act
        let _changed = run_script(control, change_password, 5000)
        let _terminated = terminate_backend(control, pid)
        let lost = next_event(events)
        let _refused = next_event(events)
        let _restored = run_script(control, restore_password, 5000)
        let _back = next_event_after_refused_reconnects(events)
        stop(connection)
        stop(control)

        // Assert
        lost
        |> should
        |> be_ok
        |> extract_disconnect_error
        |> extract_ending_report
        |> extract_report_code
        |> be_equal("57P01")
        |> or_fail_with("Expected the loss by 57P01")
      }),
    ]),
    group("the refusal", [
      it("tells of a failed reconnect, and tries again", fn() {
        // Arrange
        let events = process.new_subject()
        let config =
          user_config(first_driver_server.port, "dream_reconnect", "dream")
        let connection = start_configured(watched_config(config, events, 10))
        let control = start_connection(first_driver_server.port)
        let pid = backend_pid(connection)

        // Act
        let _changed = run_script(control, change_password, 5000)
        let _terminated = terminate_backend(control, pid)
        let _lost = next_event(events)
        let refused = next_event(events)
        let _restored = run_script(control, restore_password, 5000)
        let _back = next_event_after_refused_reconnects(events)
        stop(connection)
        stop(control)

        // Assert
        refused
        |> should
        |> be_ok
        |> extract_reconnect_error
        |> extract_login_refusal_code
        |> be_equal("28P01")
        |> or_fail_with("Expected a reconnect refused with 28P01")
      }),
    ]),
    group("the reconnect", [
      it("reconnects once the password works again", fn() {
        // Arrange
        let events = process.new_subject()
        let config =
          user_config(first_driver_server.port, "dream_reconnect", "dream")
        let connection = start_configured(watched_config(config, events, 10))
        let control = start_connection(first_driver_server.port)
        let pid = backend_pid(connection)

        // Act
        let _changed = run_script(control, change_password, 5000)
        let _terminated = terminate_backend(control, pid)
        let _lost = next_event(events)
        let _refused = next_event(events)
        let _restored = run_script(control, restore_password, 5000)
        let back = next_event_after_refused_reconnects(events)
        stop(connection)
        stop(control)

        // Assert
        back
        |> should
        |> be_ok
        |> be_equal(Reconnected)
        |> or_fail_with("Expected the reconnect after the refusals")
      }),
    ]),
  ]
}

const change_password = "ALTER ROLE dream_reconnect PASSWORD 'other'"

const restore_password = "ALTER ROLE dream_reconnect PASSWORD 'dream'"

// Callers ---------------------------------------------------------------------

fn caller_tests() {
  [
    it("stays usable after a caller is killed mid-query", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(825)", 5000)
      let caller =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(825)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 825)

      // Act
      process.kill(caller.pid)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(825)", 5000)
      let outcome = run(proxied.connection, "SELECT 2", [], [], 5000)
      stop_proxied(proxied)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"2">>)]])
      |> or_fail_with("Expected the next query's own result")
    }),
    it("runs the first of two requests", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(827)", 5000)
      let first =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(827)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 827)
      let _second =
        start_caller(fn() { run_script(proxied.connection, "SELECT 4", 5000) })

      // Act
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(827)", 5000)
      let answer = caller_answer(first)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the first request to run")
    }),
    it("runs a request that waited behind another", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(833)", 5000)
      let _first =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(833)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 833)
      let second =
        start_caller(fn() { run_script(proxied.connection, "SELECT 4", 5000) })

      // Act
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(833)", 5000)
      let answer = caller_answer(second)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the waiting request to run after the first")
    }),
    it("refuses SQL with a zero byte before it sends anything", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = run(connection, "SELECT 1\u{0000}", [], [], 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest")
    }),
    it("refuses a COPY statement with the statement before it", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let refused =
        run_script(connection, "SELECT 1; COPY (SELECT 1) TO STDOUT", 5000)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_refused_copy_outcomes
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the refusal with the statement before it")
    }),
    it("refuses a COPY statement and stays usable", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let _refused =
        run_script(connection, "SELECT 1; COPY (SELECT 1) TO STDOUT", 5000)
      let next = run_script(connection, "SELECT 5", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected SELECT 1 after the refusal")
    }),
    it("gives ScriptFailed with the statements that ran", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = run_script(connection, "SELECT 1; SELECT 1/0", 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_script_failure_outcomes
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the completed statement")
    }),
    it("gives ScriptFailed with the code of the failed statement", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = run_script(connection, "SELECT 1; SELECT 1/0", 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("22012")
      |> or_fail_with("Expected 22012")
    }),
    it("refuses a prepare that the server refuses", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = prepare(connection, "SELECT * FROM no_such_table", 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("42P01")
      |> or_fail_with("Expected 42P01")
    }),
    it("binds a NULL parameter", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let outcome = run(connection, "SELECT $1::text IS NULL", [Null], [], 5000)
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"t">>)]])
      |> or_fail_with("Expected true")
    }),
  ]
}

// More paths ------------------------------------------------------------------

fn more_tests() {
  [
    it("runs a statement over TLS", fn() {
      // Arrange
      let config =
        tls_config(connection_config(first_driver_server.port), verify_full())
      let connection = start_configured(config)

      // Act
      let outcomes = run_script(connection, "SELECT 1", 5000)
      stop(connection)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected SELECT 1 over TLS")
    }),
    it("sends Terminate when the process that started it ends", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_driver_server.port)
      let config = connection_config(port)

      // Act
      let watch = watch_client_end(proxy)
      let _started = start_in_ended_owner(fn() { start(config) })
      let last_bytes = client_end(watch)

      // Assert
      last_bytes
      |> should
      |> be_equal(<<"X", 4:32>>)
      |> or_fail_with("Expected a Terminate when the owner ended")
    }),
    it("starts under a supervisor", fn() {
      // Arrange
      let supervisor =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(
          supervised(connection_config(first_driver_server.port)),
        )

      // Act
      let started =
        start_in_ended_owner(fn() { static_supervisor.start(supervisor) })

      // Assert
      started
      |> should
      |> be_ok
      |> be_ok
      |> or_fail_with("Expected the supervisor to start the connection")
    }),
    it("fails the supervisor's start when it cannot connect", fn() {
      // Arrange
      let supervisor =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(supervised(connection_config(free_port())))

      // Act
      let started =
        start_in_ended_owner(fn() { static_supervisor.start(supervisor) })

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> or_fail_with("Expected the supervisor's start to fail")
    }),
    it("gives LoginUndecodable for bytes that are not a message", fn() {
      // Arrange
      let #(port, _server) = start_fake_server(Answer(<<"x", 4:32>>))

      // Act
      let started = start(connection_config(port))

      // Assert
      started
      |> should
      |> be_error
      |> be_equal(LoginUndecodable(UnknownMessageType(120)))
      |> or_fail_with("Expected LoginUndecodable")
    }),
    it("refuses a prepare with a zero byte", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = prepare(connection, "SELECT 1\u{0000}", 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the prepare")
    }),
    it("refuses a script with a zero byte", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let answer = run_script(connection, "SELECT 1\u{0000}", 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the script")
    }),
    it("fails a prepare while the connection is lost", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)

      // Act
      close_client(proxied.proxy)
      let _lost = next_event(proxied.events)
      let answer = prepare(proxied.connection, "SELECT 1", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(ConnectionLost(SocketClosed))
      |> or_fail_with("Expected the error of the loss")
    }),
    // The proxy sends a NoticeResponse, a NotificationResponse and a
    // ParameterStatus as if the server sent them between requests. The
    // next outcome carries the notice and the notification, and the
    // parameter has its new value.
    it(
      "keeps the parameter changes, notices and notifications between requests",
      fn() {
        // Arrange
        let proxied = start_proxied(first_driver_server, 60_000)

        // Act
        inject(proxied.proxy, idle_messages())
        let _handled =
          wait_for_parameter(proxied.connection, "application_name", "injected")
        let outcomes = run_script(proxied.connection, "SELECT 1", 5000)
        stop_proxied(proxied)

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_outcome_notices
        |> be_equal([["an idle notice"]])
        |> or_fail_with("Expected the notice of the idle time")
      },
    ),
    it("keeps the notifications between requests", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)

      // Act
      inject(proxied.proxy, idle_messages())
      let _handled =
        wait_for_parameter(proxied.connection, "application_name", "injected")
      let outcomes = run_script(proxied.connection, "SELECT 1", 5000)
      stop_proxied(proxied)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_notifications
      |> be_equal([[#("idle_jobs", "idle")]])
      |> or_fail_with("Expected the notification of the idle time")
    }),
    it("keeps a parameter change during a script", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let sql = "SET application_name = 'during a script'"

      // Act
      let _set = run_script(connection, sql, 5000)
      let name = server_parameter(connection, "application_name")
      stop(connection)

      // Assert
      name
      |> should
      |> be_ok
      |> be_some
      |> be_equal("during a script")
      |> or_fail_with("Expected the new application_name")
    }),
    it("fails the running request when the network closes", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(828)", 5000)
      let running =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(828)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 828)

      // Act
      close_client(proxied.proxy)
      let answer = caller_answer(running)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(828)", 5000)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> be_equal(ConnectionLost(SocketClosed))
      |> or_fail_with("Expected the loss for the running request")
    }),
    running_run_lost_test(
      "fails a running cached run when the network closes",
      CacheStatements(default_limit),
      830,
    ),
    running_prepare_lost_test(
      "fails a running named prepare when the network closes",
      CacheStatements(default_limit),
      "driver_prepare_lock_cached",
    ),
    running_run_lost_test(
      "fails a running unnamed run when the network closes",
      UnnamedStatements,
      831,
    ),
    running_prepare_lost_test(
      "fails a running unnamed prepare when the network closes",
      UnnamedStatements,
      "driver_prepare_lock_unnamed",
    ),
    it("refuses COPY FROM STDIN in a run", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let _created = run_script(connection, "CREATE TEMP TABLE c (x int)", 5000)
      let refused = run(connection, "COPY c FROM STDIN", [], [], 5000)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> be_equal(CopyStatementRefused([]))
      |> or_fail_with("Expected the refusal with no statement before it")
    }),
    it("refuses COPY FROM STDIN in a run and stays usable", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let _created = run_script(connection, "CREATE TEMP TABLE c (x int)", 5000)
      let _refused = run(connection, "COPY c FROM STDIN", [], [], 5000)
      let next = run_script(connection, "SELECT 6", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected SELECT 1 after the refusal")
    }),
  ]
}

/// A run waits on the advisory lock `key`. The proxy closes the connection,
/// and the caller gets the loss. Each caching uses its own key, so the
/// tests can run at the same time.
fn running_run_lost_test(name: String, caching: StatementCaching, key: Int) {
  it(name, fn() {
    // Arrange
    let proxied =
      start_proxied_with_caching(first_driver_server, 60_000, caching)
    let lock = "SELECT pg_advisory_lock(" <> to_string(key) <> ")"
    let _locked = run_script(proxied.control, lock, 5000)
    let running =
      start_caller(fn() { run(proxied.connection, lock, [], [], 5000) })
    let _waited = wait_for_lock_waiter(proxied.control, key)

    // Act
    close_client(proxied.proxy)
    let answer = caller_answer(running)
    let unlock = "SELECT pg_advisory_unlock(" <> to_string(key) <> ")"
    let _unlocked = run_script(proxied.control, unlock, 5000)
    stop_proxied(proxied)

    // Assert
    answer
    |> should
    |> be_ok
    |> be_error
    |> be_equal(ConnectionLost(SocketClosed))
    |> or_fail_with("Expected the loss for the running run")
  })
}

/// A prepare waits on `table`, that the control connection locks: its
/// Parse needs a lock on the table too. The proxy closes the connection,
/// and the caller gets the loss.
fn running_prepare_lost_test(
  name: String,
  caching: StatementCaching,
  table: String,
) {
  it(name, fn() {
    // Arrange
    let proxied =
      start_proxied_with_caching(first_driver_server, 60_000, caching)
    let create = "CREATE TABLE IF NOT EXISTS " <> table <> " (x int)"
    let lock = "BEGIN; LOCK TABLE " <> table <> " IN ACCESS EXCLUSIVE MODE"
    let _created = run_script(proxied.control, create, 5000)
    let _locked = run_script(proxied.control, lock, 5000)
    let running =
      start_caller(fn() {
        prepare(proxied.connection, "SELECT x FROM " <> table, 5000)
      })
    let _waited = wait_for_table_waiter(proxied.control, table)

    // Act
    close_client(proxied.proxy)
    let answer = caller_answer(running)
    let _released = run_script(proxied.control, "ROLLBACK", 5000)
    stop_proxied(proxied)

    // Assert
    answer
    |> should
    |> be_ok
    |> be_error
    |> be_equal(ConnectionLost(SocketClosed))
    |> or_fail_with("Expected the loss for the running prepare")
  })
}

/// A NoticeResponse, a NotificationResponse and a ParameterStatus, as the
/// server sends them between requests.
fn idle_messages() -> BitArray {
  bit_array.concat([
    notice("an idle notice"),
    notification(4321, "idle_jobs", "idle"),
    parameter_status("application_name", "injected"),
  ])
}

fn notification(process_id: Int, channel: String, payload: String) -> BitArray {
  let body = <<process_id:32, channel:utf8, 0, payload:utf8, 0>>
  <<"A", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn parameter_status(name: String, value: String) -> BitArray {
  let body = <<name:utf8, 0, value:utf8, 0>>
  <<"S", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn notice(text: String) -> BitArray {
  let body = <<
    "S", "NOTICE":utf8, 0, "V", "NOTICE":utf8, 0, "C", "00000":utf8, 0, "M",
    text:utf8, 0, 0,
  >>
  <<"N", { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

// The statement cache ---------------------------------------------------------

/// The prepared statements of the session, from pg_prepared_statements, as
/// "name executions" in name order. A script runs with the simple protocol,
/// so it adds no statement of its own.
const prepared_statements =
  "SELECT name || ' ' || (generic_plans + custom_plans)::text FROM pg_prepared_statements ORDER BY name"

fn cache_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("prepares a statement one time and runs it again by its name", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )

      // Act
      let _first = run(connection, "SELECT 41 + 1", [], [], 5000)
      let _second = run(connection, "SELECT 41 + 1", [], [], 5000)
      let statements = run_script(connection, prepared_statements, 5000)
      stop(connection)

      // Assert
      statements
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"dream_postgres_1 2">>)]])
      |> or_fail_with("Expected one named statement that ran two times")
    }),
    it("prepares a statement one time for two prepares", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )

      // Act
      let _first = prepare(connection, "SELECT 1", 5000)
      let _second = prepare(connection, "SELECT 1", 5000)
      let statements = run_script(connection, prepared_statements, 5000)
      stop(connection)

      // Assert
      statements
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"dream_postgres_1 0">>)]])
      |> or_fail_with("Expected one statement for two prepares")
    }),
    it("gives the same description for two prepares", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )

      // Act
      let first = prepare(connection, "SELECT 1", 5000)
      let second = prepare(connection, "SELECT 1", 5000)
      stop(connection)

      // Assert
      second
      |> should
      |> be_equal(first)
      |> or_fail_with("Expected the same description")
    }),
    it("closes the least recently used statement when the cache is full", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(2)),
        )

      // Act
      let _a = run(connection, "SELECT 'a'", [], [], 5000)
      let _b = run(connection, "SELECT 'b'", [], [], 5000)
      let _a_again = run(connection, "SELECT 'a'", [], [], 5000)
      let _c = run(connection, "SELECT 'c'", [], [], 5000)
      let statements = run_script(connection, prepared_statements, 5000)
      stop(connection)

      // Assert
      statements
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([
        [Text(<<"dream_postgres_1 2">>)],
        [Text(<<"dream_postgres_3 1">>)],
      ])
      |> or_fail_with("Expected b to be closed, as the least recently used")
    }),
    it("prepares again and runs when the statement is gone (26000)", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )

      // Act
      let _first = run(connection, "SELECT 41 + 1", [], [], 5000)
      let _gone = run_script(connection, "DEALLOCATE ALL", 5000)
      let outcome = run(connection, "SELECT 41 + 1", [], [], 5000)
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"42">>)]])
      |> or_fail_with("Expected the run to work after a new prepare")
    }),
    it("gives StatementChanged when the result type changed (0A000)", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )
      let _table =
        run_script(connection, "CREATE TEMP TABLE changing (a int)", 5000)
      let _first = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _altered =
        run_script(connection, "ALTER TABLE changing ADD COLUMN b int", 5000)

      // Act
      let outcome = run(connection, "SELECT * FROM changing", [], [], 5000)
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_error
      |> extract_changed_column_names
      |> be_equal(["a", "b"])
      |> or_fail_with("Expected StatementChanged with both columns")
    }),
    it("runs the changed statement after StatementChanged", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )
      let _table =
        run_script(connection, "CREATE TEMP TABLE changing (a int)", 5000)
      let _first = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _altered =
        run_script(connection, "ALTER TABLE changing ADD COLUMN b int", 5000)

      // Act
      let _changed = run(connection, "SELECT * FROM changing", [], [], 5000)
      let outcome = run(connection, "SELECT * FROM changing", [], [], 5000)
      stop(connection)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_tag
      |> be_equal("SELECT 0")
      |> or_fail_with("Expected the new statement to run")
    }),
    it("gives the error inside a transaction (0A000)", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )
      let _table =
        run_script(connection, "CREATE TEMP TABLE changing (a int)", 5000)
      let _first = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _begun =
        run_script(
          connection,
          "BEGIN; ALTER TABLE changing ADD COLUMN b int",
          5000,
        )

      // Act
      let failed = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _rolled_back = run_script(connection, "ROLLBACK", 5000)
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("0A000")
      |> or_fail_with("Expected 0A000 in the transaction")
    }),
    it("leaves the transaction failed after the error (0A000)", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )
      let _table =
        run_script(connection, "CREATE TEMP TABLE changing (a int)", 5000)
      let _first = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _begun =
        run_script(
          connection,
          "BEGIN; ALTER TABLE changing ADD COLUMN b int",
          5000,
        )

      // Act
      let failed = run(connection, "SELECT * FROM changing", [], [], 5000)
      let _rolled_back = run_script(connection, "ROLLBACK", 5000)
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_refusal_status
      |> be_equal(InFailedTransaction)
      |> or_fail_with("Expected the failed transaction with the error")
    }),
    it("refuses a run with 65536 parameters before it sends them", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(CacheStatements(512)),
        )
      let _prepared = run(connection, "SELECT 1", [], [], 5000)
      let parameters = list.repeat(Null, 65_536)

      // Act
      let refused = run(connection, "SELECT 1", parameters, [], 5000)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> be_equal(InvalidRequest(TooManyItems("parameters", 65_536)))
      |> or_fail_with("Expected TooManyItems for the Bind")
    }),
    it(
      "refuses a prepare and a run with a zero byte with UnnamedStatements",
      fn() {
        // Arrange
        let connection =
          start_configured(
            connection_config(server.port)
            |> caching_config(UnnamedStatements),
          )

        // Act
        let refused = prepare(connection, "SELECT 1\u{0000}", 5000)
        stop(connection)

        // Assert
        refused
        |> should
        |> be_error
        |> be_equal(InvalidRequest(ZeroByteInString("query")))
        |> or_fail_with("Expected InvalidRequest for the prepare")
      },
    ),
    it("refuses a run with a zero byte with UnnamedStatements", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(UnnamedStatements),
        )

      // Act
      let refused = run(connection, "SELECT 1\u{0000}", [], [], 5000)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the run")
    }),
    it("gives the server's error for a run with UnnamedStatements", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(UnnamedStatements),
        )

      // Act
      let refused = run(connection, "SELECT 1/0", [], [], 5000)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("22012")
      |> or_fail_with("Expected 22012")
    }),
    it("prepares no named statement with UnnamedStatements", fn() {
      // Arrange
      let connection =
        start_configured(
          connection_config(server.port)
          |> caching_config(UnnamedStatements),
        )

      // Act
      let _first = run(connection, "SELECT 1", [], [], 5000)
      let _second = prepare(connection, "SELECT 1", 5000)
      let statements = run_script(connection, prepared_statements, 5000)
      stop(connection)

      // Assert
      statements
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([])
      |> or_fail_with("Expected no named statement")
    }),
  ])
}

// Deadlines -------------------------------------------------------------------

// Request A passes its deadline, and the gate holds its cancel. A's
// statement ends by itself, so A gets DeadlinePassed(False). Request B
// then waits: it must not reach the server before A's cancel did, or that
// cancel could stop B.
fn deadline_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("holds the next request until the cancel of the last one is done", fn() {
      // Arrange
      let #(port, gate) = start_cancel_gate(server.port)
      let config =
        ConnectionConfig(
          ..connection_config(port),
          reconnect: Backoff(60_000, 60_000),
          cancel_timeout_milliseconds: 5000,
        )
      let connection = start_configured(config)
      let calling = process.new_subject()

      // Act
      let _first = run(connection, "SELECT pg_sleep(0.3)", [], [], 50)
      record_gate(gate)
      let second =
        start_announced_caller(
          fn() { run_script(connection, "SELECT 1", 5000) },
          calling,
        )
      let _announced = process.receive(calling, 5000)
      let _asked = ask_transaction_status(connection, 20)
      release_gate(gate)
      let _second_answer = caller_answer(second)
      let events = gate_events(gate)
      stop(connection)
      stop_cancel_gate(gate)

      // Assert
      events
      |> should
      |> be_equal([CancelPassed, MainBytes])
      |> or_fail_with("Expected the next request to wait for the cancel")
    }),
    it("gives DeadlinePassed to a request whose cancel the gate holds", fn() {
      // Arrange
      let #(port, gate) = start_cancel_gate(server.port)
      let config =
        ConnectionConfig(
          ..connection_config(port),
          reconnect: Backoff(60_000, 60_000),
          cancel_timeout_milliseconds: 5000,
        )
      let connection = start_configured(config)
      let calling = process.new_subject()

      // Act
      let first = run(connection, "SELECT pg_sleep(0.3)", [], [], 50)
      record_gate(gate)
      let second =
        start_announced_caller(
          fn() { run_script(connection, "SELECT 1", 5000) },
          calling,
        )
      let _announced = process.receive(calling, 5000)
      let _asked = ask_transaction_status(connection, 20)
      release_gate(gate)
      let _second_answer = caller_answer(second)
      stop(connection)
      stop_cancel_gate(gate)

      // Assert
      first
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected DeadlinePassed for the first request")
    }),
    it("runs the request that waited for the cancel", fn() {
      // Arrange
      let #(port, gate) = start_cancel_gate(server.port)
      let config =
        ConnectionConfig(
          ..connection_config(port),
          reconnect: Backoff(60_000, 60_000),
          cancel_timeout_milliseconds: 5000,
        )
      let connection = start_configured(config)
      let calling = process.new_subject()

      // Act
      let _first = run(connection, "SELECT pg_sleep(0.3)", [], [], 50)
      record_gate(gate)
      let second =
        start_announced_caller(
          fn() { run_script(connection, "SELECT 1", 5000) },
          calling,
        )
      let _announced = process.receive(calling, 5000)
      let _asked = ask_transaction_status(connection, 20)
      release_gate(gate)
      let second_answer = caller_answer(second)
      stop(connection)
      stop_cancel_gate(gate)

      // Assert
      second_answer
      |> should
      |> be_ok
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the next request to run")
    }),
    it("cancels a statement at its deadline and stays usable", fn() {
      // Arrange
      let connection = start_configured(cancel_config(server.port))

      // Act
      let _late = run(connection, "SELECT pg_sleep(30)", [], [], 300)
      // The next statement runs longer than the cancel timeout, so the
      // cancel's timer ends while the connection serves another request.
      let next = run(connection, "SELECT pg_sleep(0.3)::text", [], [], 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_tag
      |> be_equal("SELECT 1")
      |> or_fail_with("Expected a new run after the cancel")
    }),
    it("gives a cancelled DeadlinePassed at the deadline", fn() {
      // Arrange
      let connection = start_configured(cancel_config(server.port))

      // Act
      let late = run(connection, "SELECT pg_sleep(30)", [], [], 300)
      stop(connection)

      // Assert
      late
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: True))
      |> or_fail_with("Expected the cancel at the deadline")
    }),
    it("leaves the backend idle after the cancel", fn() {
      // Arrange
      let connection = start_configured(cancel_config(server.port))
      let control = start_connection(server.port)
      let pid = backend_pid(connection)

      // Act
      let _late = run(connection, "SELECT pg_sleep(30)", [], [], 300)
      let state =
        run_script(
          control,
          "SELECT state FROM pg_stat_activity WHERE pid = " <> pid,
          5000,
        )
      stop(connection)
      stop(control)

      // Assert
      state
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"idle">>)]])
      |> or_fail_with("Expected an idle backend after the cancel")
    }),
  ])
}

/// The config of a connection with protocol 3.2, so its cancel key is
/// longer than 4 bytes, and a cancel timeout of 200 milliseconds.
fn cancel_config(port: Int) -> ConnectionConfig {
  ConnectionConfig(
    ..protocol_config(port, Protocol32),
    cancel_timeout_milliseconds: 200,
  )
}

fn more_deadline_tests() {
  [
    it("gives the settled transaction status after a request that waited", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(835)", 5000)
      let begun =
        start_caller(fn() {
          run_script(
            proxied.connection,
            "BEGIN; SELECT pg_advisory_lock(835)",
            5000,
          )
        })
      let _waited = wait_for_lock_waiter(proxied.control, 835)

      // Act
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(835)", 5000)
      let settled = settled_transaction_status(proxied.connection, 5000)
      let _answer = caller_answer(begun)
      let _rolled_back = run_script(proxied.connection, "ROLLBACK", 5000)
      stop_proxied(proxied)

      // Assert
      settled
      |> should
      |> be_ok
      |> be_equal(InTransaction)
      |> or_fail_with("Expected InTransaction once settled")
    }),
    it("gives the transaction status at once while a request waits", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(836)", 5000)
      let begun =
        start_caller(fn() {
          run_script(
            proxied.connection,
            "BEGIN; SELECT pg_advisory_lock(836)",
            5000,
          )
        })
      let _waited = wait_for_lock_waiter(proxied.control, 836)

      // Act
      let quick = transaction_status(proxied.connection)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(836)", 5000)
      let _answer = caller_answer(begun)
      let _rolled_back = run_script(proxied.connection, "ROLLBACK", 5000)
      stop_proxied(proxied)

      // Assert
      quick
      |> should
      |> be_ok
      |> be_equal(Idle)
      |> or_fail_with("Expected Idle at once")
    }),
    it("refuses the settled status while the connection is lost", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)

      // Act
      close_client(proxied.proxy)
      let _lost = next_event(proxied.events)
      let settled = settled_transaction_status(proxied.connection, 5000)
      stop_proxied(proxied)

      // Assert
      settled
      |> should
      |> be_error
      |> be_equal(ConnectionLost(SocketClosed))
      |> or_fail_with("Expected the error of the loss")
    }),
    // A statement passes its deadline through the proxy, and its cancel
    // goes to the proxy too, which serves one session at a time, so it
    // never reaches the server. After the cancel timeout, the connection
    // is closed and the caller gets DeadlinePassed.
    it("closes the connection when the cancel never gets an answer", fn() {
      // Arrange
      let #(port, _proxy) = start_proxy(first_driver_server.port)
      let events = process.new_subject()
      let connection = start_configured(lost_cancel_config(port, events))

      // Act
      let _answer = run(connection, "SELECT pg_sleep(30)", [], [], 100)
      let event = next_event(events)
      stop(connection)

      // Assert
      event
      |> should
      |> be_ok
      |> extract_disconnect_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected the loss of the connection at the deadline")
    }),
    it("gives DeadlinePassed when the cancel never gets an answer", fn() {
      // Arrange
      let #(port, _proxy) = start_proxy(first_driver_server.port)
      let events = process.new_subject()
      let connection = start_configured(lost_cancel_config(port, events))

      // Act
      let answer = run(connection, "SELECT pg_sleep(30)", [], [], 100)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected DeadlinePassed with no answer to the cancel")
    }),
    it("closes the connection when the cancel cannot connect", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_driver_server.port)
      let events = process.new_subject()
      let connection = start_configured(lost_cancel_config(port, events))

      // Act
      stop_listening(proxy)
      let _answer = run(connection, "SELECT pg_sleep(30)", [], [], 100)
      let event = next_event(events)
      stop(connection)

      // Assert
      event
      |> should
      |> be_ok
      |> extract_disconnect_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected the loss of the connection at the deadline")
    }),
    it("gives DeadlinePassed when the cancel cannot connect", fn() {
      // Arrange
      let #(port, proxy) = start_proxy(first_driver_server.port)
      let events = process.new_subject()
      let connection = start_configured(lost_cancel_config(port, events))

      // Act
      stop_listening(proxy)
      let answer = run(connection, "SELECT pg_sleep(30)", [], [], 100)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected DeadlinePassed when the cancel cannot connect")
    }),
    it("closes the connection when the session has no cancel key", fn() {
      // Arrange
      let login_answer = <<"R", 8:32, 0:32, "Z", 5:32, "I">>
      let #(port, _server) = start_fake_server(Answer(login_answer))
      let config =
        ConnectionConfig(
          ..connection_config(port),
          reconnect: Backoff(60_000, 60_000),
          cancel_timeout_milliseconds: 200,
        )
      let connection = start_configured(config)

      // Act
      let answer = run(connection, "SELECT 1", [], [], 100)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected DeadlinePassed with no cancel")
    }),
    it("ends a waiting request at its deadline", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(832)", 5000)
      let first =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(832)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 832)

      // Act
      let waiting = run_script(proxied.connection, "SELECT 1", 100)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(832)", 5000)
      let _first_answer = caller_answer(first)
      stop_proxied(proxied)

      // Assert
      waiting
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected the waiting request to end")
    }),
    it("runs the first request after a waiting one ended", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _locked =
        run_script(proxied.control, "SELECT pg_advisory_lock(834)", 5000)
      let first =
        start_caller(fn() {
          run_script(proxied.connection, "SELECT pg_advisory_lock(834)", 5000)
        })
      let _waited = wait_for_lock_waiter(proxied.control, 834)

      // Act
      let _waiting = run_script(proxied.connection, "SELECT 1", 100)
      let _unlocked =
        run_script(proxied.control, "SELECT pg_advisory_unlock(834)", 5000)
      let first_answer = caller_answer(first)
      stop_proxied(proxied)

      // Assert
      first_answer
      |> should
      |> be_ok
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the first request to run")
    }),
    it("gives DeadlinePassed when the process does not answer in time", fn() {
      // Arrange
      let config =
        ConnectionConfig(
          ..connection_config(first_driver_server.port),
          setup_timeout_milliseconds: 100,
          cancel_timeout_milliseconds: 100,
        )
      let connection = start_configured(config)

      // Act
      suspend_connection(connection)
      let answer = run(connection, "SELECT 1", [], [], 10)
      resume_connection(connection)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected DeadlinePassed from the caller's wait")
    }),
  ]
}

/// The config of a connection through a proxy on `port`, with its events
/// sent to `events`, a first reconnect delay of 60 seconds, and a cancel
/// timeout of 200 milliseconds.
fn lost_cancel_config(
  port: Int,
  events: Subject(ConnectionEvent),
) -> ConnectionConfig {
  ConnectionConfig(
    ..watched_config(connection_config(port), events, 60_000),
    cancel_timeout_milliseconds: 200,
  )
}
