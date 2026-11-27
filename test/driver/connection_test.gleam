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
  type Outcome, ConnectionConfig, ConnectionLost, ConnectionProcessDown,
  CopyStatementRefused, DeadlinePassed, InvalidRequest, LoginUndecodable,
  ProtocolViolation, Reconnected, SetupTimedOut, TransportRefused,
  UndecodableMessage, UnexpectedIdleMessage, aborted_by, prepare, run,
  run_script, server_parameter, start, stop, supervised, transaction_status,
}
import dream_postgres/driver/message.{
  BindComplete, UnknownMessageType, ZeroByteInString,
}
import dream_postgres/driver/transport.{
  ConnectRefused, ConnectionReset, SendTimedOut, SocketClosed,
}
import dream_postgres/internal/cell.{
  Binary, BinaryFormat, ColumnDescription, CommandResult, Idle,
  InFailedTransaction, InTransaction, Null, ParameterDescription,
  StatementDescription, Text,
}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should, start_with,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/fake_server.{
  Answer, free_port, start_fake_server, start_silent_server,
}
import driver/proxy.{
  type Proxy, client_end, close_client, inject, reset_client, start_proxy,
  stop_proxy, watch_client_end,
}
import driver/server_connection.{
  type ProxiedConnection, type ProxiedOutcome, advisory_lock_sql, backend_pid,
  break_session, caller_answer, connection_config, connection_setup,
  fill_send_queue, hold_advisory_lock, inject_and_wait_for_parameter,
  lock_request, lock_waiter_pid, next_event, next_event_after_refused_reconnects,
  proxied_act_setup, proxied_setup, release_advisory_lock, run_control_script,
  run_control_setup_script, run_failing_script, run_failing_statement,
  run_setup_script, send_stray_message, start_caller, start_configured,
  start_connection, start_in_ended_owner, start_test_configured,
  start_test_connection, start_test_proxied, stop_after_error, stop_connection,
  stop_proxied, terminate_backend, terminate_session, tls_config, user_config,
  wait_for_lock_waiter, wait_for_table_waiter, watched_config,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/driver_tls.{verify_full}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/otp/static_supervisor
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_client_end.{extract_client_end}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_disconnect_error.{extract_disconnect_error}
import matchers/extract_driver_error_code.{extract_driver_error_code}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_login_refusal_code.{extract_login_refusal_code}
import matchers/extract_outcome_notices.{extract_outcome_notices}
import matchers/extract_outcome_notifications.{extract_outcome_notifications}
import matchers/extract_outcome_tags.{extract_outcome_tags}
import matchers/extract_reconnect_error.{extract_reconnect_error}
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
    late_answer_tests(),
    requests_at_loss_tests(),
    two_requests_tests(),
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
  let #(proxy_port, proxy) = start_proxy(first_driver_server.port)
  {
    use #(fake_port, _fake_server) <- try(
      start_fake_server(Answer(<<"x", 4:32>>)),
    )
    build_configs(proxy, proxy_port, fake_port)
  }
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn build_configs(
  proxy: Proxy,
  proxy_port: Int,
  fake_port: Int,
) -> Result(StartInputs, String) {
  let first_port = first_driver_server.port
  use wrong_password <- try(user_config(first_port, "dream", "wrong"))
  use no_listener <- try(connection_config(free_port()))
  use silent <- try(connection_config(start_silent_server()))
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
        "fails the supervisor's start when it cannot connect",
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
          |> be_error
          |> or_fail_with("Expected the supervisor's start to fail")
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
      before_each(start_test_proxied(first_driver_server, 60_000)),
      after_each(stop_proxied),
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
      lost_session_tests(),
      idle_message_tests(),
      lock_tests(),
      group("while the control connection locks a table", [
        before_each(run_control_setup_script(create_lock_table)),
        before_each(run_control_setup_script(lock_table)),
        // A prepare waits on a table that the control connection locks:
        // its Parse needs a lock on the table too. The proxy closes the
        // connection, and the caller gets the loss.
        it(
          "fails a running prepare when the network closes",
          fn(proxied: ProxiedConnection) {
            // Act
            let answer = {
              let running =
                start_caller(fn() {
                  prepare(
                    proxied.connection,
                    "SELECT x FROM driver_prepare_lock",
                    5000,
                  )
                })
              use _waited <- try(wait_for_table_waiter(
                proxied.control,
                "driver_prepare_lock",
              ))
              close_client(proxied.proxy)
              caller_answer(running)
            }

            // Assert
            answer
            |> should
            |> be_ok
            |> be_error
            |> be_equal(ConnectionLost(SocketClosed))
            |> or_fail_with("Expected the loss for the running prepare")
          },
        ),
      ]),
    ],
  )
}

