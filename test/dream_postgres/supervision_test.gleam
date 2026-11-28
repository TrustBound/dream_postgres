//// A pool under the app's supervisor: its child specification, the
//// connection from its name, and the name after a restart.

import dream_postgres/codecs
import dream_postgres/error
import dream_postgres/pool.{named_connection}
import dream_postgres/query.{all, query}
import dream_postgres/row.{single}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/server_pools
import fixtures/supervisors
import gleam/erlang/process
import gleam/result
import matchers/have_cause.{have_cause}
import matchers/have_reason.{have_reason}
import matchers/run_on_supervised_pool.{run_on_supervised_pool}

pub fn tests() -> TestSuite {
  describe("a pool under a supervisor", [
    it("answers through the connection of its name", fn() {
      // Arrange
      let name = process.new_name("supervised_pool_answers")

      // Act and assert
      server_pools.config(5441)
      |> should
      |> run_on_supervised_pool(name, fn(_supervisor) {
        all(query("SELECT 1"), single(codecs.int), named_connection(name))
      })
      |> be_ok()
      |> be_equal([1])
      |> or_fail_with("Expected the named pool to answer SELECT 1")
    }),
    it("answers through the same name after the supervisor restarts it", fn() {
      // Arrange
      let name = process.new_name("supervised_pool_restarts")

      // Act and assert
      server_pools.config(5441)
      |> should
      |> run_on_supervised_pool(name, fn(supervisor) {
        let first_pool = process.named(name)
        result.map(first_pool, process.kill)
        |> result.map(fn(_killed) { supervisors.wait_for_restarts(supervisor) })
        |> result.replace_error(error.PoolStopped)
        |> result.try(fn(_restarted) {
          all(query("SELECT 2"), single(codecs.int), named_connection(name))
          |> result.map_error(fn(_failure) { error.PoolStopped })
        })
      })
      |> be_ok()
      |> be_equal([2])
      |> or_fail_with(
        "Expected the restarted pool to answer under the same name",
      )
    }),
    it("refuses a config that cannot start, before any supervisor", fn() {
      // Act and assert
      server_pools.config(70_000)
      |> pool.supervised(name: process.new_name("supervised_bad_port"))
      |> should
      |> be_error()
      |> have_cause()
      |> have_reason()
      |> be_equal(error.InvalidConfig(error.InvalidPort(70_000)))
      |> or_fail_with("Expected InvalidConfig(InvalidPort(70000))")
    }),
    it("gives PoolStopped while no pool runs under the name", fn() {
      // Act and assert
      all(
        query("SELECT 1"),
        single(codecs.int),
        named_connection(process.new_name("no_pool_runs_here")),
      )
      |> should
      |> be_error()
      |> have_cause()
      |> have_reason()
      |> be_equal(error.PoolStopped)
      |> or_fail_with("Expected PoolStopped for a name with no pool")
    }),
  ])
}
