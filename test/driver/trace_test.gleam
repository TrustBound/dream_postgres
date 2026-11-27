//// Proves the OpenTelemetry span of each statement: its name, its kind,
//// its attributes by the semantic conventions for PostgreSQL, its status
//// on a failure, and that no parameter value is ever recorded. A test
//// tracer records the spans of the test's own process only.

import dream_postgres/driver/connection.{
  type Connection, type DriverError, CopyNotRunning, ScriptFailed,
  ServerEndedConnection, ServerRefused, copy_from, copy_to, error_name, named,
  prepare, run, run_script, statement,
}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/trace.{SpanQuery, SpanTarget, Worked}
import dream_postgres/internal/cell.{Idle, Text}
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{describe, it}
import driver/server_connection.{connection_setup}
import driver/servers.{database, first_driver_server}
import driver/test_tracer.{
  RecordedSpan, install_test_tracer, next_span, record_spans_here,
}
import fixtures/copy_callbacks.{collect_row, send_then_fail}
import fixtures/expected_failure.{expect_failure}
import fixtures/server_report.{server_report}
import gleam/option.{None}
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}

/// The tests of the spans of statements.
pub fn tests() -> TestSuite {
  install_test_tracer()
  suite.group("the span of a statement", [
    statement_tests(),
    copy_tests(),
    span_tests(),
    error_name_tests(),
  ])
}

fn error_name_tests() -> TestSuite {
  let report = server_report("ERROR", "42P01", "no such table")
  unit.describe("the name of an error", [
    error_name_test(ServerRefused(report, Idle), "ServerRefused"),
    error_name_test(ScriptFailed([], report, Idle), "ScriptFailed"),
    error_name_test(ServerEndedConnection(report), "ServerEndedConnection"),
    error_name_test(CopyNotRunning, "CopyNotRunning"),
  ])
}

fn error_name_test(error: DriverError, name: String) {
  unit.it("is " <> name <> " for " <> inspect(error), fn() {
    error_name(error)
    |> should
    |> be_equal(name)
    |> or_fail_with("Expected the constructor's name")
  })
}

const port = "5441"

fn statement_tests() -> TestSuite {
  describe("of a statement", connection_setup(first_driver_server), [
    it("is named after the statement's name", fn(connection: Connection) {
      {
        record_spans_here()
        use _outcome <- try(
          run(
            connection,
            statement("SELECT $1::text") |> named("greeting.read"),
            [Text(<<"hello">>)],
            [],
            5000,
          )
          |> map_error(inspect),
        )
        next_span()
      }
      |> should
      |> be_equal(
        Ok(RecordedSpan(
          name: "greeting.read",
          kind: "client",
          attributes: [
            #("db.namespace", database),
            #("db.operation.name", "SELECT"),
            #("db.query.summary", "greeting.read"),
            #("db.query.text", "SELECT $1::text"),
            #("db.system.name", "postgresql"),
            #("server.address", "localhost"),
            #("server.port", port),
          ],
          failed: False,
        )),
      )
      |> or_fail_with("Expected the span of the named statement")
    }),
    it("records no parameter value", fn(connection: Connection) {
      {
        record_spans_here()
        use _outcome <- try(
          run(
            connection,
            statement("SELECT $1::text"),
            [Text(<<"a-secret-value">>)],
            [],
            5000,
          )
          |> map_error(inspect),
        )
        next_span()
      }
      |> should
      |> be_equal(
        Ok(RecordedSpan(
          name: database,
          kind: "client",
          attributes: [
            #("db.namespace", database),
            #("db.operation.name", "SELECT"),
            #("db.query.text", "SELECT $1::text"),
            #("db.system.name", "postgresql"),
            #("server.address", "localhost"),
            #("server.port", port),
          ],
          failed: False,
        )),
      )
      |> or_fail_with("Expected no attribute with the parameter's value")
    }),
    it(
      "of a script records no text, and the operation of its statement",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _outcomes <- try(
            run_script(connection, statement("SELECT 'a-literal'"), 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.operation.name", "SELECT"),
              #("db.system.name", "postgresql"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: False,
          )),
        )
        |> or_fail_with("Expected the operation and no text")
      },
    ),
    it(
      "of a script of two statements records no operation",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _outcomes <- try(
            run_script(connection, statement("SELECT 1; SELECT 2"), 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.system.name", "postgresql"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: False,
          )),
        )
        |> or_fail_with("Expected no operation for two statements")
      },
    ),
    it(
      "of a prepare records the text and no operation",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _description <- try(
            prepare(connection, statement("SELECT $1::int"), 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.query.text", "SELECT $1::int"),
              #("db.system.name", "postgresql"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: False,
          )),
        )
        |> or_fail_with("Expected the span of the prepare")
      },
    ),
    it(
      "of a refused statement has its SQLSTATE and the status Error",
      fn(connection: Connection) {
        {
          record_spans_here()
          use Nil <- try(
            expect_failure(run(
              connection,
              statement("SELECT * FROM no_such_table"),
              [],
              [],
              5000,
            )),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.query.text", "SELECT * FROM no_such_table"),
              #("db.response.status_code", "42P01"),
              #("db.system.name", "postgresql"),
              #("error.type", "42P01"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: True,
          )),
        )
        |> or_fail_with("Expected the span of the refused statement")
      },
    ),
    it(
      "of a request that fails in the driver has the error's name",
      fn(connection: Connection) {
        {
          record_spans_here()
          use Nil <- try(
            expect_failure(prepare(
              connection,
              statement("SELECT '\u{0000}'"),
              5000,
            )),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.query.text", "SELECT '\u{0000}'"),
              #("db.system.name", "postgresql"),
              #("error.type", "InvalidRequest"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: True,
          )),
        )
        |> or_fail_with("Expected the span of the invalid request")
      },
    ),
    it(
      "shares one prepared statement between two names of one text",
      fn(connection: Connection) {
        {
          use _first <- try(
            run(
              connection,
              statement("SELECT 'shared'") |> named("first.name"),
              [],
              [],
              5000,
            )
            |> map_error(inspect),
          )
          use _second <- try(
            run(
              connection,
              statement("SELECT 'shared'") |> named("second.name"),
              [],
              [],
              5000,
            )
            |> map_error(inspect),
          )
          run(
            connection,
            statement(
              "SELECT count(*)::text FROM pg_prepared_statements WHERE statement = 'SELECT ''shared'''",
            ),
            [],
            [],
            5000,
          )
          |> map_error(inspect)
        }
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"1">>)]])
        |> or_fail_with("Expected one prepared statement for the two names")
      },
    ),
  ])
}