const create_lock_table =
  "CREATE TABLE IF NOT EXISTS driver_prepare_lock (x int)"

const lock_table =
  "BEGIN; LOCK TABLE driver_prepare_lock IN ACCESS EXCLUSIVE MODE"

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
          |> be_equal(ConnectionLost(SocketClosed))
          |> or_fail_with("Expected the error of the loss")
        },
      ),
    ]),
    // The proxy stops reading, and a large script fills the socket's send
    // queue. The proxy then sends a CopyInResponse as if the server
    // answered. The step answers it with a CopyFail, whose send waits
    // behind the full queue and fails after the send timeout of 500
    // milliseconds.
    group("after the send queue filled", [
      before_each(fill_send_queue),
      it(
        "fails a send that the server never reads",
        fn(proxied: ProxiedConnection) {
          // Act
          inject(proxied.proxy, <<"G", 7:32, 0, 0:16>>)
          let event = next_event(proxied.events)

          // Assert
          event
          |> should
          |> be_ok
          |> extract_disconnect_error
          |> be_equal(ConnectionLost(SendTimedOut))
          |> or_fail_with("Expected the loss by a send timeout")
        },
      ),
    ]),
  ])
}

/// The proxy sends a NoticeResponse, a NotificationResponse and a
/// ParameterStatus as if the server sent them between requests. The next
/// outcome carries the notice and the notification, and the parameter has
/// its new value.
fn idle_message_tests() -> ContextNode(ProxiedConnection) {
  group("after messages between requests", [
    before_each(inject_and_wait_for_parameter(
      idle_messages(),
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
        |> be_equal(ConnectionLost(SocketClosed))
        |> or_fail_with("Expected the loss for the running request")
      },
    ),
    // A run waits on an advisory lock. The proxy closes the connection,
    // and the caller gets the loss.
    it(
      "fails a running run when the network closes",
      fn(proxied: ProxiedConnection) {
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
        |> be_equal(ConnectionLost(SocketClosed))
        |> or_fail_with("Expected the loss for the running run")
      },
    ),
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
  use connection <- try(start_configured(watched_config(config, events, 10)))
  use control <- try(
    start_connection(port) |> map_error(stop_after_error(connection, _)),
  )
  refuse_reconnect(connection, control, events)
  |> map_error(restore_after_error(connection, control, _))
}

fn refuse_reconnect(
  connection: Connection,
  control: Connection,
  events: Subject(ConnectionEvent),
) -> Result(RefusedReconnect, String) {
  use pid <- try(backend_pid(connection))
  use _changed <- try(run_control_script(control, change_password))
  use _terminated <- try(terminate_backend(control, pid))
  let lost = next_event(events)
  let refused = next_event(events)
  use _restored <- try(run_control_script(control, restore_password))
  let back = next_event_after_refused_reconnects(events)
  Ok(RefusedReconnect(connection:, control:, lost:, refused:, back:))
}

fn restore_after_error(
  connection: Connection,
  control: Connection,
  error: String,
) -> String {
  let restored = run_control_script(control, restore_password)
  stop(connection)
  stop(control)
  error <> "; restoring the password gave " <> inspect(restored)
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

// A late answer: one act for two tests ------------------------------------------

type LateAnswer {
  LateAnswer(
    late: Result(List(Outcome), DriverError),
    next: Result(Outcome, DriverError),
  )
}

/// A request waits on the lock past its deadline of 50 milliseconds. The
/// lock goes back, and the next query runs.
fn answer_late(proxied: ProxiedConnection) -> Result(LateAnswer, String) {
  use _locked <- try(hold_advisory_lock(proxied))
  let late =
    run_script(proxied.connection, advisory_lock_sql(proxied.lock_key), 50)
  use _released <- try(release_advisory_lock(proxied))
  let next = run(proxied.connection, "SELECT 3", [], [], 5000)
  Ok(LateAnswer(late:, next:))
}

fn late_answer_tests() -> TestSuite {
  describe(
    "a late answer",
    proxied_act_setup(first_driver_server, 60_000, answer_late),
    [
      it(
        "gives DeadlinePassed for a late answer",
        fn(shared: ProxiedOutcome(LateAnswer)) {
          shared.outcome.late
          |> should
          |> be_error
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with("Expected DeadlinePassed")
        },
      ),
      it(
        "gives DeadlinePassed and stays usable after a late answer",
        fn(shared: ProxiedOutcome(LateAnswer)) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"3">>)]])
          |> or_fail_with("Expected the next query's result")
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
