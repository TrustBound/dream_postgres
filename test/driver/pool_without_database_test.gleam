//// Proves a pool with no database: it runs under a supervisor and a name,
//// answers `attachment`, `status` and `catalog`, refuses each hold with
//// `NoDatabase` at once, dials nothing, and is a transient child.

import dream_postgres/driver/pool.{NoDatabase, PoolStatus}
import dream_test/context
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{describe, it}
import driver/fake_server.{free_port}
import driver/server_pool.{
  type NamedPool, event_after_status_without_database,
  start_pool_without_database, stop_named_pool,
}
import driver/server_supervisor.{first_child_restart_type, restart_first_child}
import gleam/option.{None}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect}

/// The tests of a pool with no database.
pub fn tests() -> TestSuite {
  suite.group("a pool with no database", [
    shared_tests(),
    restarted_tests(),
    unit.describe("on a port where nothing listens", [
      unit.it("tells no pool event", fn() {
        event_after_status_without_database(free_port())
        |> should
        |> be_equal(Ok(Error(Nil)))
        |> or_fail_with("Expected no pool event, so no dial")
      }),
    ]),
  ])
}

fn shared_tests() -> TestSuite {
  describe(
    "under a supervisor",
    context.setup(
      setup: fn() { start_pool_without_database(free_port()) },
      teardown: stop_named_pool,
    ),
    [
      it(
        "gives its attachment through a handle of its name",
        fn(named: NamedPool) {
          pool.attachment(named.handle)
          |> should
          |> be_equal(Ok("the settings of a pool with no database"))
          |> or_fail_with("Expected the attachment")
        },
      ),
      it("shows no connection in its status", fn(named: NamedPool) {
        pool.status(named.handle)
        |> should
        |> be_equal(
          Ok(PoolStatus(
            size: 0,
            connected: 0,
            available: 0,
            held: 0,
            waiting: 0,
            last_connect_error: None,
          )),
        )
        |> or_fail_with("Expected a status of no connection")
      }),
      it("gives its catalog", fn(named: NamedPool) {
        pool.catalog(named.handle)
        |> replace(Nil)
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("Expected the catalog")
      }),
      it("refuses a hold with NoDatabase at once", fn(named: NamedPool) {
        // A wait of one minute would time the test out: the answer comes
        // at once.
        pool.hold(named.handle, 60_000, fn(_connection) { Nil })
        |> should
        |> be_equal(Error(NoDatabase))
        |> or_fail_with("Expected NoDatabase")
      }),
      it("is a transient child of its supervisor", fn(named: NamedPool) {
        first_child_restart_type(named.supervisor)
        |> should
        |> be_ok
        |> be_equal("transient")
        |> or_fail_with("Expected a transient child")
      }),
    ],
  )
}

/// The restart has a pool of its own, so no other test meets the pool
/// while it is down.
fn restarted_tests() -> TestSuite {
  describe(
    "started again by its supervisor",
    context.setup(
      setup: fn() { start_pool_without_database(free_port()) },
      teardown: stop_named_pool,
    ),
    [
      it(
        "serves the same handle after its supervisor started it again",
        fn(named: NamedPool) {
          {
            use Nil <- try(restart_first_child(named.supervisor))
            pool.attachment(named.handle) |> map_error(inspect)
          }
          |> should
          |> be_equal(Ok("the settings of a pool with no database"))
          |> or_fail_with("Expected the attachment of the new pool")
        },
      ),
    ],
  )
}
