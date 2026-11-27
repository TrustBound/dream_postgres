//// Proves the OpenTelemetry span of each statement: its name, its kind,
//// its attributes by the semantic conventions for PostgreSQL, its status
//// on a failure, and that no parameter value is ever recorded. A test
//// tracer records the spans of the test's own process only.

import dream_postgres/driver/catalog
import dream_postgres/driver/connection.{
  type Connection, copy_from, copy_to, named, prepare, run, run_script,
  statement,
}
import dream_postgres/driver/listener.{type Listener}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/pool
import dream_postgres/driver/trace.{SpanQuery, SpanTarget, Worked}
import dream_postgres/internal/cell.{Text}
import dream_test/context
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{describe, it}
import driver/proxy.{type Proxy, start_proxy, stop_proxy}
import driver/server_connection.{connection_setup}
import driver/server_listener.{start_listener, subscribe_to}
import driver/server_pool.{
  type ProxiedPool, health_check_config, start_proxied_pool, stop_proxied_pool,
  wait_for_member_free_count,
}
import driver/servers.{database, first_driver_server}
import driver/test_tracer.{
  type RecordedSpan, RecordedSpan, install_test_tracer, next_span,
  record_every_process_here, record_spans_here, spans_now, spans_on_ports,
  stop_recording_every_process,
}
import fixtures/copy_callbacks.{collect_row, send_then_fail}
import fixtures/expected_failure.{expect_failure}
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_span_attribute.{extract_span_attribute}
import matchers/extract_span_name.{extract_span_name}

/// The tests of the spans of statements.
pub fn tests() -> TestSuite {
  install_test_tracer()
  suite.group("the span of a statement", [
    statement_tests(),
    copy_tests(),
    span_tests(),
    housekeeping_tests(),
  ])
}

// The driver's own statements: one act -----------------------------------------

/// The spans of every process while a proxied pool runs health checks, a
/// proxied listener subscribes, the pool loads its catalog, and a caller
/// runs one statement through the pool. The proxies' ports tell these
/// spans from those of the tests that run at the same time.
type Housekeeping {
  Housekeeping(
    proxied: ProxiedPool,
    listener: Listener,
    listener_proxy: Proxy,
    spans: List(RecordedSpan),
  )
}

fn watch_housekeeping() -> Result(Housekeeping, String) {
  record_every_process_here()
  use proxied <- try(
    start_proxied_pool(first_driver_server, health_check_config(_, 20, 5000)),
  )
  use #(listener_port, listener_proxy) <- try(start_proxy(
    first_driver_server.port,
  ))
  use listener <- try(start_listener(listener_port, "svc828_listener", 10))
  use _subscription <- try(subscribe_to(
    listener,
    "svc828_channel",
    process.new_subject(),
  ))
  use Nil <- try(wait_for_member_free_count(proxied.pool_events, 3))
  use types <- try(pool.catalog(proxied.pool) |> map_error(inspect))
  use _int4 <- try(
    pool.hold(proxied.pool, 5000, catalog.describe(types, _, 23, 5000))
    |> map_error(inspect)
    |> result.map(map_error(_, inspect))
    |> result.flatten,
  )
  use _outcome <- try(
    pool.hold(proxied.pool, 5000, run(_, statement("SELECT 1"), [], [], 5000))
    |> map_error(inspect)
    |> result.map(map_error(_, inspect))
    |> result.flatten,
  )
  stop_recording_every_process()
  let ports = [to_string(proxied.proxy_port), to_string(listener_port)]
  Ok(Housekeeping(
    proxied:,
    listener:,
    listener_proxy:,
    spans: spans_on_ports(spans_now(), ports),
  ))
}

fn stop_housekeeping(outcome: Housekeeping) -> Result(Nil, String) {
  listener.stop(outcome.listener)
  stop_proxy(outcome.listener_proxy)
  stop_proxied_pool(outcome.proxied)
}

fn housekeeping_tests() -> TestSuite {
  describe(
    "of the driver's own statements",
    context.setup(setup: watch_housekeeping, teardown: stop_housekeeping),
    [
      it(
        "leaves only the caller's statement with a span",
        fn(outcome: Housekeeping) {
          outcome.spans
          |> should
          |> be_equal([
            RecordedSpan(
              name: "SELECT " <> database,
              kind: "client",
              attributes: [
                #("db.namespace", database),
                #("db.operation.name", "SELECT"),
                #("db.query.text", "SELECT 1"),
                #("db.system.name", "postgresql"),
                #("server.address", "localhost"),
                #("server.port", to_string(outcome.proxied.proxy_port)),
              ],
              failed: False,
            ),
          ])
          |> or_fail_with("Expected one span, of the caller's statement")
        },
      ),
    ],
  )
}

