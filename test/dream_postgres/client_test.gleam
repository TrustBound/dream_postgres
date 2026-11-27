//// The public client on PostgreSQL 16 to 19: the config, the pool
//// runners, `with_connection`, `run_sql` and transactions.
////
//// Each server has one pool for all of its tests. A test that writes rows
//// holds one connection with `with_connection` and makes its own
//// temporary table on it, so no table stays on the server.

import dream_errors.{Invalid, Unavailable}
import dream_postgres.{
  affected, all, check, column, column_at, column_named, commit, isolation,
  maybe_one, named, one, parameter, query, read_only, row, run, run_sql, single,
  step, step_with, transaction, with_connection, with_interceptor,
}
import dream_postgres/codec
import dream_postgres/error
import dream_postgres/transaction.{
  ReadCommitted, RepeatableRead, Serializable, keep_both,
}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import fixtures/client_statements
import fixtures/interceptors
import fixtures/server_pools
import fixtures/server_reports
import fixtures/server_versions
import fixtures/transfer_error.{DatabaseFailed, NotEnough, RollbackFailed}
import gleam/bool
import gleam/function
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import matchers/be_database_failed.{be_database_failed}
import matchers/have_kind_name.{have_kind_name}
import matchers/leave_rows.{leave_rows}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_on_started_pool.{run_on_started_pool}
import matchers/run_on_stopped_pool.{run_on_stopped_pool}
import matchers/run_with_table.{run_with_table}
import matchers/summarise_error.{summarise_error}
import matchers/summarise_errors.{summarise_errors}

