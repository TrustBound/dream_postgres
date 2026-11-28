//// The runners on the executor of a driver connection, against PostgreSQL
//// 16 to 19, and the client reason of each driver error.
////
//// Each server has one connection and one type catalog for all of its
//// tests. A test that writes rows makes its own temporary table, so no
//// table stays on the server.

import dream_postgres/codecs
import dream_postgres/codecs/array
import dream_postgres/codecs/numeric
import dream_postgres/driver/catalog
import dream_postgres/driver/catalog_table
import dream_postgres/driver/cell.{BinaryFormat, Idle, Text}
import dream_postgres/driver/channel_binding
import dream_postgres/driver/connection/event as connection_event
import dream_postgres/driver/connection/outcome as connection_outcome
import dream_postgres/driver/connection/request_failure as connection_request_failure
import dream_postgres/driver/login
import dream_postgres/driver/login/login_config
import dream_postgres/driver/message
import dream_postgres/driver/pool/pool_failure
import dream_postgres/driver/query/step as query_step
import dream_postgres/driver/scram
import dream_postgres/driver/transport
import dream_postgres/error.{PostgresError}
import dream_postgres/posix
import dream_postgres/query/definition
import dream_postgres/query/driver_executor
import dream_postgres/query/runner
import dream_postgres/row/reader.{column, row, single}
import dream_postgres/sql_state.{SyntaxError, UniqueViolation}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import fixtures/driver_errors
import fixtures/driver_outcomes
import fixtures/executor_sessions
import fixtures/server_reports
import fixtures/server_versions
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import matchers/have_cause.{have_cause}
import matchers/have_kind_and_sql_state.{have_kind_and_sql_state}
import matchers/have_reason.{have_reason}
import matchers/have_sql_state_message_position.{have_sql_state_message_position}
import matchers/map_address_fault.{map_address_fault}
import matchers/map_catalog_error.{map_catalog_error}
import matchers/map_checkout_error.{map_checkout_error}
import matchers/map_chunk_error.{map_chunk_error}
import matchers/map_connect_failure.{map_connect_failure}
import matchers/map_connection_state_error.{map_connection_state_error}
import matchers/map_copy_error.{map_copy_error}
import matchers/map_login_config_fault.{map_login_config_fault}
import matchers/map_pool_start_error.{map_pool_start_error}
import matchers/map_prepare_error.{map_prepare_error}
import matchers/map_request_failure.{map_request_failure}
import matchers/map_run_error.{map_run_error}
import matchers/map_run_failure.{map_run_failure}
import matchers/map_simple_query_error.{map_simple_query_error}
import matchers/run_on_executor.{run_on_executor}
import matchers/run_on_executor_with_deadline.{run_on_executor_with_deadline}
import matchers/run_simple_query_on_server.{run_simple_query_on_server}

/// The runners on the executor of a driver connection to each server.
pub fn tests() -> TestSuite {
  describe(
    "the driver executor on PostgreSQL 16 to 19",
    context.setup(executor_sessions.start, teardown: executor_sessions.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(executor_sessions.choose_version(version)),
        it(
          "all reads int, text, nullable, numeric and array columns",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_on_executor(fn(executor) {
              runner.all(
                definition.query(
                  "SELECT * FROM (VALUES "
                  <> "(1, 'one'::text, NULL::int4, 1.50::numeric, ARRAY[1, 2]), "
                  <> "(2, 'two'::text, 7, 0.25, ARRAY[]::int4[])"
                  <> ") AS mixed(id, name, maybe, amount, items) ORDER BY id",
                ),
                {
                  use id <- column(codecs.int)
                  use name <- column(codecs.text)
                  use maybe <- column(codecs.nullable(codecs.int))
                  use amount <- column(numeric.numeric)
                  use items <- column(array.array(codecs.int))
                  row(#(id, name, maybe, amount, items))
                },
                runner.DatabaseLayer(executor),
                [],
              )
            })
            |> be_ok()
            |> be_equal([
              #(1, "one", None, "1.50", [1, 2]),
              #(2, "two", Some(7), "0.25", []),
            ])
            |> or_fail_with("Expected the two rows with each column read")
          },
        ),
        it("one reads the one row", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.one(
              definition.query("SELECT 41 + $1")
                |> definition.parameter(codecs.int, 1),
              single(codecs.int),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_ok()
          |> be_equal(42)
          |> or_fail_with("Expected 41 + 1 to be 42")
        }),
        it("maybe_one gives None for no row", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.maybe_one(
              definition.query("SELECT generate_series(1, $1)")
                |> definition.parameter(codecs.int, 0),
              single(codecs.int),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_ok()
          |> be_none()
          |> or_fail_with("Expected None for a series of no rows")
        }),
        it("maybe_one gives the one row", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.maybe_one(
              definition.query("SELECT generate_series(1, $1)")
                |> definition.parameter(codecs.int, 1),
              single(codecs.int),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_ok()
          |> be_some()
          |> be_equal(1)
          |> or_fail_with("Expected the one row 1")
        }),
        it("maybe_one gives TooManyRows for two rows", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.maybe_one(
              definition.query("SELECT generate_series(1, $1)")
                |> definition.parameter(codecs.int, 2),
              single(codecs.int),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.TooManyRows(count: 2))
          |> or_fail_with("Expected TooManyRows with a count of 2")
        }),
        it("affected gives the counts of an INSERT and an UPDATE", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_simple_query_on_server(
            "CREATE TEMP TABLE executor_counts (id int4)",
          )
          |> run_on_executor(fn(executor) {
            use inserted <- result.try(
              runner.affected(
                definition.query(
                  "INSERT INTO executor_counts SELECT generate_series(1, 3)",
                ),
                runner.DatabaseLayer(executor),
                [],
              ),
            )
            use updated <- result.try(
              runner.affected(
                definition.query(
                  "UPDATE executor_counts SET id = id + 10 WHERE id > $1",
                )
                  |> definition.parameter(codecs.int, 1),
                runner.DatabaseLayer(executor),
                [],
              ),
            )
            Ok(#(inserted, updated))
          })
          |> be_ok()
          |> be_equal(#(3, 2))
          |> or_fail_with("Expected 3 rows inserted and 2 rows updated")
        }),
        it(
          "a parameter whose codec does not fit its type runs nothing",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_simple_query_on_server(
              "CREATE TEMP TABLE executor_mismatch (id int4)",
            )
            |> run_on_executor(fn(executor) {
              let inserted =
                runner.affected(
                  definition.query("INSERT INTO executor_mismatch VALUES ($1)")
                    |> definition.parameter(codecs.text, "1"),
                  runner.DatabaseLayer(executor),
                  [],
                )
              use count <- result.try(
                runner.one(
                  definition.query("SELECT count(*) FROM executor_mismatch"),
                  single(codecs.int),
                  runner.DatabaseLayer(executor),
                  [],
                ),
              )
              Ok(#(inserted, count))
            })
            |> be_ok()
            |> be_equal(#(
              Error(
                error.to_dream_error(PostgresError(
                  query_name: None,
                  sql: Some("INSERT INTO executor_mismatch VALUES ($1)"),
                  reason: error.ParameterTypeMismatch(
                    position: 1,
                    database_type: "int4",
                    codec: "text",
                  ),
                )),
              ),
              0,
            ))
            |> or_fail_with("Expected text to refuse int4, and no row inserted")
          },
        ),
        it(
          "INSERT RETURNING with a wrong row reader inserts no row",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_simple_query_on_server(
              "CREATE TEMP TABLE executor_returning (id int4)",
            )
            |> run_on_executor(fn(executor) {
              let inserted =
                runner.one(
                  definition.query(
                    "INSERT INTO executor_returning VALUES (5) RETURNING id",
                  ),
                  single(codecs.text),
                  runner.DatabaseLayer(executor),
                  [],
                )
              use count <- result.try(
                runner.one(
                  definition.query("SELECT count(*) FROM executor_returning"),
                  single(codecs.int),
                  runner.DatabaseLayer(executor),
                  [],
                ),
              )
              Ok(#(inserted, count))
            })
            |> be_ok()
            |> be_equal(#(
              Error(
                error.to_dream_error(PostgresError(
                  query_name: None,
                  sql: Some(
                    "INSERT INTO executor_returning VALUES (5) RETURNING id",
                  ),
                  reason: error.ColumnTypeMismatch(
                    position: 1,
                    name: "id",
                    database_type: "int4",
                    codec: "text",
                  ),
                )),
              ),
              0,
            ))
            |> or_fail_with("Expected text to refuse the int4 id, and no row")
          },
        ),
        it(
          "NULL read with a codec that is never NULL is UnexpectedNull",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_on_executor(fn(executor) {
              runner.one(
                definition.query("SELECT NULL::int4 AS total"),
                single(codecs.int),
                runner.DatabaseLayer(executor),
                [],
              )
            })
            |> be_error()
            |> have_cause()
            |> have_reason()
            |> be_equal(error.UnexpectedNull(position: 1, name: "total"))
            |> or_fail_with("Expected UnexpectedNull for the column total")
          },
        ),
        it(
          "a unique violation is Server with its SQLSTATE, and Conflict",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_simple_query_on_server(
              "CREATE TEMP TABLE executor_unique (id int4); "
              <> "CREATE UNIQUE INDEX executor_unique_id ON executor_unique (id); "
              <> "INSERT INTO executor_unique VALUES (1)",
            )
            |> run_on_executor(fn(executor) {
              runner.affected(
                definition.query("INSERT INTO executor_unique VALUES ($1)")
                  |> definition.parameter(codecs.int, 1),
                runner.DatabaseLayer(executor),
                [],
              )
            })
            |> be_error()
            |> have_kind_and_sql_state()
            |> be_equal(#("conflict", Some(UniqueViolation)))
            |> or_fail_with("Expected a conflict with the SQLSTATE 23505")
          },
        ),
        it("a syntax error gives the server's report", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.all(
              definition.query("SELEC 1"),
              single(codecs.int),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_error()
          |> have_sql_state_message_position()
          |> be_equal(#(
            SyntaxError,
            "syntax error at or near \"SELEC\"",
            Some(1),
          ))
          |> or_fail_with("Expected the syntax error at SELEC, at position 1")
        }),
        it(
          "a deadline of 500 ms on pg_sleep(5) is a cancelled QueryTimeout",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_on_executor_with_deadline(500, fn(executor) {
              runner.affected(
                definition.query("SELECT pg_sleep(5)"),
                runner.DatabaseLayer(executor),
                [],
              )
            })
            |> be_error()
            |> have_cause()
            |> have_reason()
            |> be_equal(error.QueryTimeout(stopped_on_server: True))
            |> or_fail_with(
              "Expected QueryTimeout with the cancel confirmed after 500 ms",
            )
          },
        ),
        it(
          "checks again after a table changed, and refuses the old reader",
          fn(sessions) {
            // Act and assert
            sessions
            |> should
            |> run_simple_query_on_server(
              "CREATE TEMP TABLE changing_table (id int4); INSERT INTO changing_table VALUES (1)",
            )
            |> run_on_executor(fn(executor) {
              let select_all = definition.query("SELECT * FROM changing_table")
              use _first <- result.try(
                runner.all(
                  select_all,
                  single(codecs.int),
                  runner.DatabaseLayer(executor),
                  [],
                ),
              )
              use _altered <- result.try(
                runner.affected(
                  definition.query(
                    "ALTER TABLE changing_table ADD COLUMN note text",
                  ),
                  runner.DatabaseLayer(executor),
                  [],
                ),
              )
              runner.all(
                select_all,
                single(codecs.int),
                runner.DatabaseLayer(executor),
                [],
              )
            })
            |> be_error()
            |> have_cause()
            |> have_reason()
            |> be_equal(error.ColumnCountMismatch(expected: 1, got: 2))
            |> or_fail_with("Expected the reader of 1 column to refuse 2")
          },
        ),
        it("SQL with a zero byte is RequestNotWritable", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.affected(
              definition.query("SELECT 1\u{0000}"),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.RequestNotWritable(error.ZeroByteInString("query")))
          |> or_fail_with("Expected the zero byte in the query to be refused")
        }),
        it("a COPY statement is CopyStatementRefused", fn(sessions) {
          // Act and assert
          sessions
          |> should
          |> run_on_executor(fn(executor) {
            runner.affected(
              definition.query("COPY (SELECT 1) TO STDOUT"),
              runner.DatabaseLayer(executor),
              [],
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(error.CopyStatementRefused(statements_run: 0))
          |> or_fail_with("Expected the COPY statement to be refused")
        }),
      ])
    }),
  )
}

