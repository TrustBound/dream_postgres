//// Tests for `dream_postgres/driver/connection`, the connection process,
//// on the driver servers of PostgreSQL 16 to 19. A test proxy between the
//// process and the server breaks the connection on purpose, and a second
//// connection controls the server, so no test sleeps.
////
//// Each describe has one kind of setup: a connection for each test, a
//// proxied connection for each test, or one act that several tests check.
//// The setups and teardowns of `driver/server_connection` start and stop
//// every connection.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type ConnectionEvent, type DriverError,
  type Outcome, Backoff, CacheStatements, ClosedAfterDeadline, ConnectionConfig,
  ConnectionLost, ConnectionProcessDown, CopyStatementRefused, DeadlinePassed,
  InvalidRequest, LoginUndecodable, ProtocolViolation, Reconnected,
  SetupTimedOut, SocketFailed, TransportRefused, UndecodableMessage,
  UnexpectedIdleMessage, UnnamedStatements, aborted_by, prepare, run, run_script,
  server_parameter, settled_transaction_status, start, stop, supervised,
  transaction_status,
}
import dream_postgres/driver/message.{
  BindComplete, Protocol32, TooManyItems, UnknownMessageType, ZeroByteInString,
}
import dream_postgres/driver/transport.{
  ConnectRefused, ConnectionReset, SendTimedOut, SocketClosed,
}
import dream_postgres/internal/cell.{
  type TransactionStatus, Binary, BinaryFormat, ColumnDescription, CommandResult,
  Idle, InFailedTransaction, InTransaction, Null, ParameterDescription,
  StatementDescription, Text,
}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, contain_string, or_fail_with,
  should, start_with,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/cancel_gate.{
  type CancelGate, type GateEvent, CancelPassed, MainBytes, gate_events,
  record_gate, release_gate, start_cancel_gate, stop_cancel_gate,
}
import driver/fake_server.{
  Answer, free_port, start_fake_server, start_silent_server,
}
import driver/proxy.{
  type Proxy, answer_next_request, client_end, close_client, inject,
  reset_client, start_proxy, stop_listening, stop_proxy, watch_client_end,
}
import driver/server_connection.{
  type ProxiedConnection, type ProxiedOutcome, advisory_lock_sql,
  ask_transaction_status, backend_pid, break_session, caller_answer,
  caller_outcomes, cancel_timeout_config, connection_config, connection_setup,
  hold_advisory_lock, inject_and_wait_for_parameter, lock_request,
  lock_waiter_pid, next_event, next_event_after_refused_reconnects,
  parameter_config, pid_of, protocol_config, proxied_act_setup, proxied_setup,
  release_advisory_lock, resume_connection, run_control_script,
  run_control_setup_script, run_failing_script, run_failing_statement,
  run_failing_statement_within, run_setup_script, run_setup_statement,
  send_stray_message, setup_timeout_config, start_announced_caller, start_caller,
  start_configured, start_connection, start_in_ended_owner, start_test_caching,
  start_test_configured, start_test_connection, start_test_proxied,
  start_test_proxied_with_caching, start_watched, stop_after_error,
  stop_connection, stop_proxied, suspend_connection, terminate_backend,
  terminate_session, tls_config, user_config, wait_for_lock_waiter,
  wait_for_mailbox_length, wait_for_message, wait_for_table_waiter,
  watched_config,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/driver_tls.{verify_full}
import gleam/bit_array
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/static_supervisor
import gleam/result.{map_error, try}
import gleam/string.{inspect, repeat}
import matchers/extract_changed_column_names.{extract_changed_column_names}
import matchers/extract_client_end.{extract_client_end}
import matchers/extract_column_origins.{extract_column_origins}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_command_tag.{extract_command_tag}
import matchers/extract_disconnect_error.{extract_disconnect_error}
import matchers/extract_driver_error_code.{extract_driver_error_code}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_first.{extract_first}
import matchers/extract_login_refusal_code.{extract_login_refusal_code}
import matchers/extract_notice_details.{extract_notice_details}
import matchers/extract_notice_messages.{extract_notice_messages}
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

/// The tests of the connection process. The describes run one after the
/// other; the tests of one describe run at the same time.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/connection", [
    connection_tests(),
    start_tests(),
    proxied_tests(),
    loss_tests(),
    refused_reconnect_tests(),
    requests_at_loss_tests(),
    two_requests_tests(),
    suite.group(
      "deadlines on each driver server",
      map(driver_servers(), deadline_tests),
    ),
    lost_cancel_tests(
      "never gets an answer",
      fn(_proxy) { Nil },
      "Expected DeadlinePassed with no answer to the cancel",
    ),
    lost_cancel_tests(
      "cannot connect",
      stop_listening,
      "Expected DeadlinePassed when the cancel cannot connect",
    ),
    keyless_session_tests(),
    waiting_at_deadline_tests(),
    waiting_status_tests(),
  ])
}

// With a connection of its own ------------------------------------------------

fn connection_tests() -> TestSuite {
  describe(
    "with a connection of its own",
    connection_setup(first_driver_server),
    [
      after_each(stop_connection),
      group("on each driver server", map(driver_servers(), server_tests)),
      group("on the first driver server", first_server_tests()),
      group("over TLS", [
        before_each(start_test_configured(
          connection_config(first_driver_server.port)
          |> result.map(tls_config(_, verify_full())),
        )),
        it("runs a statement over TLS", fn(connection) {
          // Act
          let outcomes = run_script(connection, "SELECT 1", 5000)

          // Assert
          outcomes
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected SELECT 1 over TLS")
        }),
      ]),
      group("the statement cache", map(driver_servers(), cache_tests)),
      group("what dream_model needs", map(driver_servers(), model_tests)),
      group("when the process does not answer in time", [
        before_each(start_test_configured(
          connection_config(first_driver_server.port)
          |> result.map(setup_timeout_config(_, 100))
          |> result.map(cancel_timeout_config(_, 100)),
        )),
        it(
          "gives DeadlinePassed when the process does not answer in time",
          fn(connection) {
            // Act
            suspend_connection(connection)
            let answer = run(connection, "SELECT 1", [], [], 10)
            resume_connection(connection)

            // Assert
            answer
            |> should
            |> be_error
            |> be_equal(DeadlinePassed(cancelled: False))
            |> or_fail_with("Expected DeadlinePassed from the caller's wait")
          },
        ),
      ]),
    ],
  )
}