const port = "5441"

/// A statement that raises one warning, of the default code 01000.
const warning_sql = "DO $$BEGIN RAISE WARNING 'late'; END$$"

/// A statement that raises the warnings 01003 and 01004, then a notice of
/// the code 00000.
const several_warnings_sql =
  "DO $$BEGIN RAISE WARNING 'first' USING ERRCODE = '01003'; RAISE WARNING 'second' USING ERRCODE = '01004'; RAISE NOTICE 'plain'; END$$"

/// A statement that raises a warning, then fails.
const warns_then_fails_sql =
  "DO $$BEGIN RAISE WARNING 'disk almost full'; RAISE EXCEPTION 'boom'; END$$"

/// A statement that raises a notice of the code 00000 only.
const notice_sql = "DO $$BEGIN RAISE NOTICE 'plain'; END$$"

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
    it(
      "records a warning's code as its status code and stays OK",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _outcome <- try(
            run(connection, statement(warning_sql), [], [], 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_equal(
          Ok(RecordedSpan(
            name: "DO " <> database,
            kind: "client",
            attributes: [
              #("db.namespace", database),
              #("db.operation.name", "DO"),
              #("db.query.text", warning_sql),
              #("db.response.status_code", "01000"),
              #("db.system.name", "postgresql"),
              #("server.address", "localhost"),
              #("server.port", port),
            ],
            failed: False,
          )),
        )
        |> or_fail_with("Expected the code 01000 and no failure")
      },
    ),
    it(
      "records the code of the last of several warnings",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _outcome <- try(
            run(connection, statement(several_warnings_sql), [], [], 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_ok
        |> extract_span_attribute(key: "db.response.status_code")
        |> be_equal(Some("01004"))
        |> or_fail_with("Expected the code of the last warning, 01004")
      },
    ),
    it(
      "records no status code for a notice that is no warning",
      fn(connection: Connection) {
        {
          record_spans_here()
          use _outcome <- try(
            run(connection, statement(notice_sql), [], [], 5000)
            |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_ok
        |> extract_span_attribute(key: "db.response.status_code")
        |> be_equal(None)
        |> or_fail_with("Expected no status code for the code 00000")
      },
    ),
    it(
      "records no warning of a failed statement on the next statement",
      fn(connection: Connection) {
        {
          record_spans_here()
          use Nil <- try(
            expect_failure(run(
              connection,
              statement(warns_then_fails_sql),
              [],
              [],
              5000,
            )),
          )
          use _outcome <- try(
            run(connection, statement("SELECT 1"), [], [], 5000)
            |> map_error(inspect),
          )
          use _failed_span <- try(next_span())
          next_span()
        }
        |> should
        |> be_ok
        |> extract_span_attribute(key: "db.response.status_code")
        |> be_equal(None)
        |> or_fail_with("Expected no status code on the SELECT")
      },
    ),
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
          name: "SELECT " <> database,
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
            name: "SELECT " <> database,
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
              #("error.type", "PrepareUnencodable"),
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
          name: "COPY " <> database,
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
        |> trace.end(Worked(operation: None, warning_code: None))
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
    unit.it("without a summary is named after its operation and target", fn() {
      {
        record_spans_here()
        trace.start(
          SpanTarget(database: "app", host: "db.example.com", port: 5432),
          SpanQuery(summary: None, text: None),
        )
        |> trace.end(Worked(operation: Some("INSERT"), warning_code: None))
        next_span()
      }
      |> should
      |> be_ok
      |> extract_span_name
      |> be_equal("INSERT app")
      |> or_fail_with("Expected the name INSERT app")
    }),
    unit.it("with a summary keeps the summary as its name", fn() {
      {
        record_spans_here()
        trace.start(
          SpanTarget(database: "app", host: "db.example.com", port: 5432),
          SpanQuery(summary: Some("user.create"), text: None),
        )
        |> trace.end(Worked(operation: Some("INSERT"), warning_code: None))
        next_span()
      }
      |> should
      |> be_ok
      |> extract_span_name
      |> be_equal("user.create")
      |> or_fail_with("Expected the summary as the name")
    }),
    unit.it("with an empty operation keeps its target as its name", fn() {
      {
        record_spans_here()
        trace.start(
          SpanTarget(database: "app", host: "db.example.com", port: 5432),
          SpanQuery(summary: None, text: None),
        )
        |> trace.end(Worked(operation: Some(""), warning_code: None))
        next_span()
      }
      |> should
      |> be_ok
      |> extract_span_name
      |> be_equal("app")
      |> or_fail_with("Expected the target as the name")
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