/// The client reason of each driver error that the servers do not give.
pub fn mapping_tests() -> TestSuite {
  unit.describe("the client reason of each driver error", [
    unit.group("driver errors", [
      unit.it("a refused statement is Server", fn() {
        // Arrange
        let report = server_reports.administrator_shutdown()

        // Act and assert
        connection_request_failure.RunRefused(report, Idle)
        |> should
        |> map_run_error()
        |> be_equal(error.Server(error.server_error_from_report(report)))
        |> or_fail_with("Expected the report as a Server reason")
      }),
      unit.it(
        "a failed later statement of a `run_sql` call is SqlStatementFailed",
        fn() {
          // Arrange
          let report = server_reports.administrator_shutdown()

          // Act and assert
          connection_request_failure.SimpleQueryFailed(
            [driver_outcomes.insert_outcome()],
            report,
            Idle,
          )
          |> should
          |> map_simple_query_error()
          |> be_equal(error.SqlStatementFailed(
            statements_run: 1,
            server_error: error.server_error_from_report(report),
          ))
          |> or_fail_with(
            "Expected SqlStatementFailed after 1 statement with the report",
          )
        },
      ),
      unit.it("an ended connection is Server", fn() {
        // Arrange
        let report = server_reports.administrator_shutdown()

        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ServerEndedConnection(report),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.Server(error.server_error_from_report(report)))
        |> or_fail_with("Expected the report of the end as a Server reason")
      }),
      unit.it(
        "a statement that changed where the client cannot check it again is StatementChangedDuringRun",
        fn() {
          // Act and assert
          connection_request_failure.RunStatementChanged(
            cell.StatementDescription([], []),
          )
          |> should
          |> map_run_error()
          |> be_equal(error.StatementChangedDuringRun)
          |> or_fail_with("Expected StatementChangedDuringRun")
        },
      ),
      unit.it("no call starts after the deadline of the query", fn() {
        // Arrange
        let deadline_at = driver_executor.monotonic_milliseconds()

        // Act
        let remaining = driver_executor.remaining_milliseconds(deadline_at)

        // Assert
        remaining
        |> should
        |> be_error()
        |> be_equal(error.QueryTimeout(stopped_on_server: True))
        |> or_fail_with("Expected QueryTimeout at the deadline")
      }),
      unit.it("a passed deadline is QueryTimeout", fn() {
        // Act and assert
        connection_request_failure.DeadlinePassed(True)
        |> should
        |> map_request_failure()
        |> be_equal(error.QueryTimeout(stopped_on_server: True))
        |> or_fail_with("Expected QueryTimeout")
      }),
      unit.it(
        "SQL that ran to its end and started no COPY is CopyNotStarted",
        fn() {
          // Act and assert
          connection_request_failure.CopyNotStarted(
            completed: Some(driver_outcomes.insert_outcome()),
          )
          |> should
          |> map_copy_error()
          |> be_equal(error.CopyNotStarted(statement_ran: True))
          |> or_fail_with("Expected CopyNotStarted(statement_ran: True)")
        },
      ),
      unit.it(
        "a passed deadline with no confirmed cancel is QueryTimeout",
        fn() {
          // Act and assert
          connection_request_failure.DeadlinePassed(False)
          |> should
          |> map_request_failure()
          |> be_equal(error.QueryTimeout(stopped_on_server: False))
          |> or_fail_with("Expected QueryTimeout(stopped_on_server: False)")
        },
      ),
      unit.it("SQL that starts no COPY is CopyNotStarted", fn() {
        // Act and assert
        connection_request_failure.CopyNotStarted(completed: None)
        |> should
        |> map_copy_error()
        |> be_equal(error.CopyNotStarted(statement_ran: False))
        |> or_fail_with("Expected CopyNotStarted")
      }),
      unit.it("a chunk for a COPY that ended is CopyNotRunning", fn() {
        // Act and assert
        connection_request_failure.ChunkCopyNotRunning
        |> should
        |> map_chunk_error()
        |> be_equal(error.CopyNotRunning)
        |> or_fail_with("Expected CopyNotRunning")
      }),
      unit.it("a failed COPY function gives its own reason", fn() {
        // Act and assert
        connection_request_failure.AppFailed(error.CopyQueryHasParameters(1))
        |> should
        |> map_copy_error()
        |> be_equal(error.CopyQueryHasParameters(1))
        |> or_fail_with("Expected the reason of the function")
      }),
      unit.it("a COPY that failed on its connection gives its reason", fn() {
        // Act and assert
        connection_request_failure.CopyFailed(
          connection_request_failure.DeadlinePassed(False),
        )
        |> should
        |> map_copy_error()
        |> be_equal(error.QueryTimeout(stopped_on_server: False))
        |> or_fail_with("Expected QueryTimeout")
      }),
      unit.it("a process that is down is ConnectionProcessDown", fn() {
        // Act and assert
        connection_request_failure.ConnectionProcessDown
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionProcessDown)
        |> or_fail_with("Expected ConnectionProcessDown")
      }),
      unit.it("an undecodable message is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.UnknownMessageType(33))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.UnknownMessageType(33)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(UnknownMessageType(33))",
        )
      }),
      unit.it("a message between requests is UnexpectedIdleMessage", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ProtocolViolation(
            connection_outcome.UnexpectedIdleMessage(message.BindComplete),
          ),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedIdleMessage(error.BindComplete))
        |> or_fail_with("Expected UnexpectedIdleMessage(BindComplete)")
      }),
    ]),
    unit.group("loss reasons", [
      unit.it("a close after a deadline is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(connection_event.ClosedAfterDeadline),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionLost(error.ClosedAfterDeadline))
        |> or_fail_with("Expected ConnectionLost(ClosedAfterDeadline)")
      }),
      unit.it("a server that stopped reading is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(connection_event.ServerStoppedReading),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionLost(error.SendTimedOut))
        |> or_fail_with("Expected ConnectionLost(SendTimedOut)")
      }),
      unit.it("a closed socket is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(connection_event.SocketFailed(
            transport.SocketClosed,
          )),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionLost(error.ClosedByServer))
        |> or_fail_with("Expected ConnectionLost(ClosedByServer)")
      }),
      unit.it("a reset is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(connection_event.SocketFailed(
            transport.ConnectionReset,
          )),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionLost(error.Reset))
        |> or_fail_with("Expected ConnectionLost(Reset)")
      }),
      unit.it("a TLS alert is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(
            connection_event.SocketFailed(transport.TlsAlertRaised(
              "bad_record_mac",
            )),
          ),
        )
        |> should
        |> map_request_failure()
        |> be_equal(
          error.ConnectionLost(error.TlsAlertRaised("bad_record_mac")),
        )
        |> or_fail_with(
          "Expected ConnectionLost(TlsAlertRaised(\"bad_record_mac\"))",
        )
      }),
      unit.it("a listed OS error is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(
            connection_event.SocketFailed(transport.Unlisted("ehostunreach")),
          ),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.ConnectionLost(error.OsError(posix.Ehostunreach)))
        |> or_fail_with("Expected ConnectionLost(OsError(Ehostunreach))")
      }),
      unit.it("an OS error that is not listed is ConnectionLost", fn() {
        // Act and assert
        connection_request_failure.ConnectionEnded(
          connection_event.ConnectionLost(
            connection_event.SocketFailed(transport.Unlisted("errno_999")),
          ),
        )
        |> should
        |> map_request_failure()
        |> be_equal(
          error.ConnectionLost(error.OsError(posix.Unlisted("errno_999"))),
        )
        |> or_fail_with(
          "Expected ConnectionLost(OsError(Unlisted(\"errno_999\")))",
        )
      }),
    ]),
    unit.group("prepare errors", [
      unit.it("a failed request is its reason", fn() {
        // Act and assert
        connection_request_failure.PrepareFailed(
          connection_request_failure.ConnectionProcessDown,
        )
        |> should
        |> map_prepare_error()
        |> be_equal(error.ConnectionProcessDown)
        |> or_fail_with("Expected ConnectionProcessDown")
      }),
      unit.it("a connection that has not logged in yet is ConnectFailed", fn() {
        // Act and assert
        connection_request_failure.PrepareNotConnected(
          connection_event.TransportRefused(transport.ConnectRefused),
        )
        |> should
        |> map_prepare_error()
        |> be_equal(
          error.ConnectFailed(error.ConnectionRefused(
            host: "db.example",
            port: 5432,
          )),
        )
        |> or_fail_with(
          "Expected ConnectFailed(ConnectionRefused) for db.example on port 5432",
        )
      }),
      unit.it("an unwritable statement is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.PrepareUnencodable(message.ZeroByteInString(
          "query",
        ))
        |> should
        |> map_prepare_error()
        |> be_equal(error.RequestNotWritable(error.ZeroByteInString("query")))
        |> or_fail_with(
          "Expected RequestNotWritable(ZeroByteInString(\"query\"))",
        )
      }),
      unit.it("a refused statement is Server", fn() {
        // Act and assert
        connection_request_failure.PrepareRefused(
          server_reports.administrator_shutdown(),
          Idle,
        )
        |> should
        |> map_prepare_error()
        |> be_equal(
          error.Server(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with("Expected the report as a Server reason")
      }),
    ]),
    unit.group("run errors", [
      unit.it("a failed request is its reason", fn() {
        // Act and assert
        connection_request_failure.RunFailed(
          connection_request_failure.DeadlinePassed(True),
        )
        |> should
        |> map_run_error()
        |> be_equal(error.QueryTimeout(stopped_on_server: True))
        |> or_fail_with("Expected QueryTimeout")
      }),
      unit.it("a connection that has not logged in yet is ConnectFailed", fn() {
        // Act and assert
        connection_request_failure.RunNotConnected(
          connection_event.TransportRefused(transport.ConnectRefused),
        )
        |> should
        |> map_run_error()
        |> be_equal(
          error.ConnectFailed(error.ConnectionRefused(
            host: "db.example",
            port: 5432,
          )),
        )
        |> or_fail_with(
          "Expected ConnectFailed(ConnectionRefused) for db.example on port 5432",
        )
      }),
      unit.it("a COPY statement is CopyStatementRefused", fn() {
        // Act and assert
        connection_request_failure.RunCopyRefused
        |> should
        |> map_run_error()
        |> be_equal(error.CopyStatementRefused(statements_run: 0))
        |> or_fail_with("Expected CopyStatementRefused")
      }),
    ]),
    unit.group("run failures for the runner", [
      unit.it("a changed statement goes back to the runner", fn() {
        // Act and assert
        connection_request_failure.RunStatementChanged(
          cell.StatementDescription([], []),
        )
        |> should
        |> map_run_failure()
        |> be_equal(runner.StatementChanged(cell.StatementDescription([], [])))
        |> or_fail_with("Expected StatementChanged with the new description")
      }),
      unit.it("a failed request is RunFailed", fn() {
        // Act and assert
        connection_request_failure.RunFailed(
          connection_request_failure.ConnectionProcessDown,
        )
        |> should
        |> map_run_failure()
        |> be_equal(runner.RunFailed(error.ConnectionProcessDown))
        |> or_fail_with("Expected RunFailed(ConnectionProcessDown)")
      }),
      unit.it("a connection that has not logged in yet is RunFailed", fn() {
        // Act and assert
        connection_request_failure.RunNotConnected(
          connection_event.TransportRefused(transport.ConnectRefused),
        )
        |> should
        |> map_run_failure()
        |> be_equal(
          runner.RunFailed(
            error.ConnectFailed(error.ConnectionRefused(
              host: "db.example",
              port: 5432,
            )),
          ),
        )
        |> or_fail_with("Expected RunFailed(ConnectFailed(ConnectionRefused))")
      }),
      unit.it("an unwritable statement is RunFailed", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(message.ZeroByteInString(
          "query",
        ))
        |> should
        |> map_run_failure()
        |> be_equal(
          runner.RunFailed(
            error.RequestNotWritable(error.ZeroByteInString("query")),
          ),
        )
        |> or_fail_with(
          "Expected RunFailed(RequestNotWritable(ZeroByteInString(\"query\")))",
        )
      }),
      unit.it("a refused statement is RunFailed", fn() {
        // Act and assert
        connection_request_failure.RunRefused(
          server_reports.administrator_shutdown(),
          Idle,
        )
        |> should
        |> map_run_failure()
        |> be_equal(
          runner.RunFailed(
            error.Server(
              error.server_error_from_report(
                server_reports.administrator_shutdown(),
              ),
            ),
          ),
        )
        |> or_fail_with("Expected RunFailed with the report as a Server reason")
      }),
      unit.it("a COPY statement is RunFailed", fn() {
        // Act and assert
        connection_request_failure.RunCopyRefused
        |> should
        |> map_run_failure()
        |> be_equal(
          runner.RunFailed(error.CopyStatementRefused(statements_run: 0)),
        )
        |> or_fail_with("Expected RunFailed(CopyStatementRefused)")
      }),
    ]),
    unit.group("run_sql errors", [
      unit.it("a failed request is its reason", fn() {
        // Act and assert
        connection_request_failure.SimpleQueryRequestFailed(
          connection_request_failure.ConnectionProcessDown,
        )
        |> should
        |> map_simple_query_error()
        |> be_equal(error.ConnectionProcessDown)
        |> or_fail_with("Expected ConnectionProcessDown")
      }),
      unit.it("a connection that has not logged in yet is ConnectFailed", fn() {
        // Act and assert
        connection_request_failure.SimpleQueryNotConnected(
          connection_event.TransportRefused(transport.ConnectRefused),
        )
        |> should
        |> map_simple_query_error()
        |> be_equal(
          error.ConnectFailed(error.ConnectionRefused(
            host: "db.example",
            port: 5432,
          )),
        )
        |> or_fail_with(
          "Expected ConnectFailed(ConnectionRefused) for db.example on port 5432",
        )
      }),
      unit.it("an unwritable simple query is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.SimpleQueryUnencodable(
          message.ZeroByteInString("query"),
        )
        |> should
        |> map_simple_query_error()
        |> be_equal(error.RequestNotWritable(error.ZeroByteInString("query")))
        |> or_fail_with(
          "Expected RequestNotWritable(ZeroByteInString(\"query\"))",
        )
      }),
      unit.it("a refused first statement is Server", fn() {
        // Act and assert
        connection_request_failure.SimpleQueryRefused(
          server_reports.administrator_shutdown(),
          Idle,
        )
        |> should
        |> map_simple_query_error()
        |> be_equal(
          error.Server(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with("Expected the report as a Server reason")
      }),
      unit.it(
        "a COPY statement after two statements is CopyStatementRefused",
        fn() {
          // Act and assert
          connection_request_failure.SimpleQueryCopyRefused([
            driver_outcomes.insert_outcome(),
            driver_outcomes.insert_outcome(),
          ])
          |> should
          |> map_simple_query_error()
          |> be_equal(error.CopyStatementRefused(statements_run: 2))
          |> or_fail_with("Expected CopyStatementRefused(statements_run: 2)")
        },
      ),
      unit.it("a COPY statement is CopyStatementRefused", fn() {
        // Act and assert
        connection_request_failure.SimpleQueryCopyRefused([])
        |> should
        |> map_simple_query_error()
        |> be_equal(error.CopyStatementRefused(statements_run: 0))
        |> or_fail_with("Expected CopyStatementRefused")
      }),
    ]),
    unit.group("copy errors", [
      unit.it("a connection that has not logged in yet is ConnectFailed", fn() {
        // Act and assert
        connection_request_failure.CopyNotConnected(
          connection_event.TransportRefused(transport.ConnectRefused),
        )
        |> should
        |> map_copy_error()
        |> be_equal(
          error.ConnectFailed(error.ConnectionRefused(
            host: "db.example",
            port: 5432,
          )),
        )
        |> or_fail_with(
          "Expected ConnectFailed(ConnectionRefused) for db.example on port 5432",
        )
      }),
      unit.it("an unwritable COPY is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.CopyUnencodable(message.ZeroByteInString(
          "query",
        ))
        |> should
        |> map_copy_error()
        |> be_equal(error.RequestNotWritable(error.ZeroByteInString("query")))
        |> or_fail_with(
          "Expected RequestNotWritable(ZeroByteInString(\"query\"))",
        )
      }),
      unit.it("a refused COPY is Server", fn() {
        // Act and assert
        connection_request_failure.CopyRefused(
          server_reports.administrator_shutdown(),
          Idle,
        )
        |> should
        |> map_copy_error()
        |> be_equal(
          error.Server(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with("Expected the report as a Server reason")
      }),
    ]),
    unit.group("chunk errors", [
      unit.it("a failed request is its reason", fn() {
        // Act and assert
        connection_request_failure.ChunkFailed(
          connection_request_failure.DeadlinePassed(False),
        )
        |> should
        |> map_chunk_error()
        |> be_equal(error.QueryTimeout(stopped_on_server: False))
        |> or_fail_with("Expected QueryTimeout")
      }),
      unit.it("a refused chunk is Server", fn() {
        // Act and assert
        connection_request_failure.ChunkRefused(
          server_reports.administrator_shutdown(),
          Idle,
        )
        |> should
        |> map_chunk_error()
        |> be_equal(
          error.Server(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with("Expected the report as a Server reason")
      }),
    ]),
    unit.group("connection state errors", [
      unit.it("a process that is gone is ConnectionProcessDown", fn() {
        // Act and assert
        connection_request_failure.ProcessGone
        |> should
        |> map_connection_state_error()
        |> be_equal(error.ConnectionProcessDown)
        |> or_fail_with("Expected ConnectionProcessDown")
      }),
      unit.it("no answer in time is QueryTimeout", fn() {
        // Act and assert
        connection_request_failure.NoAnswerInTime
        |> should
        |> map_connection_state_error()
        |> be_equal(error.QueryTimeout(stopped_on_server: False))
        |> or_fail_with("Expected QueryTimeout")
      }),
    ]),
    unit.group("protocol errors", [
      unit.it("UnknownMessageType(33) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.UnknownMessageType(33))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.UnknownMessageType(33)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(UnknownMessageType(33))",
        )
      }),
      unit.it("InvalidMessageLength(68, 2) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.InvalidMessageLength(68, 2))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.InvalidMessageLength(68, 2)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(InvalidMessageLength(68, 2))",
        )
      }),
      unit.it("InvalidMessageBody(68) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.InvalidMessageBody(68))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.InvalidMessageBody(68)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(InvalidMessageBody(68))",
        )
      }),
      unit.it("InvalidUtf8(84) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.InvalidUtf8(84))
        |> should
        |> map_request_failure()
        |> be_equal(error.UndecodableServerMessage(error.InvalidUtf8(84)))
        |> or_fail_with("Expected UndecodableServerMessage(InvalidUtf8(84))")
      }),
      unit.it(
        "UnknownAuthenticationRequest(99) is UndecodableServerMessage",
        fn() {
          // Act and assert
          driver_errors.undecodable_message(
            message.UnknownAuthenticationRequest(99),
          )
          |> should
          |> map_request_failure()
          |> be_equal(
            error.UndecodableServerMessage(error.UnknownAuthenticationRequest(
              99,
            )),
          )
          |> or_fail_with(
            "Expected UndecodableServerMessage(UnknownAuthenticationRequest(99))",
          )
        },
      ),
      unit.it("UnknownTransactionStatus(88) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.UnknownTransactionStatus(88))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.UnknownTransactionStatus(88)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(UnknownTransactionStatus(88))",
        )
      }),
      unit.it("UnknownFormatCode(84, 2) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.UnknownFormatCode(84, 2))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.UnknownFormatCode(84, 2)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(UnknownFormatCode(84, 2))",
        )
      }),
      unit.it("InvalidSecretKeyLength(2) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.InvalidSecretKeyLength(2))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.InvalidSecretKeyLength(2)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(InvalidSecretKeyLength(2))",
        )
      }),
      unit.it("MissingReportField(69, 67) is UndecodableServerMessage", fn() {
        // Act and assert
        driver_errors.undecodable_message(message.MissingReportField(69, 67))
        |> should
        |> map_request_failure()
        |> be_equal(
          error.UndecodableServerMessage(error.MissingReportField(69, 67)),
        )
        |> or_fail_with(
          "Expected UndecodableServerMessage(MissingReportField(69, 67))",
        )
      }),
      unit.it(
        "InvalidReportNumber(69, 80, \"x\") is UndecodableServerMessage",
        fn() {
          // Act and assert
          driver_errors.undecodable_message(message.InvalidReportNumber(
            69,
            80,
            "x",
          ))
          |> should
          |> map_request_failure()
          |> be_equal(
            error.UndecodableServerMessage(error.InvalidReportNumber(
              69,
              80,
              "x",
            )),
          )
          |> or_fail_with(
            "Expected UndecodableServerMessage(InvalidReportNumber(69, 80, \"x\"))",
          )
        },
      ),
    ]),
    unit.group("backend messages", [
      unit.it("AuthenticationOk is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.AuthenticationOk)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationOk,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationOk, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationKerberosV5 is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.AuthenticationKerberosV5)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationKerberosV5,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationKerberosV5, step: ReadingExecuteRows)",
        )
      }),
      unit.it(
        "AuthenticationCleartextPassword is UnexpectedServerMessage",
        fn() {
          // Act and assert
          driver_errors.unexpected_message(
            message.AuthenticationCleartextPassword,
          )
          |> should
          |> map_request_failure()
          |> be_equal(error.UnexpectedServerMessage(
            message: error.AuthenticationCleartextPassword,
            step: error.ReadingExecuteRows,
          ))
          |> or_fail_with(
            "Expected UnexpectedServerMessage(message: AuthenticationCleartextPassword, step: ReadingExecuteRows)",
          )
        },
      ),
      unit.it("AuthenticationMd5Password is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.AuthenticationMd5Password(<<1, 2, 3, 4>>),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationMd5Password,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationMd5Password, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationGss is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.AuthenticationGss)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationGss,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationGss, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationGssContinue is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.AuthenticationGssContinue(<<>>),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationGssContinue,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationGssContinue, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationSspi is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.AuthenticationSspi)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationSspi,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationSspi, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationSasl is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.AuthenticationSasl(["SCRAM-SHA-256"]),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationSasl,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationSasl, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationSaslContinue is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.AuthenticationSaslContinue(<<>>),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationSaslContinue,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationSaslContinue, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AuthenticationSaslFinal is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.AuthenticationSaslFinal(<<>>))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.AuthenticationSaslFinal,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: AuthenticationSaslFinal, step: ReadingExecuteRows)",
        )
      }),
      unit.it("BackendKeyData is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.BackendKeyData(1, <<1, 2, 3, 4>>),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.BackendKeyData,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: BackendKeyData, step: ReadingExecuteRows)",
        )
      }),
      unit.it("BindComplete is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.BindComplete)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.BindComplete,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: BindComplete, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CloseComplete is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.CloseComplete)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CloseComplete,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CloseComplete, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CommandComplete is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.CommandComplete("SELECT 1"))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CommandComplete,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CommandComplete, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CopyData is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.CopyDataFromServer(<<>>))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CopyData,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CopyData, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CopyDone is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.CopyDoneFromServer)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CopyDone,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CopyDone, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CopyInResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.CopyInResponse(BinaryFormat, []),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CopyInResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CopyInResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CopyOutResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.CopyOutResponse(BinaryFormat, []),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CopyOutResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CopyOutResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("CopyBothResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.CopyBothResponse(BinaryFormat, []),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.CopyBothResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: CopyBothResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("DataRow is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.DataRow([]))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.DataRow,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: DataRow, step: ReadingExecuteRows)",
        )
      }),
      unit.it("EmptyQueryResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.EmptyQueryResponse)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.EmptyQueryResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: EmptyQueryResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("ErrorResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.ErrorResponse(server_reports.administrator_shutdown()),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.ErrorResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: ErrorResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("FunctionCallResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.FunctionCallResponse(None))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.FunctionCallResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: FunctionCallResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("NegotiateProtocolVersion is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.NegotiateProtocolVersion(3, 196_608, []),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NegotiateProtocolVersion,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NegotiateProtocolVersion, step: ReadingExecuteRows)",
        )
      }),
      unit.it("NoData is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.NoData)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: ReadingExecuteRows)",
        )
      }),
      unit.it("NoticeResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(
          message.NoticeResponse(server_reports.administrator_shutdown()),
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoticeResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoticeResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("NotificationResponse is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.NotificationResponse(
          1,
          "jobs",
          "",
        ))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NotificationResponse,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NotificationResponse, step: ReadingExecuteRows)",
        )
      }),
      unit.it("ParameterDescription is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.ParameterDescriptions([]))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.ParameterDescription,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: ParameterDescription, step: ReadingExecuteRows)",
        )
      }),
      unit.it("ParameterStatus is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.ParameterStatus(
          "TimeZone",
          "UTC",
        ))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.ParameterStatus,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: ParameterStatus, step: ReadingExecuteRows)",
        )
      }),
      unit.it("ParseComplete is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.ParseComplete)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.ParseComplete,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: ParseComplete, step: ReadingExecuteRows)",
        )
      }),
      unit.it("PortalSuspended is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.PortalSuspended)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.PortalSuspended,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: PortalSuspended, step: ReadingExecuteRows)",
        )
      }),
      unit.it("ReadyForQuery is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.ReadyForQuery(Idle))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.ReadyForQuery,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: ReadyForQuery, step: ReadingExecuteRows)",
        )
      }),
      unit.it("RowDescription is UnexpectedServerMessage", fn() {
        // Act and assert
        driver_errors.unexpected_message(message.RowDescription([]))
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.RowDescription,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: RowDescription, step: ReadingExecuteRows)",
        )
      }),
    ]),
    unit.group("protocol phases", [
      unit.it("AwaitingParseComplete is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingParseComplete,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingParseComplete,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingParseComplete)",
        )
      }),
      unit.it("AwaitingParameterDescription is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingParameterDescription,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingParameterDescription,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingParameterDescription)",
        )
      }),
      unit.it("AwaitingStatementColumns is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingStatementColumns,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingStatementColumns,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingStatementColumns)",
        )
      }),
      unit.it("AwaitingBindComplete is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingBindComplete,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingBindComplete,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingBindComplete)",
        )
      }),
      unit.it("AwaitingPortalColumns is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingPortalColumns,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingPortalColumns,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingPortalColumns)",
        )
      }),
      unit.it("ReadingExecuteRows is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(query_step.ReadingExecuteRows)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.ReadingExecuteRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: ReadingExecuteRows)",
        )
      }),
      unit.it("AwaitingStatementResult is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingStatementResult,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingStatementResult,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingStatementResult)",
        )
      }),
      unit.it("ReadingSqlRows is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.ReadingSimpleQueryRows,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.ReadingSqlRows,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: ReadingSqlRows)",
        )
      }),
      unit.it("ReadingCopyOut is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(query_step.ReadingCopyOut)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.ReadingCopyOut,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: ReadingCopyOut)",
        )
      }),
      unit.it("AwaitingCopyComplete is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingCopyComplete,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingCopyComplete,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingCopyComplete)",
        )
      }),
      unit.it("AwaitingReadyForQuery is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingReadyForQuery,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingReadyForQuery,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingReadyForQuery)",
        )
      }),
      unit.it("AwaitingReadyForQueryAfterError is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingReadyForQueryAfterError,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingReadyForQueryAfterError,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingReadyForQueryAfterError)",
        )
      }),
      unit.it("AwaitingCloseComplete is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(
          query_step.AwaitingCloseComplete,
        )
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.AwaitingCloseComplete,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: AwaitingCloseComplete)",
        )
      }),
      unit.it("CopyingIn is the step", fn() {
        // Act and assert
        driver_errors.unexpected_message_in_phase(query_step.CopyingIn)
        |> should
        |> map_request_failure()
        |> be_equal(error.UnexpectedServerMessage(
          message: error.NoData,
          step: error.CopyingIn,
        ))
        |> or_fail_with(
          "Expected UnexpectedServerMessage(message: NoData, step: CopyingIn)",
        )
      }),
    ]),
    unit.group("encode errors", [
      unit.it("ZeroByteInString(\"query\") is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(message.ZeroByteInString(
          "query",
        ))
        |> should
        |> map_run_error()
        |> be_equal(error.RequestNotWritable(error.ZeroByteInString("query")))
        |> or_fail_with(
          "Expected RequestNotWritable(ZeroByteInString(\"query\"))",
        )
      }),
      unit.it("TooManyItems(\"parameters\", 70000) is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(message.TooManyItems(
          "parameters",
          70_000,
        ))
        |> should
        |> map_run_error()
        |> be_equal(
          error.RequestNotWritable(error.TooManyItems("parameters", 70_000)),
        )
        |> or_fail_with(
          "Expected RequestNotWritable(TooManyItems(\"parameters\", 70000))",
        )
      }),
      unit.it("NumberOutOfRange(\"type OID\", -1) is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(message.NumberOutOfRange(
          "type OID",
          -1,
        ))
        |> should
        |> map_run_error()
        |> be_equal(
          error.RequestNotWritable(error.NumberOutOfRange("type OID", -1)),
        )
        |> or_fail_with(
          "Expected RequestNotWritable(NumberOutOfRange(\"type OID\", -1))",
        )
      }),
      unit.it("SecretKeyLengthOutOfRange(2) is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(
          message.SecretKeyLengthOutOfRange(2),
        )
        |> should
        |> map_run_error()
        |> be_equal(
          error.RequestNotWritable(error.SecretKeyLengthOutOfRange(2)),
        )
        |> or_fail_with(
          "Expected RequestNotWritable(SecretKeyLengthOutOfRange(2))",
        )
      }),
      unit.it("MessageTooLong(5000000000) is RequestNotWritable", fn() {
        // Act and assert
        connection_request_failure.RunUnencodable(message.MessageTooLong(
          5_000_000_000,
        ))
        |> should
        |> map_run_error()
        |> be_equal(
          error.RequestNotWritable(error.MessageTooLong(5_000_000_000)),
        )
        |> or_fail_with(
          "Expected RequestNotWritable(MessageTooLong(5000000000))",
        )
      }),
    ]),
    unit.group("catalog errors", [
      unit.it("UnknownType(90000) maps", fn() {
        // Act and assert
        catalog.UnknownType(90_000)
        |> should
        |> map_catalog_error()
        |> be_equal(error.UnknownType(90_000))
        |> or_fail_with("Expected UnknownType(90000)")
      }),
      unit.it(
        "LoadFailed(HousekeepingFailed(DeadlinePassed(False))) maps",
        fn() {
          // Act and assert
          catalog.LoadFailed(
            connection_request_failure.HousekeepingFailed(
              connection_request_failure.DeadlinePassed(False),
            ),
          )
          |> should
          |> map_catalog_error()
          |> be_equal(error.QueryTimeout(stopped_on_server: False))
          |> or_fail_with("Expected QueryTimeout(stopped_on_server: False)")
        },
      ),
      unit.it(
        "LoadFailed(HousekeepingNotConnected(TransportRefused(ConnectRefused))) maps",
        fn() {
          // Act and assert
          catalog.LoadFailed(
            connection_request_failure.HousekeepingNotConnected(
              connection_event.TransportRefused(transport.ConnectRefused),
            ),
          )
          |> should
          |> map_catalog_error()
          |> be_equal(
            error.ConnectFailed(error.ConnectionRefused(
              host: "db.example",
              port: 5432,
            )),
          )
          |> or_fail_with(
            "Expected ConnectFailed(ConnectionRefused) for db.example on port 5432",
          )
        },
      ),
      unit.it("LoadFailed(HousekeepingRefused(report, Idle)) maps", fn() {
        // Act and assert
        catalog.LoadFailed(connection_request_failure.HousekeepingRefused(
          server_reports.administrator_shutdown(),
          Idle,
        ))
        |> should
        |> map_catalog_error()
        |> be_equal(
          error.Server(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with("Expected the report as a Server reason")
      }),
      unit.it("LoadFailed(HousekeepingAnswerUnexpected) maps", fn() {
        // Act and assert
        catalog.LoadFailed(
          connection_request_failure.HousekeepingAnswerUnexpected,
        )
        |> should
        |> map_catalog_error()
        |> be_equal(error.UnreadableCatalog(error.UnexpectedCatalogAnswer))
        |> or_fail_with("Expected UnreadableCatalog(UnexpectedCatalogAnswer)")
      }),
      unit.it("CatalogProcessDown maps", fn() {
        // Act and assert
        catalog.CatalogProcessDown
        |> should
        |> map_catalog_error()
        |> be_equal(error.CatalogProcessDown)
        |> or_fail_with("Expected CatalogProcessDown")
      }),
      unit.it("UnreadableCatalog(UnreadableRow([Text(\"x\")])) maps", fn() {
        // Act and assert
        catalog.UnreadableCatalog(catalog_table.UnreadableRow([Text(<<"x">>)]))
        |> should
        |> map_catalog_error()
        |> be_equal(
          error.UnreadableCatalog(error.UnreadableRow([Text(<<"x">>)])),
        )
        |> or_fail_with(
          "Expected UnreadableCatalog(UnreadableRow([Text(<<\"x\">>)]))",
        )
      }),
      unit.it("UnreadableCatalog(UnknownTypeKind(90000, \"x\")) maps", fn() {
        // Act and assert
        catalog.UnreadableCatalog(catalog_table.UnknownTypeKind(90_000, "x"))
        |> should
        |> map_catalog_error()
        |> be_equal(error.UnreadableCatalog(error.UnknownTypeKind(90_000, "x")))
        |> or_fail_with(
          "Expected UnreadableCatalog(UnknownTypeKind(90000, \"x\"))",
        )
      }),
      unit.it("UnreadableCatalog(MissingPart(90000, 90001)) maps", fn() {
        // Act and assert
        catalog.UnreadableCatalog(catalog_table.MissingPart(90_000, 90_001))
        |> should
        |> map_catalog_error()
        |> be_equal(error.UnreadableCatalog(error.MissingPart(90_000, 90_001)))
        |> or_fail_with("Expected UnreadableCatalog(MissingPart(90000, 90001))")
      }),
      unit.it("UnreadableCatalog(CircularDomain(90000)) maps", fn() {
        // Act and assert
        catalog.UnreadableCatalog(catalog_table.CircularDomain(90_000))
        |> should
        |> map_catalog_error()
        |> be_equal(error.UnreadableCatalog(error.CircularDomain(90_000)))
        |> or_fail_with("Expected UnreadableCatalog(CircularDomain(90000))")
      }),
    ]),
    unit.group("checkout errors", [
      unit.it("a checkout timeout", fn() {
        // Act and assert
        pool_failure.HoldDeadlinePassed
        |> should
        |> map_checkout_error("db", 5432)
        |> be_equal(error.NoConnection)
        |> or_fail_with("Expected NoConnection")
      }),
      unit.it("a failed connect", fn() {
        // Act and assert
        pool_failure.ConnectFailed(connection_event.SetupTimedOut)
        |> should
        |> map_checkout_error("db", 5432)
        |> be_equal(error.ConnectFailed(error.SetupTimedOut))
        |> or_fail_with("Expected ConnectFailed(SetupTimedOut)")
      }),
      unit.it("a stopped pool", fn() {
        // Act and assert
        pool_failure.PoolStopped
        |> should
        |> map_checkout_error("db", 5432)
        |> be_equal(error.PoolStopped)
        |> or_fail_with("Expected PoolStopped")
      }),
      unit.it("a pool with no database", fn() {
        // Act and assert
        pool_failure.NoDatabase
        |> should
        |> map_checkout_error("db", 5432)
        |> be_equal(error.PoolHasNoDatabase)
        |> or_fail_with("Expected PoolHasNoDatabase")
      }),
    ]),
    unit.group("pool start errors", [
      unit.it("an invalid size", fn() {
        // Act and assert
        pool_failure.InvalidSize(0)
        |> should
        |> map_pool_start_error()
        |> be_equal(error.InvalidConfig(error.InvalidPoolSize(0)))
        |> or_fail_with("Expected InvalidConfig(InvalidPoolSize(0))")
      }),
      unit.it("an invalid health check interval", fn() {
        // Act and assert
        pool_failure.InvalidHealthCheckInterval(0)
        |> should
        |> map_pool_start_error()
        |> be_equal(error.InvalidConfig(error.InvalidHealthCheckInterval(0)))
        |> or_fail_with("Expected InvalidConfig(InvalidHealthCheckInterval(0))")
      }),
      unit.it("an init timeout", fn() {
        // Act and assert
        pool_failure.PoolProcessStartFailed(actor.InitTimeout)
        |> should
        |> map_pool_start_error()
        |> be_equal(error.PoolStartFailed(error.PoolStartTimedOut))
        |> or_fail_with("Expected PoolStartFailed(PoolStartTimedOut)")
      }),
      unit.it("a failed init", fn() {
        // Act and assert
        pool_failure.PoolProcessStartFailed(actor.InitFailed("no supervisor"))
        |> should
        |> map_pool_start_error()
        |> be_equal(
          error.PoolStartFailed(error.PoolInitFailed("no supervisor")),
        )
        |> or_fail_with(
          "Expected PoolStartFailed(PoolInitFailed(\"no supervisor\"))",
        )
      }),
      unit.it("a normal exit", fn() {
        // Act and assert
        pool_failure.PoolProcessStartFailed(actor.InitExited(process.Normal))
        |> should
        |> map_pool_start_error()
        |> be_equal(error.PoolStartFailed(error.PoolProcessExited("normal")))
        |> or_fail_with(
          "Expected PoolStartFailed(PoolProcessExited(\"normal\"))",
        )
      }),
      unit.it("a kill", fn() {
        // Act and assert
        pool_failure.PoolProcessStartFailed(actor.InitExited(process.Killed))
        |> should
        |> map_pool_start_error()
        |> be_equal(error.PoolStartFailed(error.PoolProcessExited("killed")))
        |> or_fail_with(
          "Expected PoolStartFailed(PoolProcessExited(\"killed\"))",
        )
      }),
      unit.it("an abnormal exit", fn() {
        // Act and assert
        pool_failure.PoolProcessStartFailed(
          actor.InitExited(process.Abnormal(dynamic.string("boom"))),
        )
        |> should
        |> map_pool_start_error()
        |> be_equal(error.PoolStartFailed(error.PoolProcessExited("\"boom\"")))
        |> or_fail_with(
          "Expected PoolStartFailed(PoolProcessExited(\"\\\"boom\\\"\"))",
        )
      }),
    ]),
    unit.group("config errors", [
      unit.it("an invalid host", fn() {
        // Act and assert
        transport.InvalidHost("a b")
        |> should
        |> map_address_fault()
        |> be_equal(error.InvalidHost("a b"))
        |> or_fail_with("Expected InvalidHost(\"a b\")")
      }),
      unit.it("an invalid port", fn() {
        // Act and assert
        transport.InvalidPort(0)
        |> should
        |> map_address_fault()
        |> be_equal(error.InvalidPort(0))
        |> or_fail_with("Expected InvalidPort(0)")
      }),
      unit.it("an empty user", fn() {
        // Act and assert
        login_config.EmptyUser
        |> should
        |> map_login_config_fault()
        |> be_equal(error.EmptyUser)
        |> or_fail_with("Expected EmptyUser")
      }),
      unit.it("a zero byte in the password", fn() {
        // Act and assert
        login_config.ZeroByteInPassword
        |> should
        |> map_login_config_fault()
        |> be_equal(error.ZeroByteInPassword)
        |> or_fail_with("Expected ZeroByteInPassword")
      }),
      unit.it("a zero byte in a parameter", fn() {
        // Act and assert
        login_config.ZeroByteInParameter("a")
        |> should
        |> map_login_config_fault()
        |> be_equal(error.ZeroByteInParameter("a"))
        |> or_fail_with("Expected ZeroByteInParameter(\"a\")")
      }),
      unit.it("an empty parameter name", fn() {
        // Act and assert
        login_config.EmptyParameterName
        |> should
        |> map_login_config_fault()
        |> be_equal(error.EmptyParameterName)
        |> or_fail_with("Expected EmptyParameterName")
      }),
      unit.it("a duplicate parameter", fn() {
        // Act and assert
        login_config.DuplicateParameter("a")
        |> should
        |> map_login_config_fault()
        |> be_equal(error.DuplicateParameter("a"))
        |> or_fail_with("Expected DuplicateParameter(\"a\")")
      }),
      unit.it("a startup message that is too long", fn() {
        // Act and assert
        login_config.StartupMessageTooLong(2_147_483_648)
        |> should
        |> map_login_config_fault()
        |> be_equal(error.StartupMessageTooLong(2_147_483_648))
        |> or_fail_with("Expected StartupMessageTooLong(2147483648)")
      }),
      unit.it("an encoding other than UTF-8", fn() {
        // Act and assert
        login_config.UnsupportedClientEncoding("LATIN1")
        |> should
        |> map_login_config_fault()
        |> be_equal(error.UnsupportedClientEncoding("LATIN1"))
        |> or_fail_with("Expected UnsupportedClientEncoding(\"LATIN1\")")
      }),
    ]),
    unit.group("connect errors", [
      unit.it("a refused connect", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ConnectRefused)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ConnectionRefused("db", 5432))
        |> or_fail_with("Expected ConnectionRefused(\"db\", 5432)")
      }),
      unit.it("a connect timeout", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ConnectTimedOut)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ConnectTimedOut("db", 5432))
        |> or_fail_with("Expected ConnectTimedOut(\"db\", 5432)")
      }),
      unit.it("a failed DNS lookup", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.DnsLookupFailed(
          "db.example",
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.HostNotFound("db.example"))
        |> or_fail_with("Expected HostNotFound(\"db.example\")")
      }),
      unit.it("a failed TLS handshake", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.TlsFailed(
          transport.UnknownAuthority,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.UnknownAuthority))
        |> or_fail_with("Expected TlsFailed(UnknownAuthority)")
      }),
      unit.it("a server with no TLS", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ServerRefusedTls)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.ServerHasNoTls))
        |> or_fail_with("Expected TlsFailed(ServerHasNoTls)")
      }),
      unit.it("a TLS request answered with an error", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.TlsRequestAnsweredWithError)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.TlsRequestAnsweredWithError))
        |> or_fail_with("Expected TlsFailed(TlsRequestAnsweredWithError)")
      }),
      unit.it("an unexpected TLS answer", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.UnexpectedTlsAnswer(88))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.UnexpectedTlsAnswer(88)))
        |> or_fail_with("Expected TlsFailed(UnexpectedTlsAnswer(88))")
      }),
      unit.it("bytes before TLS", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.BytesBeforeTls)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.BytesBeforeTlsHandshake))
        |> or_fail_with("Expected TlsFailed(BytesBeforeTlsHandshake)")
      }),
      unit.it("a server that closed the connect", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ConnectClosed)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ConnectClosed("db", 5432))
        |> or_fail_with("Expected ConnectClosed(\"db\", 5432)")
      }),
      unit.it("a reset of the connect", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ConnectReset)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ConnectReset("db", 5432))
        |> or_fail_with("Expected ConnectReset(\"db\", 5432)")
      }),
      unit.it("a socket that failed during the login", fn() {
        // Act and assert
        connection_event.LoginSocketFailed(transport.SocketClosed)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ConnectionBroke(error.ClosedByServer))
        |> or_fail_with("Expected ConnectionBroke(ClosedByServer)")
      }),
      unit.it("a send timeout during the login", fn() {
        // Act and assert
        connection_event.LoginSendFailed(transport.SendTimedOut)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.LoginSendFailed(error.SendTimedOut))
        |> or_fail_with("Expected LoginSendFailed(SendTimedOut)")
      }),
      unit.it("an error of the operating system", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.ConnectUnlisted(
          "ehostunreach",
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.OsRefused(posix.Ehostunreach))
        |> or_fail_with("Expected OsRefused(Ehostunreach)")
      }),
      unit.it("a failed send during the login", fn() {
        // Act and assert
        connection_event.LoginSendFailed(transport.SendFailed(
          transport.ConnectionReset,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.LoginSendFailed(error.Reset))
        |> or_fail_with("Expected LoginSendFailed(Reset)")
      }),
      unit.it("channel binding with no TLS", fn() {
        // Act and assert
        connection_event.LoginRequiresTls
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ChannelBindingRequiresTls)
        |> or_fail_with("Expected ChannelBindingRequiresTls")
      }),
      unit.it("a host name mismatch", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.TlsFailed(
          transport.HostNameMismatch,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.CertificateHostMismatch))
        |> or_fail_with("Expected TlsFailed(CertificateHostMismatch)")
      }),
      unit.it("an expired certificate", fn() {
        // Act and assert
        connection_event.TransportRefused(transport.TlsFailed(
          transport.CertificateExpired,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.CertificateExpired))
        |> or_fail_with("Expected TlsFailed(CertificateExpired)")
      }),
      unit.it("an unreadable authority file", fn() {
        // Act and assert
        connection_event.TransportRefused(
          transport.TlsFailed(transport.AuthorityFileUnreadable(
            "ca.pem",
            "enoent",
          )),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(
          error.TlsFailed(error.AuthorityFileUnreadable("ca.pem", "enoent")),
        )
        |> or_fail_with(
          "Expected TlsFailed(AuthorityFileUnreadable(\"ca.pem\", \"enoent\"))",
        )
      }),
      unit.it("an empty authority file", fn() {
        // Act and assert
        connection_event.TransportRefused(
          transport.TlsFailed(transport.AuthorityFileEmpty("ca.pem")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.AuthorityFileEmpty("ca.pem")))
        |> or_fail_with("Expected TlsFailed(AuthorityFileEmpty(\"ca.pem\"))")
      }),
      unit.it("another TLS failure", fn() {
        // Act and assert
        connection_event.TransportRefused(
          transport.TlsFailed(transport.OtherTlsFailure("handshake_failure")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.TlsFailed(error.TlsAlert("handshake_failure")))
        |> or_fail_with("Expected TlsFailed(TlsAlert(\"handshake_failure\"))")
      }),
      unit.it("an undecodable login message", fn() {
        // Act and assert
        connection_event.LoginUndecodable(message.UnknownMessageType(1))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UndecodableLoginMessage(error.UnknownMessageType(1)))
        |> or_fail_with(
          "Expected UndecodableLoginMessage(UnknownMessageType(1))",
        )
      }),
      unit.it("a setup timeout", fn() {
        // Act and assert
        connection_event.SetupTimedOut
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.SetupTimedOut)
        |> or_fail_with("Expected SetupTimedOut")
      }),
      unit.it("an exit during the setup", fn() {
        // Act and assert
        connection_event.SetupExited
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.SetupProcessExited)
        |> or_fail_with("Expected SetupProcessExited")
      }),
    ]),
    unit.group("login errors", [
      unit.it("a refused login", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ServerRejectedLogin(server_reports.administrator_shutdown()),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(
          error.LoginRefused(
            error.server_error_from_report(
              server_reports.administrator_shutdown(),
            ),
          ),
        )
        |> or_fail_with(
          "Expected LoginRefused(server_error_from_report(report()))",
        )
      }),
      unit.it("an unexpected login message", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnexpectedMessage(message.NoData))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnexpectedLoginMessage(error.NoData))
        |> or_fail_with("Expected UnexpectedLoginMessage(NoData)")
      }),
      unit.it("an unsupported trust login", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedLoginMethod(
          login.TrustLogin,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("trust"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"trust\")")
      }),
      unit.it("an unsupported cleartext login", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedLoginMethod(
          login.CleartextLogin,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("cleartext password"))
        |> or_fail_with(
          "Expected UnsupportedLoginMethod(\"cleartext password\")",
        )
      }),
      unit.it("an unsupported SCRAM mechanism", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.UnsupportedLoginMethod(login.ScramLogin("SCRAM-SHA-1")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("SCRAM-SHA-1"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"SCRAM-SHA-1\")")
      }),
      unit.it("an unsupported SASL login", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.UnsupportedLoginMethod(login.SaslLogin(["A", "B"])),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("SASL (A, B)"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"SASL (A, B)\")")
      }),
      unit.it("an unsupported Kerberos login", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedLoginMethod(
          login.KerberosV5Login,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("Kerberos V5"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"Kerberos V5\")")
      }),
      unit.it("an unsupported GSSAPI login", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedLoginMethod(
          login.GssLogin,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("GSSAPI"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"GSSAPI\")")
      }),
      unit.it("an unsupported SSPI login", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedLoginMethod(
          login.SspiLogin,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedLoginMethod("SSPI"))
        |> or_fail_with("Expected UnsupportedLoginMethod(\"SSPI\")")
      }),
      unit.it("a missing password", fn() {
        // Act and assert
        connection_event.LoginRefused(login.PasswordRequired(login.Md5Login))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.PasswordRequired("MD5"))
        |> or_fail_with("Expected PasswordRequired(\"MD5\")")
      }),
      unit.it("a password with a zero byte", fn() {
        // Act and assert
        connection_event.LoginRefused(login.PasswordHasZeroByte)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.PasswordHasZeroByte)
        |> or_fail_with("Expected PasswordHasZeroByte")
      }),
      unit.it("channel binding not offered", fn() {
        // Act and assert
        connection_event.LoginRefused(login.ChannelBindingNotOffered(
          login.Md5Login,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ChannelBindingNotOffered("MD5"))
        |> or_fail_with("Expected ChannelBindingNotOffered(\"MD5\")")
      }),
      unit.it("channel binding offered with no TLS", fn() {
        // Act and assert
        connection_event.LoginRefused(login.ChannelBindingOfferedWithoutTls)
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ChannelBindingOfferedWithoutTls)
        |> or_fail_with("Expected ChannelBindingOfferedWithoutTls")
      }),
      unit.it("an invalid certificate", fn() {
        // Act and assert
        connection_event.LoginRefused(login.CertificateHashFailed(
          channel_binding.InvalidCertificate,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.CertificateHashFailed(error.InvalidCertificate))
        |> or_fail_with("Expected CertificateHashFailed(InvalidCertificate)")
      }),
      unit.it("an unsupported signature algorithm", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.CertificateHashFailed(
            channel_binding.UnsupportedSignatureAlgorithm([1, 3, 101, 112]),
          ),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(
          error.CertificateHashFailed(
            error.UnsupportedSignatureAlgorithm([1, 3, 101, 112]),
          ),
        )
        |> or_fail_with(
          "Expected CertificateHashFailed(UnsupportedSignatureAlgorithm([1, 3, 101, 112]))",
        )
      }),
      unit.it("an unsupported protocol version", fn() {
        // Act and assert
        connection_event.LoginRefused(login.UnsupportedProtocolVersion(3, 9))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.UnsupportedProtocolVersion(3, 9))
        |> or_fail_with("Expected UnsupportedProtocolVersion(3, 9)")
      }),
      unit.it("an invalid server-first-message", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.InvalidServerFirstMessage(<<"x">>)),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.InvalidServerFirstMessage(<<"x">>)))
        |> or_fail_with(
          "Expected ScramFailed(InvalidServerFirstMessage(<<\"x\">>))",
        )
      }),
      unit.it("a mandatory extension", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.MandatoryExtension("m")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.MandatoryExtension("m")))
        |> or_fail_with("Expected ScramFailed(MandatoryExtension(\"m\"))")
      }),
      unit.it("a server nonce that is too long", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.ServerNonceTooLong(5000)),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.ServerNonceTooLong(5000)))
        |> or_fail_with("Expected ScramFailed(ServerNonceTooLong(5000))")
      }),
      unit.it("a password that is too long", fn() {
        // Act and assert
        connection_event.LoginRefused(login.PasswordTooLong(5000))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.PasswordTooLong(5000))
        |> or_fail_with("Expected PasswordTooLong(5000)")
      }),
      unit.it("a nonce mismatch", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.ServerNonceMismatch("abc")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.ServerNonceMismatch("abc")))
        |> or_fail_with("Expected ScramFailed(ServerNonceMismatch(\"abc\"))")
      }),
      unit.it("an invalid salt", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.InvalidSalt("!")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.InvalidSalt("!")))
        |> or_fail_with("Expected ScramFailed(InvalidSalt(\"!\"))")
      }),
      unit.it("an invalid iteration count", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFirstFailed(scram.InvalidIterationCount("0")),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.InvalidIterationCount("0")))
        |> or_fail_with("Expected ScramFailed(InvalidIterationCount(\"0\"))")
      }),
      unit.it("an invalid server-final-message", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFinalFailed(scram.InvalidServerFinalMessage(<<"x">>)),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.InvalidServerFinalMessage(<<"x">>)))
        |> or_fail_with(
          "Expected ScramFailed(InvalidServerFinalMessage(<<\"x\">>))",
        )
      }),
      unit.it("an error of the server", fn() {
        // Act and assert
        connection_event.LoginRefused(
          login.ScramServerFinalFailed(scram.ServerReportedError(
            "invalid-proof",
          )),
        )
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(
          error.ScramFailed(error.ServerReportedError("invalid-proof")),
        )
        |> or_fail_with(
          "Expected ScramFailed(ServerReportedError(\"invalid-proof\"))",
        )
      }),
      unit.it("a signature mismatch", fn() {
        // Act and assert
        connection_event.LoginRefused(login.ScramServerFinalFailed(
          scram.ServerSignatureMismatch,
        ))
        |> should
        |> map_connect_failure("db", 5432)
        |> be_equal(error.ScramFailed(error.ServerSignatureMismatch))
        |> or_fail_with("Expected ScramFailed(ServerSignatureMismatch)")
      }),
    ]),
  ])
}
