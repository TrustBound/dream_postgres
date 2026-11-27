//// Interceptors: the outcome builders and the chain of the runners with
//// no server, then the chain of the client on PostgreSQL 16 to 19.

import dream_postgres.{
  affected, all, commit, named, one, query, script, secret_parameter, single,
  step, transaction, with_interceptor,
}
import dream_postgres/codec
import dream_postgres/error.{
  ColumnTypeMismatch, InterceptorFailed, ParameterTypeMismatch, UnknownType,
}
import dream_postgres/interceptor.{
  ScriptAnswer, StatementAnswer, column, command, connection_lost, refuse, rows,
  server_error, timeout,
}
import dream_postgres/internal/cell.{
  CommandResult, StatementDescription, TypeDescription,
}
import dream_postgres/internal/runner
import dream_postgres/sql_state.{DeadlockDetected}
import dream_postgres/transaction.{keep_both}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, contain_string, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import fixtures/client_statements
import fixtures/column_description
import fixtures/fake_executor
import fixtures/interceptors
import fixtures/no_database
import fixtures/posts
import fixtures/server_pools
import fixtures/server_versions
import gleam/erlang/process
import gleam/function
import gleam/list
import matchers/have_cause.{have_cause}
import matchers/have_kind_name.{have_kind_name}
import matchers/have_message.{have_message}
import matchers/have_reason.{have_reason}
import matchers/leave_rows.{leave_rows}
import matchers/not_contain_text.{not_contain_text}
import matchers/receive_message.{receive_message}
import matchers/run_on_configured_pool.{run_on_configured_pool}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_with_table.{run_with_table}

/// The outcome builders, and the chain of the runners on a fake executor.
pub fn unit_tests() -> TestSuite {
  unit.describe("interceptors with no server", [
    unit.it("rows refuses a field that its column type does not take", fn() {
      // Act and assert
      rows([column("id", "text")], [[codec.field(codec.int, 1)]])
      |> should
      |> be_error()
      |> be_equal(ParameterTypeMismatch(
        position: 1,
        database_type: "text",
        codec: "int",
      ))
      |> or_fail_with("Expected the int field to be refused for text")
    }),
    unit.it("command gives the row count of its tag to affected", fn() {
      // Act and assert
      runner.affected(
        posts.query(),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [interceptors.answer_with(command("UPDATE 3"))],
      )
      |> should
      |> be_ok()
      |> be_equal(3)
      |> or_fail_with("Expected the row count 3 of the tag UPDATE 3")
    }),
    unit.it("a simulated timeout is a timeout", fn() {
      // Act and assert
      runner.all(
        posts.query(),
        posts.reader(),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [interceptors.answer_with(Error(timeout()))],
      )
      |> should
      |> be_error()
      |> have_kind_name()
      |> be_equal("timeout")
      |> or_fail_with("Expected the simulated timeout to be timeout")
    }),
    unit.it("a simulated lost connection is unavailable", fn() {
      // Act and assert
      runner.all(
        posts.query(),
        posts.reader(),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [interceptors.answer_with(Error(connection_lost()))],
      )
      |> should
      |> be_error()
      |> have_kind_name()
      |> be_equal("unavailable")
      |> or_fail_with(
        "Expected the simulated lost connection to be unavailable",
      )
    }),
    unit.it("string.inspect of a request marks a secret parameter", fn() {
      // Act and assert
      query("SELECT $1")
      |> secret_parameter(codec.text, "hunter2")
      |> one(
        single(codec.text),
        with_interceptor(
          no_database.connection(),
          interceptors.refuse_with_request_text(),
        ),
      )
      |> should
      |> be_error()
      |> have_message()
      |> contain_string("Secret")
      |> or_fail_with("Expected the secret mark in the request text")
    }),
    unit.it("string.inspect of a request holds no secret value", fn() {
      // Act and assert
      query("SELECT $1")
      |> secret_parameter(codec.text, "hunter2")
      |> one(
        single(codec.text),
        with_interceptor(
          no_database.connection(),
          interceptors.refuse_with_request_text(),
        ),
      )
      |> should
      |> be_error()
      |> have_message()
      |> not_contain_text("hunter2")
      |> or_fail_with("Expected no secret value in the request text")
    }),
    unit.it("the answer of a script to a statement is refused", fn() {
      // Act and assert
      runner.all(
        posts.query(),
        posts.reader(),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [interceptors.answer_with(Ok(ScriptAnswer(results: [])))],
      )
      |> should
      |> be_error()
      |> have_cause()
      |> have_reason()
      |> be_equal(InterceptorFailed(
        reason: "an interceptor answered a statement with the answer of another kind of request",
      ))
      |> or_fail_with("Expected a script answer to a statement to be refused")
    }),
    unit.it("an answer with no type for its column gives UnknownType", fn() {
      // Act and assert
      runner.all(
        posts.query(),
        single(codec.int),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [
          interceptors.answer_with(
            Ok(StatementAnswer(
              description: StatementDescription(parameters: [], columns: [
                column_description.new("id", 99),
              ]),
              types: [],
              result: CommandResult(rows: [], tag: "SELECT 0", count: 0),
            )),
          ),
        ],
      )
      |> should
      |> be_error()
      |> have_cause()
      |> have_reason()
      |> be_equal(UnknownType(type_id: 99))
      |> or_fail_with("Expected UnknownType for the column type 99")
    }),
    unit.it("an answer reads with the types it gives", fn() {
      // Act and assert
      runner.one(
        posts.query(),
        single(codec.int),
        runner.DatabaseLayer(fake_executor.returning(posts.statement(), [])),
        [
          interceptors.answer_with(
            Ok(StatementAnswer(
              description: StatementDescription(parameters: [], columns: [
                column_description.new("id", 99),
              ]),
              types: [
                TypeDescription(
                  id: 99,
                  schema: "pg_catalog",
                  name: "int4",
                  kind: cell.Base,
                ),
              ],
              result: CommandResult(
                rows: [[cell.Binary(<<5:size(32)>>)]],
                tag: "SELECT 1",
                count: 1,
              ),
            )),
          ),
        ],
      )
      |> should
      |> be_ok()
      |> be_equal(5)
      |> or_fail_with("Expected the cell of the answer read as 5")
    }),
  ])
}

