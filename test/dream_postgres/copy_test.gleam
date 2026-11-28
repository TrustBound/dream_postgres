//// `copy_from` and `copy_to` on PostgreSQL 16 to 19.
////
//// Each server has one pool for all of its tests. A test that writes rows
//// holds one connection and makes its own temporary table on it, so no
//// table stays on the server.

import dream_postgres/codec
import dream_postgres/copy.{copy_from, copy_to, table, table_in_schema}
import dream_postgres/pool
import dream_postgres/query.{parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{commit, keep_both, step, transaction}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{before_all, describe, group, it}
import fixtures/client_statements
import fixtures/copy_users.{User}
import fixtures/interceptors
import fixtures/server_pools
import fixtures/server_versions
import gleam/function
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/pair
import gleam/result
import matchers/leave_rows.{leave_rows}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_with_table.{run_with_table}
import matchers/run_with_temporary_table.{run_with_temporary_table}
import matchers/summarise_error.{summarise_error}
import matchers/summarise_errors.{summarise_errors}

/// COPY on each driver server, with one pool for each server.
pub fn tests() -> TestSuite {
  describe(
    "COPY on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        it("copy_from stores rows that copy_to reads back", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "copy_users",
            "(id int4, email text)",
            fn(held) {
              use stored <- result.try(copy_from(
                held,
                into: table("copy_users"),
                columns: ["id", "email"],
                rows: copy_users.users(),
                write: copy_users.user_fields,
              ))
              copy_to(
                held,
                query("SELECT id, email FROM copy_users ORDER BY id"),
                read: copy_users.user_row(),
                from: [],
                with: list.prepend,
              )
              |> result.map(pair.new(stored, _))
            },
          )
          |> be_ok()
          |> be_equal(#(3, list.reverse(copy_users.users())))
          |> or_fail_with("Expected the three users stored and read back")
        }),
        it("copy_from stores a NULL field as NULL", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "copy_null_users",
            "(id int4, email text)",
            fn(held) {
              use _stored <- result.try(copy_from(
                held,
                into: table("copy_null_users"),
                columns: ["id", "email"],
                rows: copy_users.users(),
                write: copy_users.user_fields,
              ))
              query("SELECT id FROM copy_null_users WHERE email IS NULL")
              |> query.all(single(codec.int), held)
            },
          )
          |> be_ok()
          |> be_equal([2])
          |> or_fail_with("Expected the user 2 with a NULL email")
        }),
        it(
          "copy_from that an interceptor made a `run_sql` call is refused",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(fn(pool) {
              copy_from(
                pool.with_interceptor(pool, interceptors.make_sql()),
                into: table("copy_users"),
                columns: ["id", "email"],
                rows: copy_users.users(),
                write: copy_users.user_fields,
              )
            })
            |> be_error()
            |> summarise_error()
            |> be_equal(
              "failed InterceptorFailed(\"an interceptor changed a COPY FROM into another kind of request\")",
            )
            |> or_fail_with("Expected the changed request refused")
          },
        ),
        it("copy_from with no rows stores none", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("copy_no_rows", copy_from(
            _,
            into: table("copy_no_rows"),
            columns: ["id"],
            rows: [],
            write: copy_users.id_fields,
          ))
          |> leave_rows([])
          |> be_ok()
          |> be_equal(0)
          |> or_fail_with("Expected no row stored")
        }),
        it("copy_from sends many rows in several chunks on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("copy_many_rows", copy_from(
            _,
            into: table("copy_many_rows"),
            columns: ["id"],
            rows: copy_users.ids(10_000),
            write: copy_users.id_fields,
          ))
          |> leave_rows(copy_users.ids(10_000))
          |> be_ok()
          |> be_equal(10_000)
          |> or_fail_with("Expected the 10000 rows stored")
        }),
        it("copy_from quotes odd table and column names", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "\"Odd \"\"Table\"\".x\"",
            "(\"Mixed Case\" int4, \"we\"\"ird\" text)",
            fn(held) {
              use stored <- result.try(copy_from(
                held,
                into: table("Odd \"Table\".x"),
                columns: ["Mixed Case", "we\"ird"],
                rows: copy_users.users(),
                write: copy_users.user_fields,
              ))
              copy_to(
                held,
                query(
                  "SELECT \"Mixed Case\", \"we\"\"ird\" FROM \"Odd \"\"Table\"\".x\" ORDER BY 1",
                ),
                read: copy_users.user_row(),
                from: [],
                with: list.prepend,
              )
              |> result.map(pair.new(stored, _))
            },
          )
          |> be_ok()
          |> be_equal(#(3, list.reverse(copy_users.users())))
          |> or_fail_with("Expected the users in the table with odd names")
        }),
        it("copy_from stores rows in a table named with its schema", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "copy_schema_users",
            "(id int4, email text)",
            fn(held) {
              use stored <- result.try(copy_from(
                held,
                into: table_in_schema("pg_temp", "copy_schema_users"),
                columns: ["id", "email"],
                rows: copy_users.users(),
                write: copy_users.user_fields,
              ))
              copy_to(
                held,
                query(
                  "SELECT id, email FROM pg_temp.copy_schema_users ORDER BY 1",
                ),
                read: copy_users.user_row(),
                from: [],
                with: list.prepend,
              )
              |> result.map(pair.new(stored, _))
            },
          )
          |> be_ok()
          |> be_equal(#(3, list.reverse(copy_users.users())))
          |> or_fail_with("Expected the users in pg_temp.copy_schema_users")
        }),
        it(
          "copy_from refuses a codec that does not take a column's type before any row",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("copy_wrong_codec_rows", copy_from(
              _,
              into: table("copy_wrong_codec_rows"),
              columns: ["id"],
              rows: [1, 2],
              write: copy_users.text_id_fields,
            ))
            |> leave_rows([])
            |> be_error()
            |> summarise_error()
            |> be_equal("failed ParameterTypeMismatch(1, \"int4\", \"text\")")
            |> or_fail_with("Expected the text codec refused for int4")
          },
        ),
        it("copy_from refuses a codec in the text format", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("copy_text_codec_rows", copy_from(
            _,
            into: table("copy_text_codec_rows"),
            columns: ["id"],
            rows: [1, 2],
            write: copy_users.custom_id_fields,
          ))
          |> leave_rows([])
          |> be_error()
          |> summarise_error()
          |> be_equal("failed CopyNeedsBinaryCodec(1, \"id\", \"int4\")")
          |> or_fail_with("Expected the codec in the text format refused")
        }),
        it(
          "copy_from stores no row when a later row cannot be written",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("copy_later_failure_rows", copy_from(
              _,
              into: table("copy_later_failure_rows"),
              columns: ["id"],
              rows: [1, 2, 3_000_000_000],
              write: copy_users.id_fields,
            ))
            |> leave_rows([])
            |> be_error()
            |> summarise_error()
            |> be_equal(
              "invalid EncodeFailed(1, \"3000000000 is out of range for int4\")",
            )
            |> or_fail_with("Expected the third row refused and no row stored")
          },
        ),
        it("copy_from gives the error of a row the server refuses", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "copy_unique_users",
            "(id int4 PRIMARY KEY, email text)",
            copy_from(
              _,
              into: table("copy_unique_users"),
              columns: ["id", "email"],
              rows: [User(id: 1, email: None), User(id: 1, email: None)],
              write: copy_users.user_fields,
            ),
          )
          |> be_error()
          |> summarise_error()
          |> be_equal("conflict 23505")
          |> or_fail_with("Expected the second id 1 to violate the key")
        }),
        it("copy_from into a table that does not exist fails", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(copy_from(
            _,
            into: table("copy_missing_table"),
            columns: ["id"],
            rows: [1],
            write: copy_users.id_fields,
          ))
          |> be_error()
          |> summarise_error()
          |> be_equal("failed 42P01")
          |> or_fail_with("Expected the missing table as 42P01")
        }),
        it(
          "copy_from inside a transaction that rolls back stores nothing",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("copy_rolled_back_rows", fn(held) {
              transaction(
                held,
                database: function.identity,
                rollback_also_failed: keep_both,
              )
              |> step(copy_from(
                _,
                into: table("copy_rolled_back_rows"),
                columns: ["id"],
                rows: [1, 2, 3],
                write: copy_users.id_fields,
              ))
              |> step(client_statements.divide_by_zero)
              |> commit
            })
            |> leave_rows([])
            |> be_error()
            |> summarise_error()
            |> be_equal("invalid 22012")
            |> or_fail_with("Expected the rollback to leave no row")
          },
        ),
        it("copy_to folds over a result of many chunks", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(copy_to(
            _,
            query("SELECT g FROM generate_series(1, 20000) AS g"),
            read: single(codec.int),
            from: 0,
            with: int.add,
          ))
          |> be_ok()
          |> be_equal(200_010_000)
          |> or_fail_with("Expected the sum of 1 to 20000")
        }),
        it("copy_to stops at a row that the reader cannot read", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(copy_to(
            _,
            query(
              "SELECT NULLIF(g, 3) AS id FROM generate_series(1, 5000) AS g",
            ),
            read: single(codec.int),
            from: 0,
            with: int.add,
          ))
          |> be_error()
          |> summarise_error()
          |> be_equal("failed UnexpectedNull(1, \"id\")")
          |> or_fail_with("Expected the NULL of row 3 to stop the COPY")
        }),
        it(
          "the connection serves the next call after a stopped copy_to",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_table("copy_after_stop_rows", fn(held) {
              copy_to(
                held,
                query(
                  "SELECT NULLIF(g, 3) AS id FROM generate_series(1, 5000) AS g",
                ),
                read: single(codec.int),
                from: 0,
                with: int.add,
              )
              |> result.try_recover(fn(_stopped) {
                client_statements.insert(held, "copy_after_stop_rows", 1)
              })
            })
            |> leave_rows([1])
            |> be_ok()
            |> be_equal(1)
            |> or_fail_with("Expected the insert after the stop to run")
          },
        ),
        it("copy_to gives the error of the server during the copy", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(copy_to(
            _,
            query("SELECT 1 / (g - 3) AS id FROM generate_series(1, 5) AS g"),
            read: single(codec.int),
            from: 0,
            with: int.add,
          ))
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid 22012")
          |> or_fail_with("Expected the division by zero of row 3")
        }),
        it("copy_to refuses a query with parameters", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(connection) {
            [
              copy_to(
                connection,
                query("SELECT $1::int4 AS id") |> parameter(codec.int, 1),
                read: single(codec.int),
                from: 0,
                with: int.add,
              ),
              copy_to(
                connection,
                query("SELECT $1::int4 AS id"),
                read: single(codec.int),
                from: 0,
                with: int.add,
              ),
            ]
          })
          |> summarise_errors()
          |> be_equal(list.repeat("failed CopyQueryHasParameters(1)", 2))
          |> or_fail_with("Expected a given and an unset parameter refused")
        }),
        it(
          "copy_to refuses a reader with a codec in the text format",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_on_pool(copy_to(
              _,
              query("SELECT 1::int4 AS id"),
              read: copy_users.custom_int4_row(),
              from: 0,
              with: int.add,
            ))
            |> be_error()
            |> summarise_error()
            |> be_equal("failed CopyNeedsBinaryCodec(1, \"id\", \"int4\")")
            |> or_fail_with("Expected the codec in the text format refused")
          },
        ),
      ])
    }),
  )
}