fn server_tests(server: Server) -> ContextNode(Connection) {
  group("PostgreSQL " <> to_string(server.version), [
    before_each(start_test_connection(server)),
    it("keeps the server_version that the login reported", fn(connection) {
      // Act
      let version = server_parameter(connection, "server_version")

      // Assert
      version
      |> should
      |> be_ok
      |> be_some
      |> start_with(to_string(server.version) <> ".")
      |> or_fail_with("Expected the server_version of the server")
    }),
    it("prepares a statement", fn(connection) {
      // Arrange
      let sql = "SELECT relname FROM pg_class WHERE oid = $1"

      // Act
      let description = prepare(connection, sql, 5000)

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
    it(
      "runs a statement with a binary parameter and a binary result",
      fn(connection) {
        // Act
        let outcome =
          run(
            connection,
            "SELECT $1::int4 + 1",
            [Binary(<<41:32>>)],
            [BinaryFormat],
            5000,
          )

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
      },
    ),
    it("describes the result column of a run", fn(connection) {
      // Act
      let outcome =
        run(
          connection,
          "SELECT $1::int4 + 1",
          [Binary(<<41:32>>)],
          [BinaryFormat],
          5000,
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_result_columns
      |> be_equal([ColumnDescription("?column?", 23, -1, 0, 0)])
      |> or_fail_with("Expected one int4 column")
    }),
    it("runs a script with one outcome for each statement", fn(connection) {
      // Arrange
      let sql =
        "CREATE TEMP TABLE t (id int); INSERT INTO t VALUES (1); SELECT id FROM t"

      // Act
      let outcomes = run_script(connection, sql, 5000)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["CREATE TABLE", "INSERT 0 1", "SELECT 1"])
      |> or_fail_with("Expected one tag for each statement")
    }),
    failed_transaction_tests(),
    transaction_status_tests(),
    it("gives the notices and notifications with the outcome", fn(connection) {
      // Act
      let outcomes = run_script(connection, notice_script, 5000)

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_notices
      |> be_equal([[], [], ["hello"]])
      |> or_fail_with("Expected the notice on the last outcome")
    }),
    it("gives the notifications with the outcome", fn(connection) {
      // Act
      let outcomes = run_script(connection, notice_and_notify_script, 5000)

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

fn failed_transaction_tests() -> ContextNode(Connection) {
  group("a statement that fails inside a transaction", [
    before_each(run_setup_script("BEGIN")),
    it("fails the statement with 22012", fn(connection) {
      // Act
      let failed = run(connection, "SELECT 1/0", [], [], 5000)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("22012")
      |> or_fail_with("Expected 22012")
    }),
    group("after the failure", [
      before_each(run_failing_statement("SELECT 1/0")),
      it("keeps the report of the statement that aborted it", fn(connection) {
        // Act
        let aborting = aborted_by(connection)

        // Assert
        aborting
        |> should
        |> be_ok
        |> be_some
        |> extract_report_code
        |> be_equal("22012")
        |> or_fail_with("Expected the report 22012")
      }),
      it(
        "answers a COMMIT of a failed transaction with ROLLBACK",
        fn(connection) {
          // Act
          let committed = run_script(connection, "COMMIT", 5000)

          // Assert
          committed
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["ROLLBACK"])
          |> or_fail_with("Expected the tag ROLLBACK")
        },
      ),
      group("after the COMMIT", [
        before_each(run_setup_script("COMMIT")),
        it("keeps no report after the COMMIT", fn(connection) {
          // Act
          let aborting = aborted_by(connection)

          // Assert
          aborting
          |> should
          |> be_ok
          |> be_none
          |> or_fail_with("Expected no report")
        }),
      ]),
    ]),
  ])
}

fn transaction_status_tests() -> ContextNode(Connection) {
  group("the transaction status", [
    before_each(run_setup_script("BEGIN")),
    it("knows the transaction status after BEGIN", fn(connection) {
      // Act
      let status = transaction_status(connection)

      // Assert
      status
      |> should
      |> be_ok
      |> be_equal(InTransaction)
      |> or_fail_with("Expected InTransaction after BEGIN")
    }),
    group("after a failed statement", [
      before_each(run_failing_script("SELECT 1/0")),
      it(
        "knows the transaction status after a failed statement",
        fn(connection) {
          // Act
          let status = transaction_status(connection)

          // Assert
          status
          |> should
          |> be_ok
          |> be_equal(InFailedTransaction)
          |> or_fail_with("Expected InFailedTransaction after the error")
        },
      ),
      group("after ROLLBACK", [
        before_each(run_setup_script("ROLLBACK")),
        it("knows the transaction status after ROLLBACK", fn(connection) {
          // Act
          let status = transaction_status(connection)

          // Assert
          status
          |> should
          |> be_ok
          |> be_equal(Idle)
          |> or_fail_with("Expected Idle after ROLLBACK")
        }),
      ]),
    ]),
  ])
}

fn first_server_tests() -> List(ContextNode(Connection)) {
  [
    before_each(start_test_connection(first_driver_server)),
    it("gives ConnectionProcessDown after it stopped", fn(connection) {
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
    it("refuses SQL with a zero byte before it sends anything", fn(connection) {
      // Act
      let answer = run(connection, "SELECT 1\u{0000}", [], [], 5000)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest")
    }),
    it("refuses a prepare with a zero byte", fn(connection) {
      // Act
      let answer = prepare(connection, "SELECT 1\u{0000}", 5000)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the prepare")
    }),
    it("refuses a script with a zero byte", fn(connection) {
      // Act
      let answer = run_script(connection, "SELECT 1\u{0000}", 5000)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the script")
    }),
    it("refuses a COPY statement with the statement before it", fn(connection) {
      // Act
      let refused = run_script(connection, copy_script, 5000)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_refused_copy_outcomes
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the refusal with the statement before it")
    }),
    group("after a refused COPY statement", [
      before_each(run_failing_script(copy_script)),
      it("refuses a COPY statement and stays usable", fn(connection) {
        // Act
        let next = run_script(connection, "SELECT 5", 5000)

        // Assert
        next
        |> should
        |> be_ok
        |> extract_outcome_tags
        |> be_equal(["SELECT 1"])
        |> or_fail_with("Expected SELECT 1 after the refusal")
      }),
    ]),
    it("gives ScriptFailed with the statements that ran", fn(connection) {
      // Act
      let answer = run_script(connection, "SELECT 1; SELECT 1/0", 5000)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_script_failure_outcomes
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the completed statement")
    }),
    it(
      "gives ScriptFailed with the code of the failed statement",
      fn(connection) {
        // Act
        let answer = run_script(connection, "SELECT 1; SELECT 1/0", 5000)

        // Assert
        answer
        |> should
        |> be_error
        |> extract_driver_error_code
        |> be_equal("22012")
        |> or_fail_with("Expected 22012")
      },
    ),
    it("refuses a prepare that the server refuses", fn(connection) {
      // Act
      let answer = prepare(connection, "SELECT * FROM no_such_table", 5000)

      // Assert
      answer
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("42P01")
      |> or_fail_with("Expected 42P01")
    }),
    it("binds a NULL parameter", fn(connection) {
      // Act
      let outcome = run(connection, "SELECT $1::text IS NULL", [Null], [], 5000)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"t">>)]])
      |> or_fail_with("Expected true")
    }),
    it("keeps a parameter change during a script", fn(connection) {
      // Arrange
      let sql = "SET application_name = 'during a script'"

      // Act
      let name = {
        use _outcomes <- try(run_script(connection, sql, 5000))
        server_parameter(connection, "application_name")
      }

      // Assert
      name
      |> should
      |> be_ok
      |> be_some
      |> be_equal("during a script")
      |> or_fail_with("Expected the new application_name")
    }),
    group("with a temporary table", [
      before_each(run_setup_script("CREATE TEMP TABLE c (x int)")),
      it("refuses COPY FROM STDIN in a run", fn(connection) {
        // Act
        let refused = run(connection, "COPY c FROM STDIN", [], [], 5000)

        // Assert
        refused
        |> should
        |> be_error
        |> be_equal(CopyStatementRefused([]))
        |> or_fail_with("Expected the refusal with no statement before it")
      }),
      group("after the refused COPY", [
        before_each(run_failing_statement("COPY c FROM STDIN")),
        it("refuses COPY FROM STDIN in a run and stays usable", fn(connection) {
          // Act
          let next = run_script(connection, "SELECT 6", 5000)

          // Assert
          next
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected SELECT 1 after the refusal")
        }),
      ]),
    ]),
  ]
}

const copy_script = "SELECT 1; COPY (SELECT 1) TO STDOUT"

// Starting --------------------------------------------------------------------

/// The configs that the start tests start with, built once. The teardown
/// stops the proxy; a start that fails leaves no process, and each start
/// that works ends with the process that made it.
type StartInputs {
  StartInputs(
    wrong_password: ConnectionConfig,
    no_listener: ConnectionConfig,
    silent_server: ConnectionConfig,
    undecodable_login: ConnectionConfig,
    first_server: ConnectionConfig,
    through_proxy: ConnectionConfig,
    proxy: Proxy,
  )
}

fn build_start_inputs() -> Result(StartInputs, String) {
  use #(proxy_port, proxy) <- try(start_proxy(first_driver_server.port))
  {
    let first_port = first_driver_server.port
    use #(fake_port, _fake_server) <- try(
      start_fake_server(Answer(<<"x", 4:32>>)),
    )
    use wrong_password <- try(user_config(first_port, "dream", "wrong"))
    use no_listener <- try(connection_config(free_port()))
    use silent_port <- try(start_silent_server())
    use silent <- try(connection_config(silent_port))
    use undecodable_login <- try(connection_config(fake_port))
    use first_server <- try(connection_config(first_port))
    use through_proxy <- try(connection_config(proxy_port))
    let silent_server =
      ConnectionConfig(..silent, setup_timeout_milliseconds: 100)
    Ok(StartInputs(
      wrong_password:,
      no_listener:,
      silent_server:,
      undecodable_login:,
      first_server:,
      through_proxy:,
      proxy:,
    ))
  }
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn stop_start_inputs(inputs: StartInputs) -> Result(Nil, String) {
  Ok(stop_proxy(inputs.proxy))
}

fn start_tests() -> TestSuite {
  describe(
    "starting",
    context.setup(setup: build_start_inputs, teardown: stop_start_inputs),
    [
      it(
        "gives the server's 28P01 for a wrong password",
        fn(inputs: StartInputs) {
          // Act
          let started = start(inputs.wrong_password)

          // Assert
          started
          |> should
          |> be_error
          |> extract_login_refusal_code
          |> be_equal("28P01")
          |> or_fail_with("Expected the login refusal 28P01")
        },
      ),
      it(
        "gives TransportRefused for a port with no listener",
        fn(inputs: StartInputs) {
          // Act
          let started = start(inputs.no_listener)

          // Assert
          started
          |> should
          |> be_error
          |> be_equal(TransportRefused(ConnectRefused))
          |> or_fail_with("Expected TransportRefused(ConnectRefused)")
        },
      ),
      it(
        "gives SetupTimedOut for a server that never answers",
        fn(inputs: StartInputs) {
          // Act
          let started = start(inputs.silent_server)

          // Assert
          started
          |> should
          |> be_error
          |> be_equal(SetupTimedOut)
          |> or_fail_with("Expected SetupTimedOut")
        },
      ),
      it(
        "gives LoginUndecodable for bytes that are not a message",
        fn(inputs: StartInputs) {
          // Act
          let started = start(inputs.undecodable_login)

          // Assert
          started
          |> should
          |> be_error
          |> be_equal(LoginUndecodable(UnknownMessageType(120)))
          |> or_fail_with("Expected LoginUndecodable")
        },
      ),
      it(
        "sends Terminate when the process that started it ends",
        fn(inputs: StartInputs) {
          // Arrange
          let watch = watch_client_end(inputs.proxy)

          // Act
          let started =
            start_in_ended_owner(fn() { start(inputs.through_proxy) })

          // Assert
          started
          |> should
          |> be_ok
          |> be_ok
          |> extract_client_end(watch)
          |> be_equal(<<"X", 4:32>>)
          |> or_fail_with("Expected a Terminate when the owner ended")
        },
      ),
      it("starts under a supervisor", fn(inputs: StartInputs) {
        // Arrange
        let supervisor =
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.add(supervised(inputs.first_server))

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
      it(
        "keeps the supervisor up when it cannot connect",
        fn(inputs: StartInputs) {
          // Arrange
          let supervisor =
            static_supervisor.new(static_supervisor.OneForOne)
            |> static_supervisor.add(supervised(inputs.no_listener))

          // Act
          let started =
            start_in_ended_owner(fn() { static_supervisor.start(supervisor) })

          // Assert
          started
          |> should
          |> be_ok
          |> be_ok
          |> or_fail_with("Expected the supervisor to start, with no server")
        },
      ),
    ],
  )
}

// With a proxied connection of its own ----------------------------------------

fn proxied_tests() -> TestSuite {
  describe(
    "with a proxied connection of its own",
    proxied_setup(first_driver_server, 60_000),
    [
      after_each(stop_proxied),
      group("with the default statement cache", cached_proxied_tests()),
      group("with unnamed statements", unnamed_proxied_tests()),
    ],
  )
}

fn cached_proxied_tests() -> List(ContextNode(ProxiedConnection)) {
  [
    before_each(start_test_proxied(first_driver_server, 60_000)),
    it("sends Terminate when it stops", fn(proxied: ProxiedConnection) {
      // Arrange
      let watch = watch_client_end(proxied.proxy)

      // Act
      stop(proxied.connection)
      let last_bytes = client_end(watch)

      // Assert
      last_bytes
      |> should
      |> be_equal(<<"X", 4:32>>)
      |> or_fail_with("Expected a Terminate as the last bytes")
    }),
    it(
      "ignores a message that is not about its socket",
      fn(proxied: ProxiedConnection) {
        // Act
        send_stray_message(proxied.connection)
        let outcomes = run_script(proxied.connection, "SELECT 1", 5000)

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_outcome_tags
        |> be_equal(["SELECT 1"])
        |> or_fail_with("Expected the connection to work")
      },
    ),
    loss_event_test(
      "a close by the network",
      close_client,
      ConnectionLost(SocketFailed(SocketClosed)),
    ),
    loss_event_test(
      "a reset by the network",
      reset_client,
      ConnectionLost(SocketFailed(ConnectionReset)),
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
    lost_session_tests(),
    idle_message_tests(),
    lock_tests(),
    running_prepare_lost_tests(
      "fails a running named prepare when the network closes",
      "driver_prepare_lock_cached",
    ),
  ]
}

fn unnamed_proxied_tests() -> List(ContextNode(ProxiedConnection)) {
  [
    before_each(start_test_proxied_with_caching(
      first_driver_server,
      60_000,
      UnnamedStatements,
    )),
    group("while the control connection holds a lock", [
      before_each(hold_advisory_lock),
      running_run_lost_test(
        "fails a running unnamed run when the network closes",
      ),
    ]),
    running_prepare_lost_tests(
      "fails a running unnamed prepare when the network closes",
      "driver_prepare_lock_unnamed",
    ),
  ]
}

/// A run waits on the advisory lock of the control connection. The proxy
/// closes the connection, and the caller gets the loss.
fn running_run_lost_test(name: String) -> ContextNode(ProxiedConnection) {
  it(name, fn(proxied: ProxiedConnection) {
    // Act
    let answer = {
      let running =
        start_caller(fn() {
          run(
            proxied.connection,
            advisory_lock_sql(proxied.lock_key),
            [],
            [],
            5000,
          )
        })
      use _waited <- try(wait_for_lock_waiter(proxied.control, proxied.lock_key))
      close_client(proxied.proxy)
      caller_answer(running)
    }

    // Assert
    answer
    |> should
    |> be_ok
    |> be_error
    |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
    |> or_fail_with("Expected the loss for the running run")
  })
}

/// A prepare waits on `table`, that the control connection locks: its
/// Parse needs a lock on the table too. The proxy closes the connection,
/// and the caller gets the loss. Each caching uses its own table, so the
/// tests can run at the same time.
fn running_prepare_lost_tests(
  name: String,
  table: String,
) -> ContextNode(ProxiedConnection) {
  group("while the control connection locks " <> table, [
    before_each(run_control_setup_script(
      "CREATE TABLE IF NOT EXISTS " <> table <> " (x int)",
    )),
    before_each(run_control_setup_script(
      "BEGIN; LOCK TABLE " <> table <> " IN ACCESS EXCLUSIVE MODE",
    )),
    it(name, fn(proxied: ProxiedConnection) {
      // Act
      let answer = {
        let running =
          start_caller(fn() {
            prepare(proxied.connection, "SELECT x FROM " <> table, 5000)
          })
        use _waited <- try(wait_for_table_waiter(proxied.control, table))
        close_client(proxied.proxy)
        caller_answer(running)
      }

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
      |> or_fail_with("Expected the loss for the running prepare")
    }),
  ])
}

fn loss_event_test(
  name: String,
  breaking: fn(Proxy) -> Nil,
  expected: DriverError,
) -> ContextNode(ProxiedConnection) {
  it("tells of " <> name, fn(proxied: ProxiedConnection) {
    // Act
    breaking(proxied.proxy)
    let event = next_event(proxied.events)

    // Assert
    event
    |> should
    |> be_ok
    |> extract_disconnect_error
    |> be_equal(expected)
    |> or_fail_with("Expected the event of " <> name)
  })
}

fn lost_session_tests() -> ContextNode(ProxiedConnection) {
  group("a lost session", [
    group("after the server ended the session", [
      before_each(terminate_session),
      it(
        "fails a request while the connection is lost",
        fn(proxied: ProxiedConnection) {
          // Act
          send_stray_message(proxied.connection)
          let answer = run_script(proxied.connection, "SELECT 1", 5000)

          // Assert
          answer
          |> should
          |> be_error
          |> extract_driver_error_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the error of the loss")
        },
      ),
    ]),
    group("after the network closed", [
      before_each(break_session(close_client)),
      it(
        "fails a prepare while the connection is lost",
        fn(proxied: ProxiedConnection) {
          // Act
          let answer = prepare(proxied.connection, "SELECT 1", 5000)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
          |> or_fail_with("Expected the error of the loss")
        },
      ),
      it(
        "refuses the settled status while the connection is lost",
        fn(proxied: ProxiedConnection) {
          // Act
          let settled = settled_transaction_status(proxied.connection, 5000)

          // Assert
          settled
          |> should
          |> be_error
          |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
          |> or_fail_with("Expected the error of the loss")
        },
      ),
    ]),
    // The proxy reads the first bytes of a large script, answers them with
    // a CopyInResponse as if the server did, and reads nothing more. The
    // step answers with a CopyFail, whose send waits behind the rest of the
    // script in the socket's queue and fails after the send timeout of 500
    // milliseconds.
    it(
      "fails a send that the server never reads",
      fn(proxied: ProxiedConnection) {
        // Arrange
        let large = "SELECT '" <> repeat("x", 64_000_000) <> "'"

        // Act
        answer_next_request(proxied.proxy, <<"G", 7:32, 0, 0:16>>)
        let answer = run_script(proxied.connection, large, 5000)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(ConnectionLost(SocketFailed(SendTimedOut)))
        |> or_fail_with("Expected the loss by a send timeout")
      },
    ),
  ])
}

/// The proxy sends a NoticeResponse, a NotificationResponse and a
/// ParameterStatus as if the server sent them between requests. The next
/// outcome carries the notice and the notification, and the parameter has
/// its new value.
fn idle_message_tests() -> ContextNode(ProxiedConnection) {
  let idle_messages =
    bit_array.concat([
      frame("N", <<
        "S", "NOTICE":utf8, 0, "V", "NOTICE":utf8, 0, "C", "00000":utf8, 0, "M",
        "an idle notice":utf8, 0, 0,
      >>),
      frame("A", <<4321:32, "idle_jobs":utf8, 0, "idle":utf8, 0>>),
      frame("S", <<"application_name":utf8, 0, "injected":utf8, 0>>),
    ])
  group("after messages between requests", [
    before_each(inject_and_wait_for_parameter(
      idle_messages,
      "application_name",
      "injected",
    )),
    it(
      "keeps the parameter changes, notices and notifications between requests",
      fn(proxied: ProxiedConnection) {
        // Act
        let outcomes = run_script(proxied.connection, "SELECT 1", 5000)

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_outcome_notices
        |> be_equal([["an idle notice"]])
        |> or_fail_with("Expected the notice of the idle time")
      },
    ),
    it(
      "keeps the notifications between requests",
      fn(proxied: ProxiedConnection) {
        // Act
        let outcomes = run_script(proxied.connection, "SELECT 1", 5000)

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_outcome_notifications
        |> be_equal([[#("idle_jobs", "idle")]])
        |> or_fail_with("Expected the notification of the idle time")
      },
    ),
  ])
}

fn frame(type_byte: String, body: BitArray) -> BitArray {
  <<type_byte:utf8, { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

/// Each test waits on the advisory lock of its own proxied connection, which
/// the control connection holds.
fn lock_tests() -> ContextNode(ProxiedConnection) {
  group("while the control connection holds a lock", [
    before_each(hold_advisory_lock),
    it(
      "gives a violation to the running request",
      fn(proxied: ProxiedConnection) {
        // Act
        let answer = {
          let running = start_caller(lock_request(proxied))
          use _waited <- try(wait_for_lock_waiter(
            proxied.control,
            proxied.lock_key,
          ))
          inject(proxied.proxy, <<"2", 4:32>>)
          caller_answer(running)
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_error
        |> extract_unexpected_server_message
        |> be_equal(BindComplete)
        |> or_fail_with("Expected a protocol violation for the running request")
      },
    ),
    it(
      "stays usable after a caller is killed mid-query",
      fn(proxied: ProxiedConnection) {
        // Act
        let outcome = {
          let caller = start_caller(lock_request(proxied))
          use _waited <- try(wait_for_lock_waiter(
            proxied.control,
            proxied.lock_key,
          ))
          process.kill(caller.pid)
          use _released <- try(release_advisory_lock(proxied))
          Ok(run(proxied.connection, "SELECT 2", [], [], 5000))
        }

        // Assert
        outcome
        |> should
        |> be_ok
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"2">>)]])
        |> or_fail_with("Expected the next query's own result")
      },
    ),
    it(
      "fails the running request when the network closes",
      fn(proxied: ProxiedConnection) {
        // Act
        let answer = {
          let running = start_caller(lock_request(proxied))
          use _waited <- try(wait_for_lock_waiter(
            proxied.control,
            proxied.lock_key,
          ))
          close_client(proxied.proxy)
          caller_answer(running)
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_error
        |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
        |> or_fail_with("Expected the loss for the running request")
      },
    ),
    running_run_lost_test("fails a running cached run when the network closes"),
  ])
}

// Losing the connection: one act for three tests --------------------------------

type LossAndReconnect {
  LossAndReconnect(
    lost: Result(ConnectionEvent, Nil),
    back: Result(ConnectionEvent, Nil),
    outcomes: Result(List(Outcome), DriverError),
  )
}

/// The server ends the idle session; the process tells of the loss,
/// reconnects after 10 milliseconds, and runs a statement again.
fn lose_and_reconnect(
  proxied: ProxiedConnection,
) -> Result(LossAndReconnect, String) {
  use pid <- try(backend_pid(proxied.connection))
  use _terminated <- try(terminate_backend(proxied.control, pid))
  let lost = next_event(proxied.events)
  let back = next_event(proxied.events)
  let outcomes = run_script(proxied.connection, "SELECT 1", 5000)
  Ok(LossAndReconnect(lost:, back:, outcomes:))
}

fn loss_tests() -> TestSuite {
  describe(
    "losing the connection",
    proxied_act_setup(first_driver_server, 10, lose_and_reconnect),
    [
      it(
        "notices at once when the server ends an idle session",
        fn(shared: ProxiedOutcome(LossAndReconnect)) {
          shared.outcome.lost
          |> should
          |> be_ok
          |> extract_disconnect_error
          |> extract_ending_report
          |> extract_report_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the loss by 57P01")
        },
      ),
      it(
        "reconnects after the server ended an idle session",
        fn(shared: ProxiedOutcome(LossAndReconnect)) {
          shared.outcome.back
          |> should
          |> be_ok
          |> be_equal(Reconnected)
          |> or_fail_with("Expected the reconnect after the loss")
        },
      ),
      it(
        "runs a statement again after it reconnected",
        fn(shared: ProxiedOutcome(LossAndReconnect)) {
          shared.outcome.outcomes
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected SELECT 1 on the new session")
        },
      ),
    ],
  )
}

// A refused reconnect: one act for three tests ----------------------------------

/// The password of dream_reconnect changes while it is logged in, so the
/// reconnect fails with 28P01. The password goes back, and the next attempt
/// works. The act runs once, so no other test changes the password at the
/// same time.
type RefusedReconnect {
  RefusedReconnect(
    connection: Connection,
    control: Connection,
    lost: Result(ConnectionEvent, Nil),
    refused: Result(ConnectionEvent, Nil),
    back: Result(ConnectionEvent, Nil),
  )
}

fn start_refused_reconnect() -> Result(RefusedReconnect, String) {
  let events = process.new_subject()
  let port = first_driver_server.port
  use config <- try(user_config(port, "dream_reconnect", "dream"))
  use connection <- try(start_watched(
    watched_config(config, events, 10),
    events,
  ))
  use control <- try(
    start_connection(port) |> map_error(stop_after_error(connection, _)),
  )
  {
    use pid <- try(backend_pid(connection))
    use _changed <- try(run_control_script(control, change_password))
    use _terminated <- try(terminate_backend(control, pid))
    let lost = next_event(events)
    let refused = next_event(events)
    use _restored <- try(run_control_script(control, restore_password))
    let back = next_event_after_refused_reconnects(events)
    Ok(RefusedReconnect(connection:, control:, lost:, refused:, back:))
  }
  |> map_error(fn(error) {
    let restored = run_control_script(control, restore_password)
    stop(connection)
    stop(control)
    error <> "; restoring the password gave " <> inspect(restored)
  })
}

fn stop_refused_reconnect(scenario: RefusedReconnect) -> Result(Nil, String) {
  stop(scenario.connection)
  stop_connection(scenario.control)
}

const change_password = "ALTER ROLE dream_reconnect PASSWORD 'other'"

const restore_password = "ALTER ROLE dream_reconnect PASSWORD 'dream'"

fn refused_reconnect_tests() -> TestSuite {
  describe(
    "a refused reconnect",
    context.setup(
      setup: start_refused_reconnect,
      teardown: stop_refused_reconnect,
    ),
    [
      it(
        "tells of the loss before a refused reconnect",
        fn(scenario: RefusedReconnect) {
          scenario.lost
          |> should
          |> be_ok
          |> extract_disconnect_error
          |> extract_ending_report
          |> extract_report_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the loss by 57P01")
        },
      ),
      it(
        "tells of a failed reconnect, and tries again",
        fn(scenario: RefusedReconnect) {
          scenario.refused
          |> should
          |> be_ok
          |> extract_reconnect_error
          |> extract_login_refusal_code
          |> be_equal("28P01")
          |> or_fail_with("Expected a reconnect refused with 28P01")
        },
      ),
      it(
        "reconnects once the password works again",
        fn(scenario: RefusedReconnect) {
          scenario.back
          |> should
          |> be_ok
          |> be_equal(Reconnected)
          |> or_fail_with("Expected the reconnect after the refusals")
        },
      ),
    ],
  )
}

// A loss with a running and a waiting request: one act for two tests ------------

type RequestsAtLoss {
  RequestsAtLoss(
    running: Result(Result(List(Outcome), DriverError), String),
    waiting: Result(Result(List(Outcome), DriverError), String),
  )
}

/// One request waits on the lock, a second one waits behind it, and the
/// server ends the session.
fn lose_with_requests(
  proxied: ProxiedConnection,
) -> Result(RequestsAtLoss, String) {
  use _locked <- try(hold_advisory_lock(proxied))
  let running = start_caller(lock_request(proxied))
  use _waited <- try(wait_for_lock_waiter(proxied.control, proxied.lock_key))
  let waiting =
    start_caller(fn() { run_script(proxied.connection, "SELECT 1", 5000) })
  use pid <- try(lock_waiter_pid(proxied.control, proxied.lock_key))
  use _terminated <- try(terminate_backend(proxied.control, pid))
  Ok(RequestsAtLoss(
    running: caller_answer(running),
    waiting: caller_answer(waiting),
  ))
}

fn requests_at_loss_tests() -> TestSuite {
  describe(
    "a loss with requests",
    proxied_act_setup(first_driver_server, 60_000, lose_with_requests),
    [
      it(
        "fails a running request with the loss",
        fn(shared: ProxiedOutcome(RequestsAtLoss)) {
          shared.outcome.running
          |> should
          |> be_ok
          |> be_error
          |> extract_driver_error_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the loss for the running request")
        },
      ),
      it(
        "fails a running request with the loss and the waiting ones too",
        fn(shared: ProxiedOutcome(RequestsAtLoss)) {
          shared.outcome.waiting
          |> should
          |> be_ok
          |> be_error
          |> extract_driver_error_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the loss for the waiting request")
        },
      ),
    ],
  )
}

// Two requests: one act for two tests -------------------------------------------

type TwoRequests {
  TwoRequests(
    first: Result(Result(List(Outcome), DriverError), String),
    second: Result(Result(List(Outcome), DriverError), String),
  )
}

/// The first request waits on the lock, the second one waits behind it,
/// and the lock goes back.
fn run_two_requests(proxied: ProxiedConnection) -> Result(TwoRequests, String) {
  use _locked <- try(hold_advisory_lock(proxied))
  let first = start_caller(lock_request(proxied))
  use _waited <- try(wait_for_lock_waiter(proxied.control, proxied.lock_key))
  let second =
    start_caller(fn() { run_script(proxied.connection, "SELECT 4", 5000) })
  use _released <- try(release_advisory_lock(proxied))
  Ok(TwoRequests(first: caller_answer(first), second: caller_answer(second)))
}

fn two_requests_tests() -> TestSuite {
  describe(
    "two requests",
    proxied_act_setup(first_driver_server, 60_000, run_two_requests),
    [
      it(
        "runs the first of two requests",
        fn(shared: ProxiedOutcome(TwoRequests)) {
          shared.outcome.first
          |> should
          |> be_ok
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected the first request to run")
        },
      ),
      it(
        "runs a request that waited behind another",
        fn(shared: ProxiedOutcome(TwoRequests)) {
          shared.outcome.second
          |> should
          |> be_ok
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected the waiting request to run after the first")
        },
      ),
    ],
  )
}

// Deadlines on each driver server: one act for each describe ----------------

fn deadline_tests(server: Server) -> TestSuite {
  suite.group("PostgreSQL " <> to_string(server.version), [
    gated_deadline_tests(server),
    cancel_at_deadline_tests(server),
  ])
}

/// Request A passes its deadline, and the gate holds its cancel. A's
/// statement ends by itself, so A gets DeadlinePassed(False). Request B
/// then waits: it must not reach the server before A's cancel did, or that
/// cancel could stop B.
type GatedDeadline {
  GatedDeadline(
    connection: Connection,
    gate: CancelGate,
    first: Result(Outcome, DriverError),
    second: Result(Result(List(Outcome), DriverError), String),
    events: List(GateEvent),
  )
}

/// The connection goes through the gate, with a first reconnect delay of
/// 60 seconds and a cancel timeout of 5 seconds.
fn start_gated_deadline(server: Server) -> Result(GatedDeadline, String) {
  use #(port, gate) <- try(start_cancel_gate(server.port))
  {
    use config <- try(connection_config(port))
    let gated = ConnectionConfig(..config, reconnect: Backoff(60_000, 60_000))
    use connection <- try(start_configured(cancel_timeout_config(gated, 5000)))
    {
      let first = run(connection, "SELECT pg_sleep(0.3)", [], [], 50)
      record_gate(gate)
      use second <- try(
        start_announced_caller(fn() { run_script(connection, "SELECT 1", 5000) }),
      )
      use _asked <- try(ask_transaction_status(connection, 20))
      release_gate(gate)
      let second_answer = caller_answer(second)
      let events = gate_events(gate)
      Ok(GatedDeadline(
        connection:,
        gate:,
        first:,
        second: second_answer,
        events:,
      ))
    }
    |> map_error(stop_after_error(connection, _))
  }
  |> map_error(fn(error) {
    stop_cancel_gate(gate)
    error
  })
}

fn stop_gated_deadline(shared: GatedDeadline) -> Result(Nil, String) {
  stop(shared.connection)
  Ok(stop_cancel_gate(shared.gate))
}

fn gated_deadline_tests(server: Server) -> TestSuite {
  describe(
    "a cancel that the gate holds",
    context.setup(
      setup: fn() { start_gated_deadline(server) },
      teardown: stop_gated_deadline,
    ),
    [
      it(
        "holds the next request until the cancel of the last one is done",
        fn(shared: GatedDeadline) {
          shared.events
          |> should
          |> be_equal([CancelPassed, MainBytes])
          |> or_fail_with("Expected the next request to wait for the cancel")
        },
      ),
      it(
        "gives DeadlinePassed to a request whose cancel the gate holds",
        fn(shared: GatedDeadline) {
          shared.first
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with("Expected DeadlinePassed for the first request")
        },
      ),
      it(
        "runs the request that waited for the cancel",
        fn(shared: GatedDeadline) {
          shared.second
          |> should
          |> be_ok
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected the next request to run")
        },
      ),
    ],
  )
}

/// A statement passes its deadline of 300 milliseconds, and the connection
/// cancels it. A control connection reads the state of the backend, and
/// the connection runs a statement again.
type CancelAtDeadline {
  CancelAtDeadline(
    connection: Connection,
    control: Connection,
    late: Result(Outcome, DriverError),
    state: Result(List(Outcome), DriverError),
    next: Result(Outcome, DriverError),
  )
}

/// The connection uses protocol 3.2, so its cancel key is longer than 4
/// bytes, and a cancel timeout of 200 milliseconds.
fn start_cancel_at_deadline(
  server: Server,
) -> Result(CancelAtDeadline, String) {
  use config <- try(protocol_config(server.port, Protocol32))
  use connection <- try(start_configured(cancel_timeout_config(config, 200)))
  use control <- try(
    start_connection(server.port) |> map_error(stop_after_error(connection, _)),
  )
  {
    use pid <- try(backend_pid(connection))
    let late = run(connection, "SELECT pg_sleep(30)", [], [], 300)
    let state =
      run_script(
        control,
        "SELECT state FROM pg_stat_activity WHERE pid = " <> pid,
        5000,
      )
    // The next statement runs longer than the cancel timeout, so the
    // cancel's timer ends while the connection serves another request.
    let next = run(connection, "SELECT pg_sleep(0.3)::text", [], [], 5000)
    Ok(CancelAtDeadline(connection:, control:, late:, state:, next:))
  }
  |> map_error(fn(error) {
    stop(control)
    stop_after_error(connection, error)
  })
}

fn stop_cancel_at_deadline(shared: CancelAtDeadline) -> Result(Nil, String) {
  stop(shared.connection)
  stop_connection(shared.control)
}

fn cancel_at_deadline_tests(server: Server) -> TestSuite {
  describe(
    "a cancel at the deadline",
    context.setup(
      setup: fn() { start_cancel_at_deadline(server) },
      teardown: stop_cancel_at_deadline,
    ),
    [
      it(
        "cancels a statement at its deadline and stays usable",
        fn(shared: CancelAtDeadline) {
          shared.next
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_tag
          |> be_equal("SELECT 1")
          |> or_fail_with("Expected a new run after the cancel")
        },
      ),
      it(
        "gives a cancelled DeadlinePassed at the deadline",
        fn(shared: CancelAtDeadline) {
          shared.late
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: True))
          |> or_fail_with("Expected the cancel at the deadline")
        },
      ),
      it(
        "leaves the backend idle after the cancel",
        fn(shared: CancelAtDeadline) {
          shared.state
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"idle">>)]])
          |> or_fail_with("Expected an idle backend after the cancel")
        },
      ),
    ],
  )
}

// A lost cancel: one act for two tests ------------------------------------------

/// A statement passes its deadline through a proxy, and its cancel goes to
/// the proxy too, which serves one session at a time, so it never reaches
/// the server. After the cancel timeout, the connection is closed with the
/// loss ClosedAfterDeadline and the caller gets DeadlinePassed. `breaking`
/// runs on the proxy before the statement. The connection sends its events
/// to a subject of the act, with a first reconnect delay of 60 seconds and a
/// cancel timeout of 200 milliseconds.
type LostCancel {
  LostCancel(
    connection: Connection,
    proxy: Proxy,
    answer: Result(Outcome, DriverError),
    event: Result(ConnectionEvent, Nil),
  )
}

fn start_lost_cancel(breaking: fn(Proxy) -> Nil) -> Result(LostCancel, String) {
  use #(port, proxy) <- try(start_proxy(first_driver_server.port))
  let events = process.new_subject()
  {
    use config <- try(connection_config(port))
    let watched = watched_config(config, events, 60_000)
    use connection <- try(start_watched(
      cancel_timeout_config(watched, 200),
      events,
    ))
    breaking(proxy)
    let answer = run(connection, "SELECT pg_sleep(30)", [], [], 100)
    let event = next_event(events)
    Ok(LostCancel(connection:, proxy:, answer:, event:))
  }
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn stop_lost_cancel(shared: LostCancel) -> Result(Nil, String) {
  stop(shared.connection)
  Ok(stop_proxy(shared.proxy))
}

fn lost_cancel_tests(
  cause: String,
  breaking: fn(Proxy) -> Nil,
  answer_message: String,
) -> TestSuite {
  describe(
    "a cancel that " <> cause,
    context.setup(
      setup: fn() { start_lost_cancel(breaking) },
      teardown: stop_lost_cancel,
    ),
    [
      it(
        "closes the connection when the cancel " <> cause,
        fn(shared: LostCancel) {
          shared.event
          |> should
          |> be_ok
          |> extract_disconnect_error
          |> be_equal(ConnectionLost(ClosedAfterDeadline))
          |> or_fail_with("Expected the loss of the connection at the deadline")
        },
      ),
      it(
        "gives DeadlinePassed when the cancel " <> cause,
        fn(shared: LostCancel) {
          shared.answer
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with(answer_message)
        },
      ),
    ],
  )
}

// A session with no cancel key ------------------------------------------------

/// A fake server whose login gives no BackendKeyData, so a statement at its
/// deadline has no cancel to send, and the connection closes with the loss
/// ClosedAfterDeadline. Its first reconnect comes after 60 seconds, so
/// later requests see the loss. The fake server ends by itself once the
/// connection closed.
fn start_keyless_connection() -> Result(Connection, String) {
  let login_answer = <<"R", 8:32, 0:32, "Z", 5:32, "I">>
  use #(port, _fake_server) <- try(start_fake_server(Answer(login_answer)))
  use config <- try(connection_config(port))
  start_configured(
    ConnectionConfig(
      ..config,
      reconnect: Backoff(60_000, 60_000),
      cancel_timeout_milliseconds: 200,
    ),
  )
}

/// A `before_each` hook that starts a keyless connection, with its own
/// fake server, for the test.
fn start_test_keyless(
  _tree_connection: Connection,
) -> Result(Connection, String) {
  start_keyless_connection()
}

fn keyless_session_tests() -> TestSuite {
  describe(
    "a session with no cancel key",
    context.setup(setup: start_keyless_connection, teardown: stop_connection),
    [
      before_each(start_test_keyless),
      after_each(stop_connection),
      it(
        "closes the connection when the session has no cancel key",
        fn(connection) {
          // Act
          let answer = run(connection, "SELECT 1", [], [], 100)

          // Assert
          answer
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with("Expected DeadlinePassed with no cancel")
        },
      ),
      // The process is suspended while a request with a deadline of 100
      // milliseconds and a second request come, so both wait in its
      // mailbox in that order. The first passes its deadline, the
      // connection closes, and the second gets the loss. Both callers
      // answer before the test ends.
      it(
        "gives a waiting request ClosedAfterDeadline after a deadline loss",
        fn(connection) {
          // Act
          let answer = {
            let pid = pid_of(connection)
            suspend_connection(connection)
            let first =
              start_caller(fn() { run(connection, "SELECT 1", [], [], 100) })
            use _first_came <- try(wait_for_message(pid, ["request"], 1_000_000))
            let waiting =
              start_caller(fn() { run_script(connection, "SELECT 2", 5000) })
            use _both_came <- try(wait_for_mailbox_length(pid, 2, 1_000_000))
            resume_connection(connection)
            use _first_answer <- try(caller_answer(first))
            caller_answer(waiting)
          }

          // Assert
          answer
          |> should
          |> be_ok
          |> be_error
          |> be_equal(ConnectionLost(ClosedAfterDeadline))
          |> or_fail_with(
            "Expected the request behind the deadline to get ClosedAfterDeadline",
          )
        },
      ),
      group("after a deadline loss", [
        before_each(run_failing_statement_within("SELECT 1", 100)),
        it(
          "gives a later request ClosedAfterDeadline after a deadline loss",
          fn(connection) {
            // Act
            let answer = run(connection, "SELECT 1", [], [], 5000)

            // Assert
            answer
            |> should
            |> be_error
            |> be_equal(ConnectionLost(ClosedAfterDeadline))
            |> or_fail_with(
              "Expected ClosedAfterDeadline while the process reconnects",
            )
          },
        ),
      ]),
    ],
  )
}

// A waiting request at its deadline: one act for two tests --------------------

type WaitingAtDeadline {
  WaitingAtDeadline(
    waiting: Result(List(Outcome), DriverError),
    first: Result(Result(List(Outcome), DriverError), String),
  )
}

/// The first request waits on the lock, a second one waits behind it past
/// its deadline of 100 milliseconds, and the lock goes back.
fn end_waiting_request(
  proxied: ProxiedConnection,
) -> Result(WaitingAtDeadline, String) {
  use _locked <- try(hold_advisory_lock(proxied))
  let first = start_caller(lock_request(proxied))
  use _waited <- try(wait_for_lock_waiter(proxied.control, proxied.lock_key))
  let waiting = run_script(proxied.connection, "SELECT 1", 100)
  use _released <- try(release_advisory_lock(proxied))
  Ok(WaitingAtDeadline(waiting:, first: caller_answer(first)))
}

fn waiting_at_deadline_tests() -> TestSuite {
  describe(
    "a waiting request at its deadline",
    proxied_act_setup(first_driver_server, 60_000, end_waiting_request),
    [
      it(
        "ends a waiting request at its deadline",
        fn(shared: ProxiedOutcome(WaitingAtDeadline)) {
          shared.outcome.waiting
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with("Expected the waiting request to end")
        },
      ),
      it(
        "runs the first request after a waiting one ended",
        fn(shared: ProxiedOutcome(WaitingAtDeadline)) {
          shared.outcome.first
          |> should
          |> be_ok
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected the first request to run")
        },
      ),
    ],
  )
}

// The transaction status while a request waits: one act for two tests --------

type WaitingStatus {
  WaitingStatus(
    quick: Result(TransactionStatus, DriverError),
    settled: Result(TransactionStatus, DriverError),
  )
}

/// A request opens a transaction and waits on the lock. The status comes
/// at once while it waits; the lock goes back, and the settled status
/// waits for the request.
fn ask_status_while_waiting(
  proxied: ProxiedConnection,
) -> Result(WaitingStatus, String) {
  use _locked <- try(hold_advisory_lock(proxied))
  let begun =
    start_caller(fn() {
      run_script(
        proxied.connection,
        "BEGIN; " <> advisory_lock_sql(proxied.lock_key),
        5000,
      )
    })
  use _waited <- try(wait_for_lock_waiter(proxied.control, proxied.lock_key))
  let quick = transaction_status(proxied.connection)
  use _released <- try(release_advisory_lock(proxied))
  let settled = settled_transaction_status(proxied.connection, 5000)
  use _outcomes <- try(caller_outcomes(begun))
  use _rolled_back <- try(run_control_script(proxied.connection, "ROLLBACK"))
  Ok(WaitingStatus(quick:, settled:))
}

fn waiting_status_tests() -> TestSuite {
  describe(
    "the transaction status while a request waits",
    proxied_act_setup(first_driver_server, 60_000, ask_status_while_waiting),
    [
      it(
        "gives the settled transaction status after a request that waited",
        fn(shared: ProxiedOutcome(WaitingStatus)) {
          shared.outcome.settled
          |> should
          |> be_ok
          |> be_equal(InTransaction)
          |> or_fail_with("Expected InTransaction once settled")
        },
      ),
      it(
        "gives the transaction status at once while a request waits",
        fn(shared: ProxiedOutcome(WaitingStatus)) {
          shared.outcome.quick
          |> should
          |> be_ok
          |> be_equal(Idle)
          |> or_fail_with("Expected Idle at once")
        },
      ),
    ],
  )
}

// What dream_model needs -------------------------------------------------------

// The startup parameter `options` sets run-time parameters, as dream_model
// does to get the rewritten query tree in a notice.
fn model_tests(server: Server) -> ContextNode(Connection) {
  group("PostgreSQL " <> to_string(server.version), [
    group("with the rewritten query tree in a notice", [
      before_each(
        start_test_configured(parameter_config(
          server.port,
          "options",
          tree_options,
        )),
      ),
      it(
        "reads the rewritten query tree from a notice, with options",
        fn(connection) {
          // Act
          let outcome = run(connection, pg_class_query, [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_notice_details
          |> extract_first
          |> be_some
          |> contain_string("{QUERY")
          |> or_fail_with("Expected the query tree in the notice's detail")
        },
      ),
      it("gives the notice of the rewritten query tree", fn(connection) {
        // Act
        let outcome = run(connection, pg_class_query, [], [], 5000)

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_notice_messages
        |> be_equal(["rewritten parse tree:"])
        |> or_fail_with("Expected the tree notice")
      }),
      it(
        "gives the column origin with the rewritten query tree",
        fn(connection) {
          // Act
          let outcome = run(connection, pg_class_query, [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_result_columns
          |> extract_column_origins
          |> be_equal([#("relname", 1259, 2)])
          |> or_fail_with("Expected the column origin")
        },
      ),
      it("gives the row with the rewritten query tree", fn(connection) {
        // Act
        let outcome = run(connection, pg_class_query, [], [], 5000)

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"pg_class">>)]])
        |> or_fail_with("Expected the row")
      }),
    ]),
    group("with a function that gives a notice for each row", [
      before_each(start_test_connection(server)),
      before_each(run_setup_script(noisy_function)),
      it(
        "gives each notice in the middle of a result, and every row",
        fn(connection) {
          // Act
          let outcome = run(connection, noisy_query, [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_notice_messages
          |> be_equal(["row 1", "row 2", "row 3"])
          |> or_fail_with("Expected three notices")
        },
      ),
      it(
        "gives every row of a result with notices in the middle",
        fn(connection) {
          // Act
          let outcome = run(connection, noisy_query, [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"1">>)], [Text(<<"2">>)], [Text(<<"3">>)]])
          |> or_fail_with("Expected three rows")
        },
      ),
    ]),
  ])
}

/// The run-time parameters, for the startup parameter `options`, that print
/// the rewritten query tree in a notice.
const tree_options = "-c debug_print_rewritten=on -c client_min_messages=log"

const pg_class_query = "SELECT relname FROM pg_class WHERE relname = 'pg_class'"

const noisy_function =
  "CREATE FUNCTION pg_temp.noisy(n int) RETURNS int LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'row %', n; RETURN n; END $$"

const noisy_query = "SELECT pg_temp.noisy(g) FROM generate_series(1, 3) AS g"

// The statement cache ---------------------------------------------------------

/// The prepared statements of the session, from pg_prepared_statements, as
/// "name executions" in name order. A script runs with the simple protocol,
/// so it adds no statement of its own.
const prepared_statements =
  "SELECT name || ' ' || (generic_plans + custom_plans)::text FROM pg_prepared_statements ORDER BY name"

fn cache_tests(server: Server) -> ContextNode(Connection) {
  group("PostgreSQL " <> to_string(server.version), [
    group("with a cache of 512 statements", [
      before_each(start_test_caching(server, CacheStatements(512))),
      group("for one statement", one_statement_cache_tests()),
      group("after a change of the table", changed_table_tests()),
      group("after a prepared SELECT 1", [
        before_each(run_setup_statement("SELECT 1")),
        it(
          "refuses a run with 65536 parameters before it sends them",
          fn(connection) {
            // Act
            let refused =
              run(connection, "SELECT 1", list.repeat(Null, 65_536), [], 5000)

            // Assert
            refused
            |> should
            |> be_error
            |> be_equal(InvalidRequest(TooManyItems("parameters", 65_536)))
            |> or_fail_with("Expected TooManyItems for the Bind")
          },
        ),
      ]),
    ]),
    group("with a full cache of 2 statements", [
      before_each(start_test_caching(server, CacheStatements(2))),
      before_each(run_setup_statement("SELECT 'a'")),
      before_each(run_setup_statement("SELECT 'b'")),
      before_each(run_setup_statement("SELECT 'a'")),
      it(
        "closes the least recently used statement when the cache is full",
        fn(connection) {
          // Act
          let statements = {
            use _c <- try(run(connection, "SELECT 'c'", [], [], 5000))
            run_script(connection, prepared_statements, 5000)
          }

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
        },
      ),
    ]),
    group("with UnnamedStatements", unnamed_statement_tests(server)),
  ])
}

fn one_statement_cache_tests() -> List(ContextNode(Connection)) {
  [
    it(
      "prepares a statement one time and runs it again by its name",
      fn(connection) {
        // Act
        let statements = {
          use _first <- try(run(connection, "SELECT 41 + 1", [], [], 5000))
          use _second <- try(run(connection, "SELECT 41 + 1", [], [], 5000))
          run_script(connection, prepared_statements, 5000)
        }

        // Assert
        statements
        |> should
        |> be_ok
        |> extract_first
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"dream_postgres_1 2">>)]])
        |> or_fail_with("Expected one named statement that ran two times")
      },
    ),
    it("prepares a statement one time for two prepares", fn(connection) {
      // Act
      let statements = {
        use _first <- try(prepare(connection, "SELECT 1", 5000))
        use _second <- try(prepare(connection, "SELECT 1", 5000))
        run_script(connection, prepared_statements, 5000)
      }

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
    it("gives the same description for two prepares", fn(connection) {
      // Act
      let first = prepare(connection, "SELECT 1", 5000)
      let second = prepare(connection, "SELECT 1", 5000)

      // Assert
      second
      |> should
      |> be_equal(first)
      |> or_fail_with("Expected the same description")
    }),
    group("after the server forgot the statement", [
      before_each(run_setup_statement("SELECT 41 + 1")),
      before_each(run_setup_script("DEALLOCATE ALL")),
      it(
        "prepares again and runs when the statement is gone (26000)",
        fn(connection) {
          // Act
          let outcome = run(connection, "SELECT 41 + 1", [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"42">>)]])
          |> or_fail_with("Expected the run to work after a new prepare")
        },
      ),
    ]),
  ]
}

fn changed_table_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script("CREATE TEMP TABLE changing (a int)")),
    before_each(run_setup_statement("SELECT * FROM changing")),
    group("outside a transaction", [
      before_each(run_setup_script("ALTER TABLE changing ADD COLUMN b int")),
      it(
        "gives StatementChanged when the result type changed (0A000)",
        fn(connection) {
          // Act
          let outcome = run(connection, "SELECT * FROM changing", [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_error
          |> extract_changed_column_names
          |> be_equal(["a", "b"])
          |> or_fail_with("Expected StatementChanged with both columns")
        },
      ),
      group("after the StatementChanged", [
        before_each(run_failing_statement("SELECT * FROM changing")),
        it("runs the changed statement after StatementChanged", fn(connection) {
          // Act
          let outcome = run(connection, "SELECT * FROM changing", [], [], 5000)

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_tag
          |> be_equal("SELECT 0")
          |> or_fail_with("Expected the new statement to run")
        }),
      ]),
    ]),
    group("inside a transaction", [
      before_each(run_setup_script(
        "BEGIN; ALTER TABLE changing ADD COLUMN b int",
      )),
      it("gives the error inside a transaction (0A000)", fn(connection) {
        // Act
        let failed = run(connection, "SELECT * FROM changing", [], [], 5000)

        // Assert
        failed
        |> should
        |> be_error
        |> extract_driver_error_code
        |> be_equal("0A000")
        |> or_fail_with("Expected 0A000 in the transaction")
      }),
      it(
        "leaves the transaction failed after the error (0A000)",
        fn(connection) {
          // Act
          let failed = run(connection, "SELECT * FROM changing", [], [], 5000)

          // Assert
          failed
          |> should
          |> be_error
          |> extract_refusal_status
          |> be_equal(InFailedTransaction)
          |> or_fail_with("Expected the failed transaction with the error")
        },
      ),
    ]),
  ]
}

fn unnamed_statement_tests(server: Server) -> List(ContextNode(Connection)) {
  [
    before_each(start_test_caching(server, UnnamedStatements)),
    it(
      "refuses a prepare and a run with a zero byte with UnnamedStatements",
      fn(connection) {
        // Act
        let refused = prepare(connection, "SELECT 1\u{0000}", 5000)

        // Assert
        refused
        |> should
        |> be_error
        |> be_equal(InvalidRequest(ZeroByteInString("query")))
        |> or_fail_with("Expected InvalidRequest for the prepare")
      },
    ),
    it("refuses a run with a zero byte with UnnamedStatements", fn(connection) {
      // Act
      let refused = run(connection, "SELECT 1\u{0000}", [], [], 5000)

      // Assert
      refused
      |> should
      |> be_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest for the run")
    }),
    it(
      "gives the server's error for a run with UnnamedStatements",
      fn(connection) {
        // Act
        let refused = run(connection, "SELECT 1/0", [], [], 5000)

        // Assert
        refused
        |> should
        |> be_error
        |> extract_driver_error_code
        |> be_equal("22012")
        |> or_fail_with("Expected 22012")
      },
    ),
    it("prepares no named statement with UnnamedStatements", fn(connection) {
      // Act
      let statements = {
        use _first <- try(run(connection, "SELECT 1", [], [], 5000))
        use _second <- try(prepare(connection, "SELECT 1", 5000))
        run_script(connection, prepared_statements, 5000)
      }

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
  ]
}