fn copy_tests() -> TestSuite {
  describe("of a COPY", connection_setup(first_driver_server), [
    it("of a COPY TO records the operation COPY", fn(connection: Connection) {
      {
        record_spans_here()
        use _rows <- try(
          copy_to(
            connection,
            statement("COPY (SELECT 1) TO STDOUT"),
            5000,
            [],
            collect_row,
          )
          |> map_error(inspect),
        )
        next_span()
      }
      |> should
      |> be_equal(
        Ok(RecordedSpan(
          name: database,
          kind: "client",
          attributes: [
            #("db.namespace", database),
            #("db.operation.name", "COPY"),
            #("db.query.text", "COPY (SELECT 1) TO STDOUT"),
            #("db.system.name", "postgresql"),
            #("server.address", "localhost"),
            #("server.port", port),
          ],
          failed: False,
        )),
      )
      |> or_fail_with("Expected the span of the COPY TO")
    }),
    it(
      "of a COPY whose function failed has the error AppFailed",
      fn(connection: Connection) {
        {
          use _created <- try(
            run_script(
              connection,
              statement("CREATE TEMP TABLE IF NOT EXISTS traced_rows (x text)"),
              5000,
            )
            |> map_error(inspect),
          )
          record_spans_here()
          use Nil <- try(
            expect_failure(copy_from(
              connection,
              statement("COPY traced_rows FROM STDIN"),
              5000,
              send_then_fail,
            )),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.query.text", "COPY traced_rows FROM STDIN"),
              #("db.system.name", "postgresql"),
              #("error.type", "AppFailed"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: True,
          )),
        )
        |> or_fail_with("Expected the span of the failed COPY")
      },
    ),
  ])
}

fn span_tests() -> TestSuite {
  unit.describe("of a target", [
    unit.it("leaves out the default port", fn() {
      {
        record_spans_here()
        trace.start(
          SpanTarget(database: "app", host: "db.example.com", port: 5432),
          SpanQuery(summary: None, text: None),
        )
        |> trace.end(Worked(operation: None))
        next_span()
      }
      |> should
      |> be_equal(
        Ok(RecordedSpan(
          name: "app",
          kind: "client",
          attributes: [
            #("db.namespace", "app"),
            #("db.system.name", "postgresql"),
            #("server.address", "db.example.com"),
          ],
          failed: False,
        )),
      )
      |> or_fail_with("Expected no server.port for 5432")
    }),
    unit.it("names the user's database for an empty database", fn() {
      login.new(
        user: "app_user",
        database: "",
        password: login.no_password(),
        parameters: [],
        channel_binding: PreferChannelBinding,
        protocol_version: Protocol30,
      )
      |> result.map(login.database)
      |> should
      |> be_equal(Ok("app_user"))
      |> or_fail_with("Expected the user's name as the database")
    }),
  ])
}
