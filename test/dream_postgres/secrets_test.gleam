//// The secrets of a config, on text and on the rows of answers, with no
//// database.

import dream_postgres/codecs
import dream_postgres/driver/cell.{Binary, Null, StatementDescription}
import dream_postgres/error.{SecretColumnNotReplaced}
import dream_postgres/pool.{named_connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/secrets
import dream_test/context
import dream_test/matchers.{be_equal, be_error, contain, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, group}
import driver/test_tracer.{install_test_tracer, record_spans_here, spans_now}
import fixtures/column_description
import fixtures/normalize_inputs
import fixtures/server_pools
import fixtures/server_versions
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import matchers/extract_span_attributes.{extract_span_attributes}
import matchers/have_cause.{have_cause}
import matchers/have_sql.{have_sql}
import matchers/run_on_configured_pool.{run_on_configured_pool}
import snippets/app_config.{app_config}

/// The secrets tests, with no database.
pub fn unit_tests() -> TestSuite {
  unit.describe("secrets", [
    unit.it("an error of a name that no pool has keeps no SQL", fn() {
      // Act and assert
      query("SELECT 'sk_live_1'")
      |> one(single(codecs.text), named_connection(process.new_name("no_pool")))
      |> should
      |> be_error()
      |> have_cause()
      |> have_sql()
      |> be_equal(None)
      |> or_fail_with("Expected no SQL, because the secrets are not known")
    }),
    unit.it("replace_text replaces each secret text in order", fn() {
      // Act and assert
      secrets.new()
      |> secrets.text("sk_live_", with: "sk_test_")
      |> secrets.text("sk_test_1", with: "one")
      |> secrets.replace_text("SELECT 'sk_live_1', 'sk_live_2'")
      |> should
      |> be_equal("SELECT 'one', 'sk_test_2'")
      |> or_fail_with("Expected both texts replaced in order")
    }),
    unit.it("replace_columns replaces the value of a secret column", fn() {
      // Act and assert
      secrets.new()
      |> secrets.column("token", codecs.text, with: "token-redacted")
      |> secrets.replace_columns(
        StatementDescription(parameters: [], columns: [
          column_description.new("id", 1),
          column_description.new("token", 1),
        ]),
        [normalize_inputs.type_named("text")],
        [[Binary(<<"7":utf8>>), Binary(<<"sk_live_abc":utf8>>)]],
      )
      |> should
      |> be_equal(
        Ok([[Binary(<<"7":utf8>>), Binary(<<"token-redacted":utf8>>)]]),
      )
      |> or_fail_with("Expected only the token replaced")
    }),
    unit.it("replace_columns leaves a NULL of a secret column", fn() {
      // Act and assert
      secrets.new()
      |> secrets.column("token", codecs.text, with: "token-redacted")
      |> secrets.replace_columns(
        StatementDescription(parameters: [], columns: [
          column_description.new("token", 1),
        ]),
        [normalize_inputs.type_named("text")],
        [[Null]],
      )
      |> should
      |> be_equal(Ok([[Null]]))
      |> or_fail_with("Expected the NULL as it was")
    }),
    unit.it("replace_columns refuses a codec that does not take the type", fn() {
      // Act and assert
      secrets.new()
      |> secrets.column("token", codecs.int, with: 1)
      |> secrets.replace_columns(
        StatementDescription(parameters: [], columns: [
          column_description.new("token", 1),
        ]),
        [normalize_inputs.type_named("text")],
        [],
      )
      |> should
      |> be_equal(
        Error(SecretColumnNotReplaced(
          column: "token",
          reason: "the codec int does not take the type text",
        )),
      )
      |> or_fail_with("Expected the codec refused")
    }),
    unit.it("replace_columns gives the reason a value cannot be written", fn() {
      // Act and assert
      secrets.new()
      |> secrets.column("small", codecs.int, with: 100_000)
      |> secrets.replace_columns(
        StatementDescription(parameters: [], columns: [
          column_description.new("small", 1),
        ]),
        [normalize_inputs.type_named("int2")],
        [],
      )
      |> should
      |> be_equal(
        Error(SecretColumnNotReplaced(
          column: "small",
          reason: "100000 is out of range for int2",
        )),
      )
      |> or_fail_with("Expected the value refused")
    }),
    unit.it(
      "replace_columns refuses a column whose type is not in the answer",
      fn() {
        // Act and assert
        secrets.new()
        |> secrets.column("token", codecs.text, with: "token-redacted")
        |> secrets.replace_columns(
          StatementDescription(parameters: [], columns: [
            column_description.new("token", 2),
          ]),
          [normalize_inputs.type_named("text")],
          [],
        )
        |> should
        |> be_equal(
          Error(SecretColumnNotReplaced(
            column: "token",
            reason: "the answer has no type for the column",
          )),
        )
        |> or_fail_with("Expected the missing type")
      },
    ),
  ])
}

/// The secrets of a config in the errors and the spans of a pool, on
/// PostgreSQL 16 to 19.
pub fn tests() -> TestSuite {
  unit_context.describe(
    "secrets on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        unit_context.it(
          "the SQL of an error has the text secrets replaced",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_configured_pool(app_config, fn(connection) {
              query("SELECT 'sk_live_1' +")
              |> one(single(codecs.text), connection)
            })
            |> be_error()
            |> have_cause()
            |> have_sql()
            |> be_equal(Some("SELECT 'sk_test_1' +"))
            |> or_fail_with("Expected sk_test_ in the SQL of the error")
          },
        ),
        unit_context.it(
          "the span text of a statement has the text secrets replaced",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_configured_pool(app_config, fn(connection) {
              install_test_tracer()
              record_spans_here()
              let _token =
                query("SELECT 'sk_live_1'")
                |> one(single(codecs.text), connection)
              spans_now()
            })
            |> extract_span_attributes()
            |> contain(#("db.query.text", "/* billing */ SELECT 'sk_test_1'"))
            |> or_fail_with("Expected sk_test_ in db.query.text")
          },
        ),
        unit_context.it("the app still gets the real values", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_configured_pool(app_config, fn(connection) {
            query("SELECT 'sk_live_1' AS token")
            |> one(single(codecs.text), connection)
          })
          |> be_equal(Ok("sk_live_1"))
          |> or_fail_with("Expected the live value")
        }),
      ])
    }),
  )
}