/// The chain of the client on each driver server.
pub fn tests() -> TestSuite {
  describe(
    "interceptors on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        it(
          "interceptors change the SQL in the order they were added",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(fn(connection) {
              query("SELECT 'x'::text")
              |> one(
                single(codec.text),
                connection
                  |> with_interceptor(interceptors.append_to_sql(" || 'a'"))
                  |> with_interceptor(interceptors.append_to_sql(" || 'b'")),
              )
            })
            |> be_ok()
            |> be_equal("xab")
            |> or_fail_with("Expected the first interceptor to change it first")
          },
        ),
        it("a changed SQL is still checked against the codecs", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT 1")
            |> one(
              single(codec.int),
              with_interceptor(
                connection,
                interceptors.replace_sql("SELECT 'one'::text AS word"),
              ),
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(ColumnTypeMismatch(
            position: 1,
            name: "word",
            database_type: "text",
            codec: "int",
          ))
          |> or_fail_with("Expected the changed SQL to fail the int reader")
        }),
        it("an interceptor of the config changes the SQL", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_configured_pool(
            dream_postgres.intercept(_, interceptors.append_to_sql(" || 'a'")),
            fn(connection) {
              query("SELECT 'x'::text") |> one(single(codec.text), connection)
            },
          )
          |> be_ok()
          |> be_equal("xa")
          |> or_fail_with("Expected the interceptor of the config to run")
        }),
        it("an interceptor that watches sees the outcome", fn(pools) {
          // Arrange
          let seen = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT generate_series(1, 2)")
            |> affected(with_interceptor(
              connection,
              interceptors.send_tags_to(seen),
            ))
          })
          |> receive_message(seen, within: 1000)
          |> be_equal(Ok("SELECT 2"))
          |> or_fail_with("Expected the watcher to see the tag SELECT 2")
        }),
        it("an interceptor watches a script", fn(pools) {
          // Arrange
          let seen = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            script(
              "SELECT 1; SELECT 2",
              with_interceptor(connection, interceptors.send_tags_to(seen)),
            )
          })
          |> receive_message(seen, within: 1000)
          |> be_equal(Ok("SELECT 1, SELECT 1"))
          |> or_fail_with("Expected the watcher to see both tags")
        }),
        it("an interceptor answers without the database", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT id, title FROM no_such_table")
            |> named("post.list")
            |> all(
              posts.reader(),
              with_interceptor(
                connection,
                interceptors.answer_with(
                  rows([column("id", "int4"), column("title", "text")], [
                    [
                      codec.field(codec.int, 1),
                      codec.field(codec.text, "First"),
                    ],
                    [
                      codec.field(codec.int, 2),
                      codec.field(codec.text, "Second"),
                    ],
                  ]),
                ),
              ),
            )
          })
          |> be_ok()
          |> be_equal([#(1, "First"), #(2, "Second")])
          |> or_fail_with("Expected the two rows of the interceptor")
        }),
        it("an interceptor refuses a query", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            client_statements.insert(
              with_interceptor(
                connection,
                interceptors.answer_with(Error(refuse("read only"))),
              ),
              "no_such_table",
              1,
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(InterceptorFailed(reason: "read only"))
          |> or_fail_with("Expected the refusal of the interceptor")
        }),
        it("the statement answer to a script is refused", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            script(
              "SELECT 1",
              with_interceptor(
                connection,
                interceptors.answer_with(command("SELECT 1")),
              ),
            )
          })
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(InterceptorFailed(
            reason: "an interceptor answered a script with the answer of another kind of request",
          ))
          |> or_fail_with("Expected a statement answer to a script refused")
        }),
        it("a simulated deadlock is retry", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT 1")
            |> named("post.create")
            |> one(
              single(codec.int),
              with_interceptor(
                connection,
                interceptors.fail_named(
                  "post.create",
                  server_error(DeadlockDetected, "deadlock detected"),
                ),
              ),
            )
          })
          |> be_error()
          |> have_kind_name()
          |> be_equal("retry")
          |> or_fail_with("Expected the simulated deadlock to be retry")
        }),
        it("a simulated error in a transaction rolls it back", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("intercepted_rows", fn(held) {
            transaction(
              with_interceptor(
                held,
                interceptors.fail_named(
                  "post.create",
                  server_error(DeadlockDetected, "deadlock detected"),
                ),
              ),
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(client_statements.insert(_, "intercepted_rows", 1))
            |> step(fn(transaction_connection) {
              query("INSERT INTO intercepted_rows (id) VALUES (2)")
              |> named("post.create")
              |> affected(transaction_connection)
            })
            |> commit
          })
          |> leave_rows([])
          |> be_error()
          |> have_kind_name()
          |> be_equal("retry")
          |> or_fail_with("Expected the rollback and the deadlock as retry")
        }),
      ])
    }),
  )
}
