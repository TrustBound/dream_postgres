//// The boot check `verify` on PostgreSQL 16 to 19: each query is
//// prepared and checked against the live database, and none runs.

import dream_postgres/boot_check.{verify}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import fixtures/boot_checks
import fixtures/no_database
import fixtures/server_pools
import fixtures/server_versions
import gleam/list
import matchers/describe_each_error.{describe_each_error}
import matchers/leave_rows.{leave_rows}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_on_stopped_pool.{run_on_stopped_pool}
import matchers/run_with_table.{run_with_table}
import matchers/run_with_temporary_table.{run_with_temporary_table}

/// `verify` on each driver server, with one pool for each server.
pub fn tests() -> TestSuite {
  describe(
    "verify on PostgreSQL 16 to 19",
    context.setup(server_pools.start, teardown: server_pools.stop),
    list.map(server_versions.all(), fn(version) {
      group(server_versions.group_name(version), [
        before_all(server_pools.choose_version(version)),
        it("every check passes on a table that fits the queries", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "checked_users",
            boot_checks.columns,
            fn(held) { verify(held, [boot_checks.queries()]) },
          )
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with("Expected every query to fit the table")
        }),
        it("the checks pass on a pool", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(pool) {
            verify(pool, [[boot_checks.add_one()], []])
          })
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with("Expected the query to fit the server")
        }),
        it("a changed column type gives the column error", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "checked_users",
            boot_checks.changed_columns,
            fn(held) { verify(held, [[boot_checks.read()]]) },
          )
          |> be_error()
          |> describe_each_error()
          |> be_equal([
            "failed: user.read: column 3 (nickname) is int4, and the query reads it with the nullable text codec",
          ])
          |> or_fail_with("Expected the changed type of nickname")
        }),
        it("a missing column gives the error of the server", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "checked_users",
            boot_checks.missing_columns,
            fn(held) { verify(held, [[boot_checks.read()]]) },
          )
          |> be_error()
          |> describe_each_error()
          |> be_equal([
            "failed: user.read: column \"nickname\" does not exist (42703)",
          ])
          |> or_fail_with("Expected the missing column nickname")
        }),
        it("a wrong parameter codec gives the parameter error", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "checked_users",
            boot_checks.columns,
            fn(held) { verify(held, [[boot_checks.find_with_wrong_codec()]]) },
          )
          |> be_error()
          |> describe_each_error()
          |> be_equal([
            "failed: user.find_by_email: parameter $1 is text, and the query gives it with the int codec",
          ])
          |> or_fail_with("Expected the int codec of the text parameter")
        }),
        it("every failing query is reported, in order", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "checked_users",
            boot_checks.changed_columns,
            fn(held) {
              verify(held, [
                boot_checks.queries(),
                [boot_checks.find_with_wrong_codec()],
              ])
            },
          )
          |> be_error()
          |> describe_each_error()
          |> be_equal([
            "failed: user.read: column 3 (nickname) is int4, and the query reads it with the nullable text codec",
            "failed: user.create: parameter $3 is int4, and the query gives it with the nullable text codec",
            "failed: user.find_by_email: parameter $1 is text, and the query gives it with the int codec",
          ])
          |> or_fail_with("Expected the three failing queries")
        }),
        it("the check of an INSERT inserts no row", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_table("checked_rows", fn(held) {
            verify(held, [[boot_checks.insert_one()]])
          })
          |> leave_rows([])
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with("Expected the check to pass and to insert no row")
        }),
        it("a stopped pool gives its one error", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_stopped_pool(fn(stopped) {
            verify(stopped, [[boot_checks.add_one()]])
          })
          |> be_error()
          |> describe_each_error()
          |> be_equal(["unavailable: the pool is stopped"])
          |> or_fail_with("Expected the stopped pool to be unavailable")
        }),
      ])
    }),
  )
}

/// `verify` on a connection with no database.
pub fn unit_tests() -> TestSuite {
  unit.describe("verify with no database", [
    unit.it("a connection with no database gives NoDatabaseToVerify", fn() {
      // Act and assert
      verify(no_database.connection(), [boot_checks.queries()])
      |> should
      |> be_error()
      |> describe_each_error()
      |> be_equal([
        "failed: the connection has no database to check the queries against",
      ])
      |> or_fail_with("Expected the connection with no database to fail")
    }),
  ])
}