/// The client on each driver server, with one pool for each server.
pub fn tests() -> TestSuite {
  describe(
    "the client on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        it("all reads every row on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT generate_series(1, $1)")
            |> parameter(codec.int, 3)
            |> all(single(codec.int), connection)
          })
          |> be_ok()
          |> be_equal([1, 2, 3])
          |> or_fail_with("Expected the rows 1, 2 and 3")
        }),
        it("one reads a row of two columns on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT 7, 'seven'::text")
            |> named("seven")
            |> one(
              {
                use number <- column(codec.int)
                use name <- column(codec.text)
                row(#(number, name))
              },
              connection,
            )
          })
          |> be_ok()
          |> be_equal(#(7, "seven"))
          |> or_fail_with("Expected the row 7 and seven")
        }),
        it("column_at and column_named read some of the columns", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT 1 AS first, 'two'::text AS second, 3 AS third")
            |> one(
              {
                use third <- column_at(3, codec.int)
                use second <- column_named("second", codec.text)
                row(#(third, second))
              },
              connection,
            )
          })
          |> be_ok()
          |> be_equal(#(3, "two"))
          |> or_fail_with("Expected the third column 3 and the second two")
        }),
        it("maybe_one gives None for no row on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT 1 WHERE false")
            |> maybe_one(single(codec.int), connection)
          })
          |> be_ok()
          |> be_none()
          |> or_fail_with("Expected None for a query with no row")
        }),
        it("affected gives the row count of the tag on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            query("SELECT generate_series(1, 4)") |> affected(connection)
          })
          |> be_ok()
          |> be_equal(4)
          |> or_fail_with("Expected the row count 4 of the tag SELECT 4")
        }),
        it("a query that the server refuses gives its error", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(client_statements.divide_by_zero)
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid 22012")
          |> or_fail_with("Expected the division by zero as invalid 22012")
        }),
        it("with_connection runs each call on one connection", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("held_rows", fn(held) {
            use _inserted <- result.try(client_statements.insert(
              held,
              "held_rows",
              1,
            ))
            // A nested with_connection gets the same connection.
            use inner <- result.try(
              with_connection(held, fn(inner) {
                client_statements.ids(inner, "held_rows")
              })
              |> result.flatten,
            )
            dream_postgres.stop(held)
            Ok(inner)
          })
          |> leave_rows([1])
          |> be_ok()
          |> be_equal([1])
          |> or_fail_with("Expected the nested call to read the inserted row")
        }),
        it("run_sql runs several statements", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            run_sql("SELECT 1; SELECT 2", connection)
          })
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with(
            "Expected both statements of the `run_sql` call to run",
          )
        }),
        it("run_sql gives the error of a failed statement", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            run_sql("SELECT 1; SELECT 1 / 0", connection)
          })
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid SqlStatementFailed 1 22012")
          |> or_fail_with(
            "Expected the division by zero of the `run_sql` call after 1 statement",
          )
        }),
        it("run_sql rolls back every statement when one fails", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            with_connection(connection, fn(held) {
              #(
                run_sql(
                  "CREATE TEMPORARY TABLE run_sql_rolled_back (id int4); SELECT 1 / 0",
                  held,
                )
                  |> result.is_error,
                query(
                  "SELECT to_regclass('pg_temp.run_sql_rolled_back') IS NULL",
                )
                  |> one(single(codec.bool), held),
              )
            })
          })
          |> be_ok()
          |> be_equal(#(True, Ok(True)))
          |> or_fail_with("Expected the failed call to leave no table behind")
        }),
        it("every call on a stopped pool is Unavailable", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_stopped_pool(fn(connection) {
            [
              query("SELECT 1")
                |> all(single(codec.int), connection)
                |> result.replace(Nil),
              run_sql("SELECT 1", connection),
              with_connection(connection, fn(_held) { Nil }),
              transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
                |> step(client_statements.divide_by_zero)
                |> commit
                |> result.replace(Nil),
              {
                use _transaction_connection <- run(transaction(
                  connection,
                  database: function.identity,
                  rollback_also_failed: keep_both,
                ))
                Ok(Nil)
              },
              transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
                |> step(client_statements.divide_by_zero)
                |> commit
                |> result.replace(Nil),
            ]
          })
          |> summarise_errors()
          |> be_equal(list.repeat("unavailable PoolStopped", 6))
          |> or_fail_with("Expected each of the six calls to be unavailable")
        }),
        it("commit keeps the work of every step", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("committed_rows", fn(held) {
            transaction(
              held,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(client_statements.insert(_, "committed_rows", 1))
            |> step(client_statements.insert(_, "committed_rows", 2))
            |> commit
          })
          |> leave_rows([1, 2])
          |> be_ok()
          |> be_equal(1)
          |> or_fail_with("Expected both rows kept after the commit")
        }),
        it("commit on a pool commits on one held connection", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              connection,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(fn(transaction_connection) {
              run_sql(
                "CREATE TEMPORARY TABLE pooled_rows (id int4) ON COMMIT DROP",
                transaction_connection,
              )
            })
            |> step(client_statements.insert(_, "pooled_rows", 5))
            |> step(client_statements.ids(_, "pooled_rows"))
            |> commit
          })
          |> be_ok()
          |> be_equal([5])
          |> or_fail_with("Expected each step to see the table of the first")
        }),
        it("a step error rolls every step back", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("step_error_rows", fn(held) {
            transaction(
              held,
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            )
            |> step(client_statements.insert(_, "step_error_rows", 1))
            |> step(client_statements.divide_by_zero)
            |> step(client_statements.insert(_, "step_error_rows", 2))
            |> commit
          })
          |> leave_rows([])
          |> be_error()
          |> be_database_failed()
          |> summarise_error()
          |> be_equal("invalid 22012")
          |> or_fail_with("Expected the division by zero and no row kept")
        }),
        it("a check error rolls every step back", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("check_error_rows", fn(held) {
            transaction(
              held,
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            )
            |> step(client_statements.insert(_, "check_error_rows", 1))
            |> check(transfer_error.require_more_than(_, 1))
            |> step(client_statements.insert(_, "check_error_rows", 2))
            |> commit
          })
          |> leave_rows([])
          |> be_error()
          |> be_equal(Invalid("too few rows", NotEnough(found: 1)))
          |> or_fail_with("Expected NotEnough 1 and no row kept")
        }),
        it("a check that passes gives its value to the next step", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              connection,
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            )
            |> step(fn(transaction_connection) {
              query("SELECT 5")
              |> one(single(codec.int), transaction_connection)
            })
            |> check(transfer_error.require_more_than(_, 1))
            |> step_with(fn(transaction_connection, found) {
              query("SELECT $1 * 10")
              |> parameter(codec.int, found)
              |> one(single(codec.int), transaction_connection)
            })
            |> commit
          })
          |> be_ok()
          |> be_equal(50)
          |> or_fail_with("Expected 5 to pass the check and give 50")
        }),
        it("step_with gives the value of the step before it", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("step_with_rows", fn(held) {
            transaction(
              held,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(fn(transaction_connection) {
              query("SELECT 4")
              |> one(single(codec.int), transaction_connection)
            })
            |> step_with(fn(transaction_connection, id) {
              client_statements.insert(
                transaction_connection,
                "step_with_rows",
                id * 2,
              )
            })
            |> commit
          })
          |> leave_rows([8])
          |> be_ok()
          |> be_equal(1)
          |> or_fail_with("Expected the row 8 from the value 4")
        }),
        it("each isolation level is the level of the transaction", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            list.map([ReadCommitted, RepeatableRead, Serializable], fn(level) {
              transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> isolation(level)
              |> step(client_statements.setting(_, "transaction_isolation"))
              |> commit
            })
          })
          |> be_equal([
            Ok("read committed"),
            Ok("repeatable read"),
            Ok("serializable"),
          ])
          |> or_fail_with("Expected each level as the transaction isolation")
        }),
        it("read_only with an isolation level sets both", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              connection,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> isolation(RepeatableRead)
            |> read_only
            |> step(client_statements.setting(_, "transaction_isolation"))
            |> step_with(fn(transaction_connection, level) {
              client_statements.setting(
                transaction_connection,
                "transaction_read_only",
              )
              |> result.map(fn(read_only_setting) {
                #(level, read_only_setting)
              })
            })
            |> commit
          })
          |> be_ok()
          |> be_equal(#("repeatable read", "on"))
          |> or_fail_with("Expected repeatable read and read only on")
        }),
        it("a write in a read only transaction fails", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              connection,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> read_only
            |> step(run_sql(
              "CREATE TEMPORARY TABLE read_only_rows (id int4)",
              _,
            ))
            |> commit
          })
          |> be_error()
          |> summarise_error()
          |> be_equal("failed 25006")
          |> or_fail_with("Expected the write to fail with SQLSTATE 25006")
        }),
        it(
          "a swallowed statement error makes commit CommitRolledBack",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("swallowed_rows", fn(held) {
              transaction(
                held,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(client_statements.insert(_, "swallowed_rows", 1))
              |> step(fn(transaction_connection) {
                client_statements.divide_by_zero(transaction_connection)
                |> result.lazy_or(fn() { Ok(0) })
              })
              |> commit
            })
            |> leave_rows([])
            |> be_error()
            |> summarise_error()
            |> be_equal("failed CommitRolledBack 22012")
            |> or_fail_with("Expected the commit to roll back, and no row kept")
          },
        ),
        it("a serialization failure (40001) is Retry", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              connection,
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            )
            |> isolation(Serializable)
            |> step(run_sql(
              "DO $$ BEGIN RAISE EXCEPTION 'conflict' USING ERRCODE = 'serialization_failure'; END $$",
              _,
            ))
            |> commit
          })
          |> be_error()
          |> be_database_failed()
          |> summarise_error()
          |> be_equal("retry 40001")
          |> or_fail_with("Expected the serialization failure as retry 40001")
        }),
        it("run commits the branch that the callback takes", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("branch_rows", fn(held) {
            use transaction_connection <- run(transaction(
              held,
              database: function.identity,
              rollback_also_failed: keep_both,
            ))
            use found <- result.try(
              query("SELECT 2")
              |> one(single(codec.int), transaction_connection),
            )
            use <- bool.lazy_guard(when: found <= 1, return: fn() {
              client_statements.insert(transaction_connection, "branch_rows", 0)
            })
            client_statements.insert(
              transaction_connection,
              "branch_rows",
              found,
            )
          })
          |> leave_rows([2])
          |> be_ok()
          |> be_equal(1)
          |> or_fail_with("Expected the branch for 2 to insert and commit 2")
        }),
        it("run rolls back when the callback gives an error", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("run_error_rows", fn(held) {
            use transaction_connection <- run(transaction(
              held,
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            ))
            use _inserted <- result.try(
              client_statements.insert(
                transaction_connection,
                "run_error_rows",
                1,
              )
              |> result.map_error(dream_errors.map_cause(_, DatabaseFailed)),
            )
            Error(Invalid("too few rows", NotEnough(found: 1)))
          })
          |> leave_rows([])
          |> be_error()
          |> be_equal(Invalid("too few rows", NotEnough(found: 1)))
          |> or_fail_with("Expected NotEnough 1 and no row kept")
        }),
        it("a failed nested transaction undoes only its own work", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("nested_failed_rows", fn(held) {
            transaction(
              held,
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(client_statements.insert(_, "nested_failed_rows", 1))
            |> step(fn(transaction_connection) {
              transaction(
                transaction_connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(client_statements.insert(_, "nested_failed_rows", 2))
              |> step(client_statements.divide_by_zero)
              |> commit
              |> Ok
            })
            |> step_with(fn(transaction_connection, inner) {
              client_statements.insert(
                transaction_connection,
                "nested_failed_rows",
                3,
              )
              |> result.replace(inner)
            })
            |> commit
          })
          |> leave_rows([1, 3])
          |> be_ok()
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid 22012")
          |> or_fail_with("Expected the inner error, and the rows 1 and 3 kept")
        }),
        it(
          "a nested transaction that succeeds keeps its work, also two deep",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("nested_kept_rows", fn(held) {
              transaction(
                held,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(client_statements.insert(_, "nested_kept_rows", 1))
              |> step(fn(transaction_connection) {
                transaction(
                  transaction_connection,
                  database: function.identity,
                  rollback_also_failed: keep_both,
                )
                |> step(client_statements.insert(_, "nested_kept_rows", 2))
                |> step(fn(inner_connection) {
                  transaction(
                    inner_connection,
                    database: function.identity,
                    rollback_also_failed: keep_both,
                  )
                  |> step(client_statements.insert(_, "nested_kept_rows", 3))
                  |> commit
                })
                |> commit
              })
              |> commit
            })
            |> leave_rows([1, 2, 3])
            |> be_ok()
            |> be_equal(1)
            |> or_fail_with("Expected the rows 1, 2 and 3 kept")
          },
        ),
        it(
          "a swallowed error in a nested transaction rolls back only its savepoint",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("nested_swallowed_rows", fn(held) {
              transaction(
                held,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(client_statements.insert(_, "nested_swallowed_rows", 1))
              |> step(fn(transaction_connection) {
                transaction(
                  transaction_connection,
                  database: function.identity,
                  rollback_also_failed: keep_both,
                )
                |> step(client_statements.insert(_, "nested_swallowed_rows", 2))
                |> step(fn(inner_connection) {
                  client_statements.divide_by_zero(inner_connection)
                  |> result.lazy_or(fn() { Ok(0) })
                })
                |> commit
                |> Ok
              })
              |> commit
            })
            |> leave_rows([1])
            |> be_ok()
            |> be_error()
            |> summarise_error()
            |> be_equal("failed CommitRolledBack 22012")
            |> or_fail_with("Expected the inner rollback, and the row 1 kept")
          },
        ),
        it("a failed ROLLBACK after a check error keeps both errors", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              with_interceptor(connection, interceptors.refuse_rollback()),
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            )
            |> step(fn(transaction_connection) {
              query("SELECT 1")
              |> one(single(codec.int), transaction_connection)
            })
            |> check(transfer_error.require_more_than(_, 1))
            |> commit
          })
          |> be_error()
          |> be_equal(Unavailable(
            "the rollback after a failed step failed",
            RollbackFailed(
              step_error: Invalid("too few rows", NotEnough(found: 1)),
              rollback_error: error.PostgresError(
                query_name: None,
                sql: Some("ROLLBACK"),
                reason: error.InterceptorFailed("rollback refused"),
              ),
            ),
          ))
          |> or_fail_with(
            "Expected RollbackFailed with the check error and the rollback error",
          )
        }),
        it("run keeps both errors when the ROLLBACK fails", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            use _transaction_connection <- run(transaction(
              with_interceptor(connection, interceptors.refuse_rollback()),
              database: DatabaseFailed,
              rollback_also_failed: RollbackFailed,
            ))
            Error(Invalid("too few rows", NotEnough(found: 0)))
          })
          |> be_error()
          |> be_equal(Unavailable(
            "the rollback after a failed step failed",
            RollbackFailed(
              step_error: Invalid("too few rows", NotEnough(found: 0)),
              rollback_error: error.PostgresError(
                query_name: None,
                sql: Some("ROLLBACK"),
                reason: error.InterceptorFailed("rollback refused"),
              ),
            ),
          ))
          |> or_fail_with(
            "Expected RollbackFailed with the callback error and the rollback error",
          )
        }),
        it("keep_both joins a step error and a failed ROLLBACK", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            transaction(
              with_interceptor(connection, interceptors.refuse_rollback()),
              database: function.identity,
              rollback_also_failed: keep_both,
            )
            |> step(client_statements.divide_by_zero)
            |> commit
          })
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "unavailable RollbackAlsoFailed invalid 22012, then InterceptorFailed(\"rollback refused\")",
          )
          |> or_fail_with(
            "Expected the division by zero and the rollback error in one error",
          )
        }),
        it(
          "a failed ROLLBACK TO SAVEPOINT keeps both errors, and the outer transaction rolls back",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(fn(connection) {
              use transaction_connection <- run(transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              ))
              transaction(
                with_interceptor(
                  transaction_connection,
                  interceptors.refuse_rollback(),
                ),
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(client_statements.divide_by_zero)
              |> commit
            })
            |> be_error()
            |> summarise_error()
            |> be_equal(
              "unavailable RollbackAlsoFailed invalid 22012, then InterceptorFailed(\"rollback refused\")",
            )
            |> or_fail_with(
              "Expected the division by zero and the savepoint rollback error in one error",
            )
          },
        ),
        it(
          "a nested transaction cannot set an isolation level or read only",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(fn(connection) {
              transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(fn(transaction_connection) {
                Ok([
                  transaction(
                    transaction_connection,
                    database: function.identity,
                    rollback_also_failed: keep_both,
                  )
                    |> isolation(Serializable)
                    |> step(client_statements.setting(
                      _,
                      "transaction_isolation",
                    ))
                    |> commit,
                  transaction(
                    transaction_connection,
                    database: function.identity,
                    rollback_also_failed: keep_both,
                  )
                    |> read_only
                    |> step(client_statements.setting(
                      _,
                      "transaction_read_only",
                    ))
                    |> commit,
                ])
              })
              |> commit
            })
            |> be_ok()
            |> summarise_errors()
            |> be_equal(list.repeat("failed OptionsInNestedTransaction", 2))
            |> or_fail_with("Expected both nested options to be refused")
          },
        ),
        it(
          "a nested transaction after a swallowed error fails at its savepoint",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(fn(connection) {
              transaction(
                connection,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(fn(transaction_connection) {
                client_statements.divide_by_zero(transaction_connection)
                |> result.lazy_or(fn() { Ok(0) })
              })
              |> step(fn(transaction_connection) {
                transaction(
                  transaction_connection,
                  database: function.identity,
                  rollback_also_failed: keep_both,
                )
                |> step(client_statements.setting(_, "transaction_isolation"))
                |> commit
                |> Ok
              })
              |> commit
            })
            |> be_error()
            |> summarise_error()
            |> be_equal("failed CommitRolledBack 22012")
            |> or_fail_with("Expected the commit to roll back")
          },
        ),
      ])
    }),
  )
}

