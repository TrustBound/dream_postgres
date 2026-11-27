//// Proves the span text of a statement: the span of each call records it
//// as `db.query.text`, while the server runs the real SQL, and the
//// statement cache keys by the real SQL. Each span text here is not SQL
//// that the server could run, so a call that works ran the real SQL.

import dream_postgres/driver/connection.{
  type Connection, copy_from, copy_to, describe_current, prepare, run,
  run_simple_query, span_text, statement,
}
import dream_postgres/internal/cell.{Text}
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{describe, it}
import driver/server_connection.{connection_setup}
import driver/servers.{first_driver_server}
import driver/test_tracer.{install_test_tracer, next_span, record_spans_here}
import fixtures/copy_callbacks.{collect_row, send_three_rows}
import gleam/option.{Some}
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_span_attribute.{extract_span_attribute}

/// The tests of the span text.
pub fn tests() -> TestSuite {
  install_test_tracer()
  describe(
    "the span text of a statement",
    connection_setup(first_driver_server),
    [
      it("is the query text of the span of a run", fn(connection: Connection) {
        {
          record_spans_here()
          use _outcome <- try(
            run(connection, secret_select(), [], [], 5000) |> map_error(inspect),
          )
          next_span()
        }
        |> should
        |> be_ok
        |> extract_span_attribute(key: "db.query.text")
        |> be_equal(Some("SELECT ?"))
        |> or_fail_with("Expected the span text, not the SQL")
      }),
      it(
        "leaves the real SQL to the server in a run",
        fn(connection: Connection) {
          run(connection, secret_select(), [], [], 5000)
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"span-text-secret":utf8>>)]])
          |> or_fail_with("Expected the value of the real SQL")
        },
      ),
      it(
        "is the query text of the span of a prepare",
        fn(connection: Connection) {
          {
            record_spans_here()
            use _description <- try(
              prepare(connection, secret_select(), 5000) |> map_error(inspect),
            )
            next_span()
          }
          |> should
          |> be_ok
          |> extract_span_attribute(key: "db.query.text")
          |> be_equal(Some("SELECT ?"))
          |> or_fail_with("Expected the span text on the prepare")
        },
      ),
      it(
        "is the query text of the span of a describe_current",
        fn(connection: Connection) {
          {
            record_spans_here()
            use _description <- try(
              describe_current(connection, secret_select(), 5000)
              |> map_error(inspect),
            )
            next_span()
          }
          |> should
          |> be_ok
          |> extract_span_attribute(key: "db.query.text")
          |> be_equal(Some("SELECT ?"))
          |> or_fail_with("Expected the span text on the describe_current")
        },
      ),
      it(
        "is the query text of the span of a simple query",
        fn(connection: Connection) {
          {
            record_spans_here()
            use _outcomes <- try(
              run_simple_query(connection, secret_select(), 5000)
              |> map_error(inspect),
            )
            next_span()
          }
          |> should
          |> be_ok
          |> extract_span_attribute(key: "db.query.text")
          |> be_equal(Some("SELECT ?"))
          |> or_fail_with("Expected the span text on the simple query")
        },
      ),
      it(
        "is the query text of the span of a COPY TO",
        fn(connection: Connection) {
          {
            record_spans_here()
            use _rows <- try(
              copy_to(
                connection,
                statement("COPY (SELECT 'span-text-secret') TO STDOUT")
                  |> span_text(text: "COPY (?) TO STDOUT"),
                5000,
                [],
                collect_row,
              )
              |> map_error(inspect),
            )
            next_span()
          }
          |> should
          |> be_ok
          |> extract_span_attribute(key: "db.query.text")
          |> be_equal(Some("COPY (?) TO STDOUT"))
          |> or_fail_with("Expected the span text on the COPY TO")
        },
      ),
      it(
        "is the query text of the span of a COPY FROM",
        fn(connection: Connection) {
          {
            use _created <- try(
              run_simple_query(
                connection,
                statement(
                  "CREATE TEMP TABLE IF NOT EXISTS span_text_rows (n int, w text)",
                ),
                5000,
              )
              |> map_error(inspect),
            )
            record_spans_here()
            use _count <- try(
              copy_from(
                connection,
                statement("COPY span_text_rows FROM STDIN")
                  |> span_text(text: "COPY ? FROM STDIN"),
                5000,
                send_three_rows,
              )
              |> map_error(inspect),
            )
            next_span()
          }
          |> should
          |> be_ok
          |> extract_span_attribute(key: "db.query.text")
          |> be_equal(Some("COPY ? FROM STDIN"))
          |> or_fail_with("Expected the span text on the COPY FROM")
        },
      ),
      it("keys the statement cache by the real SQL", fn(connection: Connection) {
        {
          use _first <- try(
            run(
              connection,
              statement(cache_key_sql) |> span_text(text: "first span text"),
              [],
              [],
              5000,
            )
            |> map_error(inspect),
          )
          use _second <- try(
            run(
              connection,
              statement(cache_key_sql) |> span_text(text: "second span text"),
              [],
              [],
              5000,
            )
            |> map_error(inspect),
          )
          run(connection, statement(count_cache_key_statements), [], [], 5000)
          |> map_error(inspect)
        }
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"1":utf8>>)]])
        |> or_fail_with("Expected one server statement for both span texts")
      }),
    ],
  )
}

/// A SELECT of a value that its span text does not hold.
fn secret_select() {
  statement("SELECT 'span-text-secret'") |> span_text(text: "SELECT ?")
}

/// The SQL of the two runs that differ only in their span texts.
const cache_key_sql = "SELECT 'span-text-cache-key'"

/// Counts the server's prepared statements of `cache_key_sql`.
const count_cache_key_statements =
  "SELECT count(*)::text FROM pg_prepared_statements WHERE statement = 'SELECT ''span-text-cache-key'''"