/// The config checks and the answers to COMMIT, with no server.
pub fn unit_tests() -> TestSuite {
  unit.describe("the client with no server", [
    unit.group("config", [
      unit.it("an empty host is InvalidConfig", fn() {
        // Act and assert
        dream_postgres.default_config()
        |> dream_postgres.host("")
        |> dream_postgres.start
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("invalid InvalidConfig(InvalidHost(\"\"))")
        |> or_fail_with("Expected the empty host to be refused")
      }),
      unit.it("a port of 0 is InvalidConfig", fn() {
        // Act and assert
        dream_postgres.default_config()
        |> dream_postgres.port(0)
        |> dream_postgres.start
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("invalid InvalidConfig(InvalidPort(0))")
        |> or_fail_with("Expected the port 0 to be refused")
      }),
      unit.it("an empty user is InvalidConfig", fn() {
        // Act and assert
        dream_postgres.default_config()
        |> dream_postgres.user("")
        |> dream_postgres.start
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("invalid InvalidConfig(EmptyUser)")
        |> or_fail_with("Expected the empty user to be refused")
      }),
      unit.it("a password with a zero byte is InvalidConfig", fn() {
        // Act and assert
        dream_postgres.default_config()
        |> dream_postgres.password("a\u{0000}b")
        |> dream_postgres.start
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("invalid InvalidConfig(ZeroByteInPassword)")
        |> or_fail_with("Expected the zero byte in the password to be refused")
      }),
      unit.it("a pool size of 0 is InvalidConfig", fn() {
        // Act and assert
        dream_postgres.default_config()
        |> dream_postgres.pool_size(0)
        |> dream_postgres.start
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("invalid InvalidConfig(InvalidPoolSize(0))")
        |> or_fail_with("Expected the pool size 0 to be refused")
      }),
    ]),
    unit.group("the answer to COMMIT", [
      unit.it("COMMIT is a commit", fn() {
        // Act and assert
        dream_postgres.commit_answer(["COMMIT"], None)
        |> should
        |> be_ok()
        |> be_equal(Nil)
        |> or_fail_with("Expected the tag COMMIT to be a commit")
      }),
      unit.it(
        "ROLLBACK is CommitRolledBack with the report that failed it",
        fn() {
          // Act and assert
          dream_postgres.commit_answer(
            ["ROLLBACK"],
            Some(
              error.server_error_from_report(server_reports.division_by_zero()),
            ),
          )
          |> should
          |> be_error()
          |> summarise_error()
          |> be_equal("failed CommitRolledBack 22012")
          |> or_fail_with("Expected a rollback caused by the division by zero")
        },
      ),
      unit.it("ROLLBACK with no report is CommitRolledBack with no cause", fn() {
        // Act and assert
        dream_postgres.commit_answer(["ROLLBACK"], None)
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("failed CommitRolledBack(None)")
        |> or_fail_with("Expected a rollback with no cause")
      }),
      unit.it("other tags are UnexpectedCommitAnswer", fn() {
        // Act and assert
        dream_postgres.commit_answer(["COMMIT", "COMMIT"], None)
        |> should
        |> be_error()
        |> summarise_error()
        |> be_equal("failed UnexpectedCommitAnswer([\"COMMIT\", \"COMMIT\"])")
        |> or_fail_with("Expected two COMMIT tags to be unexpected")
      }),
    ]),
    unit.group("a pool that cannot connect", [
      unit.it("a query on a pool with no server is Unavailable", fn() {
        // Arrange
        // Nothing listens on port 5449 on localhost.
        let config =
          dream_postgres.default_config()
          |> dream_postgres.host("localhost")
          |> dream_postgres.port(5449)
          |> dream_postgres.pool_size(1)
          |> dream_postgres.checkout_timeout(300)
          |> dream_postgres.query_timeout(1000)

        // Act and assert
        config
        |> should
        |> run_on_started_pool(fn(connection) {
          query("SELECT 1") |> all(single(codec.int), connection)
        })
        |> be_error()
        |> have_kind_name()
        |> be_equal("unavailable")
        |> or_fail_with("Expected the query to be unavailable")
      }),
    ]),
  ])
}
