//// Tests for `dream_postgres/driver/pool`, the pool and its holds, on the
//// driver servers of PostgreSQL 16 to 19. A test proxy between the pool
//// and the server breaks a connection on purpose, and a control
//// connection straight to the server watches and controls the server, so
//// no test sleeps.
////
//// Each describe has one kind of setup: a pool for each test, a pool
//// through a proxy for each test, a pool under a name for each test, the
//// inputs of a start, or one act that several tests check. The setups and
//// teardowns of `driver/server_pool` start and stop every pool, connection
//// and proxy.

import dream_postgres/driver/catalog.{CatalogProcessDown}
import dream_postgres/driver/connection.{
  type ConnectionEvent, type DriverError, type Outcome, Connected,
  ConnectionLost, ConnectionProcessDown, Disconnected, SocketFailed,
  TransportRefused,
}
import dream_postgres/driver/pool.{
  type HoldError, type Pool, type PoolConfig, type PoolEvent, type PoolStatus,
  ConnectFailed, HoldDeadlinePassed, HoldRefused, HoldWaiting,
  InvalidHealthCheckInterval, InvalidSize, MemberConnected, MemberDisconnected,
  MemberFree, MemberHeld, MemberReplacing, MemberReturned, PoolStatus,
  PoolStopped, PoolStopping,
}
import dream_postgres/driver/transport.{ConnectRefused, SocketClosed}
import dream_postgres/internal/cell.{type TransactionStatus, Idle, InTransaction}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_some, have_length, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/fake_server.{free_port}
import driver/proxy.{
  type Proxy, client_end, close_client, freeze, next_kept, start_proxy,
  stop_proxy, watch_client_end,
}
import driver/server_connection.{
  type ActOutcome, advisory_lock_sql, backend_pid, caller_answer, query_text,
  start_caller, start_in_ended_owner, terminate_backend, wait_for_lock_waiter,
}
import driver/server_pool.{
  type NamedPool, type PoolSession, type ProxiedPool, backend_pid_and_time,
  begin_on_backend, begin_transaction, connection_events_until_connected,
  connection_events_until_disconnected, dream_pool_config, end_owner,
  exit_after_supervisor_kill, exit_holder_in_transaction, health_check_config,
  held_backend_pid, held_transaction_status, hold_connection, hold_pool_lock,
  hold_until_back, kill_and_hold_again, kill_holder, kill_member,
  kill_named_manager, leave_transaction_open, named_pool_setup, next_pool_event,
  pool_act_setup, pool_events_until_free, pool_session_setup, pool_status,
  proxied_pool_act_setup, proxied_pool_setup, query_in_hold, release_holder,
  release_pool_lock, rollback_deadline_config, script_in_hold,
  slow_reconnect_config, start_holder, start_idle_holder, start_owned_pool,
  start_pool, start_supervised_pool, start_test_named_pool, start_test_pool,
  start_test_pool_configured, start_test_proxied_pool,
  start_test_proxied_pool_configured, stop_named_pool, stop_on_backend,
  stop_pool_after_error, stop_pool_inside, stop_pool_session, stop_proxied_pool,
  unchanged_config, user_pool_config, wait_for_disconnect,
  wait_for_failed_reconnect, wait_for_last_query, wait_for_pool_event,
  while_holding,
}
import driver/servers.{
  type Server, driver_servers, first_driver_server, password,
}
import gleam/dynamic
import gleam/erlang/process.{Abnormal}
import gleam/int.{to_string}
import gleam/list.{map, try_map}
import gleam/option.{None}
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/be_different_parts.{be_different_parts}
import matchers/be_equal_parts.{be_equal_parts}
import matchers/extract_connect_failure.{extract_connect_failure}
import matchers/extract_distinct_items.{extract_distinct_items}
import matchers/extract_login_refusal_code.{extract_login_refusal_code}
import matchers/extract_type_name.{extract_type_name}

/// The tests of the pool. The describes run one after the other; the
/// tests of one describe run at the same time.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/pool", [
    pool_tests(),
    proxied_tests(),
    start_tests(),
    two_pool_tests(),
    named_tests(),
    lost_server_tests(),
    late_rollback_tests(),
    drain_tests(),
    replacement_tests(),
    hold_event_tests(),
  ])
}

// With a pool of its own ------------------------------------------------------

fn pool_tests() -> TestSuite {
  describe("with a pool of its own", pool_session_setup(first_driver_server), [
    after_each(stop_pool_session),
    group("on each driver server", map(driver_servers(), server_tests)),
    status_tests(),
    checkout_tests(),
    connect_error_tests(),
    replace_tests(),
    health_check_tests(),
    stop_tests(),
  ])
}

fn server_tests(server: Server) -> ContextNode(PoolSession) {
  group("PostgreSQL " <> to_string(server.version), [
    group("with three connections", [
      before_each(start_test_pool(server, 3)),
      it("starts the set number of connections", fn(session: PoolSession) {
        // Act
        let backends = while_holding(session.pool, 3, try_map(_, backend_pid))

        // Assert
        backends
        |> should
        |> be_ok
        |> be_ok
        |> extract_distinct_items
        |> have_length(3)
        |> or_fail_with("Expected three backends for three nested holds")
      }),
      it("finds no free connection for a fourth hold", fn(session: PoolSession) {
        // Act
        let fourth =
          while_holding(session.pool, 3, fn(_held) {
            pool.hold(session.pool, 0, backend_pid)
          })

        // Assert
        fourth
        |> should
        |> be_ok
        |> be_error
        |> be_equal(HoldDeadlinePassed)
        |> or_fail_with("Expected a timed out fourth hold")
      }),
    ]),
    group("with one connection", [
      before_each(start_test_pool(server, 1)),
      group("after a hold that leaves a transaction open", [
        before_each(leave_transaction_open),
        it(
          "rolls back a transaction that a hold leaves open",
          fn(session: PoolSession) {
            held_transaction_status(session.pool)
            |> should
            |> be_ok
            |> be_equal(Idle)
            |> or_fail_with("Expected the connection outside any transaction")
          },
        ),
      ]),
      it(
        "hands out the same backend after the rollback",
        fn(session: PoolSession) {
          // Act
          let backends = {
            use began <- try(hold_connection(session.pool, begin_on_backend))
            use after <- try(held_backend_pid(session.pool))
            Ok(#(began, after))
          }

          // Assert
          backends
          |> should
          |> be_ok
          |> be_equal_parts
          |> or_fail_with("Expected the same backend after the rollback")
        },
      ),
      group("after a caller that exits in a transaction", [
        before_each(exit_holder_in_transaction),
        it(
          "rolls back the transaction of a caller that exits",
          fn(session: PoolSession) {
            held_transaction_status(session.pool)
            |> should
            |> be_ok
            |> be_equal(Idle)
            |> or_fail_with("Expected the transaction to be rolled back")
          },
        ),
      ]),
      it(
        "has the transaction of the caller open before it exits",
        fn(session: PoolSession) {
          // Act
          let began = {
            use holder <- try(start_holder(session.pool, begin_transaction))
            Ok(kill_holder(holder))
          }

          // Assert
          began
          |> should
          |> be_ok
          |> be_ok
          |> be_equal(InTransaction)
          |> or_fail_with("Expected the caller's transaction to be open")
        },
      ),
      group("while the control connection holds the lock", [
        before_each(hold_pool_lock),
        it(
          "waits for the request of a caller that exits before the reset",
          fn(session: PoolSession) {
            // Act
            let status = {
              let caller =
                start_caller(script_in_hold(
                  session.pool,
                  "BEGIN; SELECT pg_advisory_xact_lock("
                    <> to_string(session.lock_key)
                    <> ")",
                ))
              use _waited <- try(wait_for_lock_waiter(
                session.control,
                session.lock_key,
              ))
              process.kill(caller.pid)
              use Nil <- try(wait_for_pool_event(
                session.pool_events,
                MemberReturned(0),
              ))
              use _unlocked <- try(release_pool_lock(session))
              held_transaction_status(session.pool)
            }

            // Assert
            status
            |> should
            |> be_ok
            |> be_equal(Idle)
            |> or_fail_with(
              "Expected the next holder outside the caller's transaction",
            )
          },
        ),
      ]),
      it(
        "gives a catalog that describes the server's types",
        fn(session: PoolSession) {
          // Act
          let described = {
            use types <- try(pool.catalog(session.pool))
            pool.hold(session.pool, 5000, catalog.describe(types, _, 23, 5000))
          }

          // Assert
          described
          |> should
          |> be_ok
          |> be_ok
          |> extract_type_name
          |> be_equal("int4")
          |> or_fail_with("Expected int4")
        },
      ),
      it("stops its catalog with the pool", fn(session: PoolSession) {
        // Act
        let after_stop = {
          use types <- try(pool.catalog(session.pool))
          pool.stop(session.pool, 1000)
          Ok(catalog.describe(types, session.control, 23, 5000))
        }

        // Assert
        after_stop
        |> should
        |> be_ok
        |> be_error
        |> be_equal(CatalogProcessDown)
        |> or_fail_with("Expected no catalog process after the stop")
      }),
      it("gives no catalog after it stopped", fn(session: PoolSession) {
        // Act
        pool.stop(session.pool, 1000)
        let answer = pool.catalog(session.pool)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(PoolStopped)
        |> or_fail_with("Expected PoolStopped for the catalog")
      }),
    ]),
  ])
}

fn status_tests() -> ContextNode(PoolSession) {
  group("status", [
    before_each(start_test_pool(first_driver_server, 2)),
    it("gives its status", fn(session: PoolSession) {
      // Act
      let status =
        while_holding(session.pool, 2, fn(_held) { pool.status(session.pool) })

      // Assert
      status
      |> should
      |> be_ok
      |> be_ok
      |> be_equal(PoolStatus(
        size: 2,
        connected: 2,
        available: 0,
        held: 2,
        waiting: 0,
        last_connect_error: None,
      ))
      |> or_fail_with("Expected two connected and held connections")
    }),
  ])
}

fn checkout_tests() -> ContextNode(PoolSession) {
  group("checkouts", [
    before_each(start_test_pool(first_driver_server, 1)),
    it(
      "gives HoldDeadlinePassed when no connection is free in time",
      fn(session: PoolSession) {
        // Act
        let answer = {
          use holder <- try(start_idle_holder(session.pool))
          let late = pool.hold(session.pool, 20, backend_pid)
          use _released <- try(release_holder(holder))
          Ok(late)
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_error
        |> be_equal(HoldDeadlinePassed)
        |> or_fail_with("Expected HoldDeadlinePassed")
      },
    ),
    it(
      "gives a waiting checkout the connection that comes back",
      fn(session: PoolSession) {
        // Act
        let answer = {
          use holder <- try(start_idle_holder(session.pool))
          let waiter =
            start_caller(query_in_hold(session.pool, "SELECT 'served'"))
          use Nil <- try(wait_for_pool_event(
            session.pool_events,
            HoldWaiting(1),
          ))
          use _released <- try(release_holder(holder))
          caller_answer(waiter)
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_ok
        |> be_equal("served")
        |> or_fail_with("Expected the waiting checkout to run")
      },
    ),
  ])
}

fn connect_error_tests() -> ContextNode(PoolSession) {
  group("connect errors", [
    group("with a wrong password", [
      before_each(start_test_pool_configured(
        first_driver_server,
        user_pool_config(first_driver_server.port, "dream", "wrong"),
        1,
      )),
      it(
        "gives the connect error of a wrong password",
        fn(session: PoolSession) {
          pool.hold(session.pool, 5000, backend_pid)
          |> should
          |> be_error
          |> extract_connect_failure
          |> extract_login_refusal_code
          |> be_equal("28P01")
          |> or_fail_with("Expected the login refusal 28P01")
        },
      ),
    ]),
    group("with a server that is down", [
      before_each(start_test_pool_configured(
        first_driver_server,
        dream_pool_config(free_port()),
        2,
      )),
      it(
        "gives the connect error of a server that is down",
        fn(session: PoolSession) {
          pool.hold(session.pool, 5000, backend_pid)
          |> should
          |> be_error
          |> be_equal(ConnectFailed(TransportRefused(ConnectRefused)))
          |> or_fail_with(
            "Expected ConnectFailed(TransportRefused(ConnectRefused))",
          )
        },
      ),
    ]),
  ])
}

fn replace_tests() -> ContextNode(PoolSession) {
  group("replacing connections", [
    before_each(start_test_pool(first_driver_server, 1)),
    it(
      "never hands out a connection that the server ended",
      fn(session: PoolSession) {
        // Act
        let backends = {
          use first <- try(held_backend_pid(session.pool))
          use _terminated <- try(terminate_backend(session.control, first))
          use _lost <- try(wait_for_disconnect(session.events))
          use second <- try(held_backend_pid(session.pool))
          Ok(#(first, second))
        }

        // Assert
        backends
        |> should
        |> be_ok
        |> be_different_parts
        |> or_fail_with(
          "Expected a new backend after the server ended the first",
        )
      },
    ),
    it(
      "replaces a connection whose process was killed during a hold",
      fn(session: PoolSession) {
        // Act
        let backends =
          hold_connection(session.pool, kill_and_hold_again(session.pool))

        // Assert
        backends
        |> should
        |> be_ok
        |> be_different_parts
        |> or_fail_with("Expected a new backend inside the first hold")
      },
    ),
    it(
      "keeps the new connection after the hold of the killed one ends",
      fn(session: PoolSession) {
        // Act
        let backends = {
          use inside <- try(hold_connection(
            session.pool,
            kill_and_hold_again(session.pool),
          ))
          use after <- try(held_backend_pid(session.pool))
          Ok(#(inside.1, after))
        }

        // Assert
        backends
        |> should
        |> be_ok
        |> be_equal_parts
        |> or_fail_with("Expected the new backend to stay after the first hold")
      },
    ),
    it(
      "replaces a connection that its holder stopped",
      fn(session: PoolSession) {
        // Act
        let backends = {
          use first <- try(hold_connection(session.pool, stop_on_backend))
          use second <- try(held_backend_pid(session.pool))
          Ok(#(first, second))
        }

        // Assert
        backends
        |> should
        |> be_ok
        |> be_different_parts
        |> or_fail_with(
          "Expected a new backend after the holder stopped the first",
        )
      },
    ),
    it("starts a member again after it was killed", fn(session: PoolSession) {
      // Act
      let backends = {
        use first <- try(held_backend_pid(session.pool))
        use _killed <- try(kill_member(session.pool))
        use second <- try(held_backend_pid(session.pool))
        Ok(#(first, second))
      }

      // Assert
      backends
      |> should
      |> be_ok
      |> be_different_parts
      |> or_fail_with("Expected a new backend from the new member")
    }),
  ])
}

fn health_check_tests() -> ContextNode(PoolSession) {
  group("health checks", [
    group("every 10 milliseconds", [
      before_each(start_test_pool_configured(
        first_driver_server,
        dream_pool_config(first_driver_server.port)
          |> result.map(health_check_config(_, 10, 5000)),
        1,
      )),
      it("runs a health check on an idle connection", fn(session: PoolSession) {
        // Act
        let last_query = {
          use pid <- try(held_backend_pid(session.pool))
          wait_for_last_query(session.control, pid, "SELECT 1", 2000)
        }

        // Assert
        last_query
        |> should
        |> be_ok
        |> be_equal("SELECT 1")
        |> or_fail_with("Expected the health check query")
      }),
    ]),
    group("every 100 milliseconds", [
      before_each(start_test_pool_configured(
        first_driver_server,
        dream_pool_config(first_driver_server.port)
          |> result.map(health_check_config(_, 100, 5000)),
        1,
      )),
      it(
        "skips the health check of a connection used in the interval",
        fn(session: PoolSession) {
          // Act
          let waited_an_interval = {
            use #(pid, used_at) <- try(hold_connection(
              session.pool,
              backend_pid_and_time,
            ))
            use _checked <- try(wait_for_last_query(
              session.control,
              pid,
              "SELECT 1",
              100_000,
            ))
            query_text(
              session.control,
              "SELECT (query_start - '"
                <> used_at
                <> "'::timestamptz >= interval '100 milliseconds')::text"
                <> " FROM pg_stat_activity WHERE pid = "
                <> pid,
            )
          }

          // Assert
          waited_an_interval
          |> should
          |> be_ok
          |> be_equal("true")
          |> or_fail_with(
            "Expected the first health check a whole interval later",
          )
        },
      ),
    ]),
  ])
}

fn stop_tests() -> ContextNode(PoolSession) {
  group("stopping", [
    before_each(start_test_pool(first_driver_server, 1)),
    group("while the control connection holds the lock", [
      before_each(hold_pool_lock),
      it("closes a running hold at the deadline", fn(session: PoolSession) {
        // Act
        let answer = {
          let running =
            start_caller(script_in_hold(
              session.pool,
              advisory_lock_sql(session.lock_key),
            ))
          use _waited <- try(wait_for_lock_waiter(
            session.control,
            session.lock_key,
          ))
          pool.stop(session.pool, 20)
          let ended = caller_answer(running)
          use _unlocked <- try(release_pool_lock(session))
          ended
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_ok
        |> be_error
        |> be_equal(ConnectionProcessDown)
        |> or_fail_with("Expected the hold's command to end with the pool")
      }),
    ]),
    it("gives PoolStopped after it stopped", fn(session: PoolSession) {
      // Act
      pool.stop(session.pool, 1000)
      let answer = pool.hold(session.pool, 5000, backend_pid)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(PoolStopped)
      |> or_fail_with("Expected PoolStopped for a hold")
    }),
    it(
      "gives PoolStopped for the status after it stopped",
      fn(session: PoolSession) {
        // Act
        pool.stop(session.pool, 1000)
        let status = pool.status(session.pool)

        // Assert
        status
        |> should
        |> be_error
        |> be_equal(PoolStopped)
        |> or_fail_with("Expected PoolStopped for the status")
      },
    ),
  ])
}

// Through a proxy -------------------------------------------------------------

fn proxied_tests() -> TestSuite {
  describe("through a proxy", proxied_pool_setup(first_driver_server), [
    after_each(stop_proxied_pool),
    group("with a health check deadline of 50 milliseconds", [
      before_each(
        start_test_proxied_pool_configured(
          first_driver_server,
          health_check_config(_, 10, 50),
        ),
      ),
      it(
        "replaces an idle connection whose health check passes its deadline",
        fn(proxied: ProxiedPool) {
          // Act
          let backends = {
            use first <- try(held_backend_pid(proxied.pool))
            let kept = freeze(proxied.proxy)
            use _health_check <- try(next_kept(kept))
            use second <- try(held_backend_pid(proxied.pool))
            Ok(#(first, second))
          }

          // Assert
          backends
          |> should
          |> be_ok
          |> be_different_parts
          |> or_fail_with(
            "Expected a new backend after the health check failed",
          )
        },
      ),
    ]),
    group("with a health check and a slow reconnect", [
      before_each(start_test_proxied_pool_configured(
        first_driver_server,
        checked_and_slow_config,
      )),
      it(
        "drops the events of a connection that it replaced",
        fn(proxied: ProxiedPool) {
          // Act
          let backends = {
            use first <- try(held_backend_pid(proxied.pool))
            let kept = freeze(proxied.proxy)
            use _health_check <- try(next_kept(kept))
            close_client(proxied.proxy)
            use second <- try(held_backend_pid(proxied.pool))
            Ok(#(first, second))
          }

          // Assert
          backends
          |> should
          |> be_ok
          |> be_different_parts
          |> or_fail_with("Expected a new backend that the pool hands out")
        },
      ),
    ]),
    group("with the dream settings", [
      before_each(start_test_proxied_pool(first_driver_server)),
      it(
        "sends Terminate on each connection when it stops",
        fn(proxied: ProxiedPool) {
          // Act
          let last_bytes = {
            use _backend <- try(held_backend_pid(proxied.pool))
            let watch = watch_client_end(proxied.proxy)
            pool.stop(proxied.pool, 1000)
            Ok(client_end(watch))
          }

          // Assert
          last_bytes
          |> should
          |> be_ok
          |> be_equal(<<"X", 4:32>>)
          |> or_fail_with("Expected a Terminate as the last bytes")
        },
      ),
    ]),
  ])
}

/// A health check every 10 milliseconds, and connections that connect
/// again only after the test, so a replaced connection's Disconnected
/// waits in the member's mailbox.
fn checked_and_slow_config(config: PoolConfig) -> PoolConfig {
  config |> health_check_config(10, 5000) |> slow_reconnect_config
}

// Starting --------------------------------------------------------------------

/// The settings of the start tests: a pool to the first driver server,
/// and a pool through a proxy.
type StartInputs {
  StartInputs(config: PoolConfig, proxy: Proxy, proxied_config: PoolConfig)
}

fn build_start_inputs() -> Result(StartInputs, String) {
  use #(port, proxy) <- try(start_proxy(first_driver_server.port))
  {
    use config <- try(dream_pool_config(first_driver_server.port))
    use proxied_config <- try(dream_pool_config(port))
    Ok(StartInputs(config:, proxy:, proxied_config:))
  }
  |> map_error(fn(error) {
    stop_proxy(proxy)
    error
  })
}

fn stop_start_inputs(inputs: StartInputs) -> Result(Nil, String) {
  Ok(stop_proxy(inputs.proxy))
}

fn start_tests() -> TestSuite {
  describe(
    "starting",
    context.setup(setup: build_start_inputs, teardown: stop_start_inputs),
    [
      it("refuses a size below 1", fn(inputs: StartInputs) {
        // Act
        let started = pool.start(inputs.config, 0)

        // Assert
        started
        |> should
        |> be_error
        |> be_equal(InvalidSize(0))
        |> or_fail_with("Expected InvalidSize(0)")
      }),
      it("refuses a health check interval below 1", fn(inputs: StartInputs) {
        // Act
        let started = pool.start(health_check_config(inputs.config, 0, 5000), 1)

        // Assert
        started
        |> should
        |> be_error
        |> be_equal(InvalidHealthCheckInterval(0))
        |> or_fail_with("Expected InvalidHealthCheckInterval(0)")
      }),
      it(
        "stops when the process that started it exits",
        fn(inputs: StartInputs) {
          // Act
          let last_bytes = {
            use owned <- try(start_owned_pool(inputs.proxied_config, 1))
            use _backend <- try(held_backend_pid(owned.pool))
            let watch = watch_client_end(inputs.proxy)
            end_owner(owned)
            Ok(client_end(watch))
          }

          // Assert
          last_bytes
          |> should
          |> be_ok
          |> be_equal(<<"X", 4:32>>)
          |> or_fail_with("Expected a Terminate when the owner exits")
        },
      ),
      it(
        "stops with an error when the supervisor of its members stops",
        fn(inputs: StartInputs) {
          // Act
          let reason = exit_after_supervisor_kill(inputs.config)

          // Assert
          reason
          |> should
          |> be_ok
          |> be_equal(Abnormal(dynamic.string("a process of the pool stopped")))
          |> or_fail_with("Expected the pool to stop with an error")
        },
      ),
      it("gives PoolStopped for a name that no pool has", fn(_inputs) {
        // Arrange
        let handle = pool.from_name(process.new_name("pool_test_unused"))

        // Act
        let answer = pool.hold(handle, 5000, backend_pid)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(PoolStopped)
        |> or_fail_with("Expected PoolStopped")
      }),
      it("refuses a size below 1 under a supervisor", fn(inputs: StartInputs) {
        // Arrange
        let name = process.new_name("pool_test_size")

        // Act
        let started =
          start_in_ended_owner(fn() {
            start_supervised_pool(inputs.config, 0, name)
          })

        // Assert
        started
        |> should
        |> be_ok
        |> be_error
        |> or_fail_with("Expected the supervisor not to start")
      }),
    ],
  )
}

// Two pools -------------------------------------------------------------------

/// Two pools with other users on the first driver server.
type TwoPools {
  TwoPools(first: Pool, second: Pool)
}

fn start_two_pools() -> Result(TwoPools, String) {
  let port = first_driver_server.port
  use first <- try(dream_pool_config(port) |> try(start_pool(_, 1)))
  {
    use second_config <- try(user_pool_config(port, "dream_trust", password))
    use second <- try(start_pool(second_config, 1))
    Ok(TwoPools(first:, second:))
  }
  |> map_error(stop_pool_after_error(first, _))
}

fn stop_two_pools(pools: TwoPools) -> Result(Nil, String) {
  pool.stop(pools.first, 1000)
  Ok(pool.stop(pools.second, 1000))
}

fn two_pool_tests() -> TestSuite {
  describe(
    "two pools",
    context.setup(setup: start_two_pools, teardown: stop_two_pools),
    [
      it(
        "keeps the settings and the catalog of each pool apart",
        fn(pools: TwoPools) {
          #(pool.catalog(pools.first), pool.catalog(pools.second))
          |> should
          |> be_different_parts
          |> or_fail_with("Expected each pool to have its own catalog")
        },
      ),
      it("logs in with the user of the first pool", fn(pools: TwoPools) {
        hold_connection(pools.first, query_text(_, "SELECT current_user::text"))
        |> should
        |> be_ok
        |> be_equal("dream")
        |> or_fail_with("Expected the user of the first pool")
      }),
      it("logs in with the user of the second pool", fn(pools: TwoPools) {
        hold_connection(pools.second, query_text(_, "SELECT current_user::text"))
        |> should
        |> be_ok
        |> be_equal("dream_trust")
        |> or_fail_with("Expected the user of the second pool")
      }),
    ],
  )
}

// Under a name ----------------------------------------------------------------

fn named_tests() -> TestSuite {
  describe("under a name", named_pool_setup(first_driver_server), [
    before_each(start_test_named_pool(first_driver_server)),
    after_each(stop_named_pool),
    it("refuses a name that another pool has", fn(named: NamedPool) {
      // Act
      let second =
        start_in_ended_owner(fn() {
          start_supervised_pool(named.config, 1, named.name)
        })

      // Assert
      second
      |> should
      |> be_ok
      |> be_error
      |> or_fail_with("Expected the second supervisor not to start")
    }),
    it(
      "ends a hold quietly when its pool stopped during it",
      fn(named: NamedPool) {
        pool.hold(named.handle, 5000, stop_pool_inside(named.handle))
        |> should
        |> be_ok
        |> be_equal("stopped")
        |> or_fail_with("Expected the callback's value")
      },
    ),
    it(
      "gives PoolStopped after its pool stopped during a hold",
      fn(named: NamedPool) {
        // Act
        let status = {
          use _stopped <- try(pool.hold(
            named.handle,
            5000,
            stop_pool_inside(named.handle),
          ))
          pool.status(named.handle)
        }

        // Assert
        status
        |> should
        |> be_error
        |> be_equal(PoolStopped)
        |> or_fail_with("Expected no pool after the hold")
      },
    ),
    it("keeps a handle of the name valid after a restart", fn(named: NamedPool) {
      // Act
      let backends = {
        use first <- try(held_backend_pid(named.handle))
        use _killed <- try(kill_named_manager(named.name))
        use second <- try(hold_until_back(named.handle))
        Ok(#(first, second))
      }

      // Assert
      backends
      |> should
      |> be_ok
      |> be_different_parts
      |> or_fail_with("Expected a new connection through the same handle")
    }),
  ])
}

// A lost server: one act for two tests ----------------------------------------

type LostServer {
  LostServer(
    hold: Result(Result(String, String), HoldError),
    status: PoolStatus,
  )
}

/// The proxy ends: the connection is lost, and its reconnect is refused.
fn lose_server(proxied: ProxiedPool) -> Result(LostServer, String) {
  use _backend <- try(held_backend_pid(proxied.pool))
  stop_proxy(proxied.proxy)
  use _refused <- try(wait_for_failed_reconnect(proxied.events))
  let hold = pool.hold(proxied.pool, 5000, backend_pid)
  use status <- try(pool_status(proxied.pool))
  Ok(LostServer(hold:, status:))
}

fn lost_server_tests() -> TestSuite {
  describe(
    "a lost server",
    proxied_pool_act_setup(first_driver_server, unchanged_config, lose_server),
    [
      it(
        "gives the last connect error when every connection is lost",
        fn(shared: ActOutcome(ProxiedPool, LostServer)) {
          shared.outcome.hold
          |> should
          |> be_error
          |> be_equal(ConnectFailed(TransportRefused(ConnectRefused)))
          |> or_fail_with("Expected the refused reconnect for the hold")
        },
      ),
      it(
        "gives the last connect error in its status",
        fn(shared: ActOutcome(ProxiedPool, LostServer)) {
          shared.outcome.status.last_connect_error
          |> should
          |> be_some
          |> be_equal(TransportRefused(ConnectRefused))
          |> or_fail_with("Expected the refused reconnect in the status")
        },
      ),
    ],
  )
}

// A rollback past its deadline: one act for two tests -------------------------

type LateRollback {
  LateRollback(status: TransactionStatus, backends: #(String, String))
}

/// The hold leaves a transaction open, and the proxy keeps the ROLLBACK,
/// so it passes its deadline of 50 milliseconds. A hold after it gets a
/// new connection.
fn hold_after_late_rollback(
  proxied: ProxiedPool,
) -> Result(LateRollback, String) {
  use #(first, kept) <- try(
    hold_connection(proxied.pool, fn(connection) {
      use pid <- try(begin_on_backend(connection))
      Ok(#(pid, freeze(proxied.proxy)))
    }),
  )
  use _rollback <- try(next_kept(kept))
  use status <- try(held_transaction_status(proxied.pool))
  use second <- try(held_backend_pid(proxied.pool))
  Ok(LateRollback(status:, backends: #(first, second)))
}

fn late_rollback_tests() -> TestSuite {
  describe(
    "a rollback past its deadline",
    proxied_pool_act_setup(
      first_driver_server,
      rollback_deadline_config(_, 50),
      hold_after_late_rollback,
    ),
    [
      it(
        "replaces a connection whose rollback passes its deadline",
        fn(shared: ActOutcome(ProxiedPool, LateRollback)) {
          shared.outcome.backends
          |> should
          |> be_different_parts
          |> or_fail_with("Expected a new backend after the late rollback")
        },
      ),
      it(
        "hands out the new connection outside any transaction",
        fn(shared: ActOutcome(ProxiedPool, LateRollback)) {
          shared.outcome.status
          |> should
          |> be_equal(Idle)
          |> or_fail_with("Expected the new connection outside any transaction")
        },
      ),
    ],
  )
}

// A drain: one act for three tests --------------------------------------------

type Drain {
  Drain(
    refused: Result(Result(String, String), HoldError),
    finished: Result(
      Result(Result(List(Outcome), DriverError), HoldError),
      String,
    ),
    stopped: Result(Nil, String),
  )
}

/// A hold waits on an advisory lock while the pool stops. The pool
/// refuses each checkout that comes after the stop, and closes only after
/// the hold finished.
fn drain_running_hold(session: PoolSession) -> Result(Drain, String) {
  use _locked <- try(hold_pool_lock(session))
  let running =
    start_caller(script_in_hold(
      session.pool,
      advisory_lock_sql(session.lock_key),
    ))
  use _waited <- try(wait_for_lock_waiter(session.control, session.lock_key))
  let stopper = start_caller(fn() { pool.stop(session.pool, 5000) })
  use Nil <- try(wait_for_pool_event(session.pool_events, PoolStopping))
  let refused = pool.hold(session.pool, 5000, backend_pid)
  use _unlocked <- try(release_pool_lock(session))
  let finished = caller_answer(running)
  Ok(Drain(refused:, finished:, stopped: caller_answer(stopper)))
}

fn drain_tests() -> TestSuite {
  describe("a drain", pool_act_setup(first_driver_server, drain_running_hold), [
    it(
      "lets a running hold finish when it stops",
      fn(shared: ActOutcome(PoolSession, Drain)) {
        shared.outcome.finished
        |> should
        |> be_ok
        |> be_ok
        |> be_ok
        |> have_length(1)
        |> or_fail_with("Expected the hold to finish before the pool closed")
      },
    ),
    it(
      "refuses a checkout while it stops",
      fn(shared: ActOutcome(PoolSession, Drain)) {
        shared.outcome.refused
        |> should
        |> be_error
        |> be_equal(PoolStopped)
        |> or_fail_with("Expected PoolStopped for a checkout after the stop")
      },
    ),
    it(
      "closes after the running hold finished",
      fn(shared: ActOutcome(PoolSession, Drain)) {
        shared.outcome.stopped
        |> should
        |> be_ok
        |> be_equal(Nil)
        |> or_fail_with("Expected the stop to end after the hold")
      },
    ),
  ])
}

// The events of a member: one act for the start and a replacement ------------

/// What the subscribers of a pool of one connection through a proxy saw.
/// Its connection connects again only after the test. The proxy closes the
/// socket while a caller holds the connection, so the member's reset after
/// the hold finds the connection lost and replaces it.
type Replacement {
  Replacement(
    start_events: Result(List(PoolEvent), String),
    replace_events: Result(List(PoolEvent), String),
    connection_events: Result(List(ConnectionEvent), String),
    backends: Result(#(String, String), String),
  )
}

/// The backend of the held connection, and the connection events up to
/// its `Disconnected`, after the proxy closed its socket.
type LostInHold {
  LostInHold(backend: String, events: List(ConnectionEvent))
}

fn replace_lost_connection(
  proxied: ProxiedPool,
) -> Result(Replacement, String) {
  let start_events = pool_events_until_free(proxied.pool_events, 0)
  use _first_connected <- try(connection_events_until_connected(proxied.events))
  use lost <- try(
    pool.hold(proxied.pool, 5000, fn(connection) {
      use backend <- try(backend_pid(connection))
      close_client(proxied.proxy)
      connection_events_until_disconnected(proxied.events)
      |> result.map(LostInHold(backend, _))
    })
    |> map_error(inspect)
    |> result.flatten,
  )
  let replace_events = pool_events_until_free(proxied.pool_events, 0)
  let connection_events =
    connection_events_until_connected(proxied.events)
    |> result.map(list.append(lost.events, _))
  let backends =
    held_backend_pid(proxied.pool)
    |> result.map(fn(second) { #(lost.backend, second) })
  Ok(Replacement(start_events:, replace_events:, connection_events:, backends:))
}

fn replacement_tests() -> TestSuite {
  describe(
    "a member that replaces its lost connection",
    proxied_pool_act_setup(
      first_driver_server,
      slow_reconnect_config,
      replace_lost_connection,
    ),
    [
      it(
        "tells MemberConnected, then MemberFree, when it starts",
        fn(shared: ActOutcome(ProxiedPool, Replacement)) {
          shared.outcome.start_events
          |> should
          |> be_ok
          |> be_equal([MemberConnected(0), MemberFree(0)])
          |> or_fail_with("Expected MemberConnected, then MemberFree")
        },
      ),
      it(
        "tells the hold, the loss, the replacement and MemberFree",
        fn(shared: ActOutcome(ProxiedPool, Replacement)) {
          shared.outcome.replace_events
          |> should
          |> be_ok
          |> be_equal([
            MemberHeld(0),
            MemberDisconnected(0, ConnectionLost(SocketFailed(SocketClosed))),
            MemberReturned(0),
            MemberReplacing(0),
            MemberConnected(0),
            MemberFree(0),
          ])
          |> or_fail_with(
            "Expected the pool events of a hold and a replacement",
          )
        },
      ),
      it(
        "gives the old process's Disconnected, then the new one's Connected",
        fn(shared: ActOutcome(ProxiedPool, Replacement)) {
          shared.outcome.connection_events
          |> should
          |> be_ok
          |> be_equal([
            Disconnected(ConnectionLost(SocketFailed(SocketClosed))),
            Connected,
          ])
          |> or_fail_with("Expected each process to speak for itself")
        },
      ),
      it(
        "hands out the new connection",
        fn(shared: ActOutcome(ProxiedPool, Replacement)) {
          shared.outcome.backends
          |> should
          |> be_ok
          |> be_different_parts
          |> or_fail_with("Expected a new backend after the replacement")
        },
      ),
    ],
  )
}

// The events of holds and a stop: one act ------------------------------------

/// A pool of one connection: a hold takes the connection, a second hold
/// waits and passes its deadline, a stop starts while the first hold runs,
/// a hold after the stop is refused, and the first hold ends.
type HoldsAndStop {
  HoldsAndStop(
    events: List(PoolEvent),
    timed_out: Result(Result(String, String), HoldError),
    after_stop: Result(Result(String, String), HoldError),
  )
}

fn walk_holds_and_stop(session: PoolSession) -> Result(HoldsAndStop, String) {
  use Nil <- try(wait_for_pool_event(session.pool_events, MemberFree(0)))
  use holder <- try(start_idle_holder(session.pool))
  use held <- try(next_pool_event(session.pool_events))
  let timed_out = pool.hold(session.pool, 50, backend_pid)
  use waiting <- try(next_pool_event(session.pool_events))
  use refused <- try(next_pool_event(session.pool_events))
  let stopper = start_caller(fn() { pool.stop(session.pool, 5000) })
  use stopping <- try(next_pool_event(session.pool_events))
  let after_stop = pool.hold(session.pool, 5000, backend_pid)
  use late_refused <- try(next_pool_event(session.pool_events))
  use Nil <- try(release_holder(holder))
  use returned <- try(next_pool_event(session.pool_events))
  use Nil <- try(caller_answer(stopper) |> map_error(inspect))
  Ok(HoldsAndStop(
    events: [held, waiting, refused, stopping, late_refused, returned],
    timed_out:,
    after_stop:,
  ))
}

fn hold_event_tests() -> TestSuite {
  describe(
    "the events of holds and a stop",
    pool_act_setup(first_driver_server, walk_holds_and_stop),
    [
      it(
        "tells each hold, wait, refusal, stop and return, in order",
        fn(shared: ActOutcome(PoolSession, HoldsAndStop)) {
          shared.outcome.events
          |> should
          |> be_equal([
            MemberHeld(0),
            HoldWaiting(1),
            HoldRefused(HoldDeadlinePassed),
            PoolStopping,
            HoldRefused(PoolStopped),
            MemberReturned(0),
          ])
          |> or_fail_with("Expected the pool events in their order")
        },
      ),
      it(
        "refuses the waiting hold at its deadline",
        fn(shared: ActOutcome(PoolSession, HoldsAndStop)) {
          shared.outcome.timed_out
          |> should
          |> be_error
          |> be_equal(HoldDeadlinePassed)
          |> or_fail_with("Expected HoldDeadlinePassed")
        },
      ),
      it(
        "refuses a hold after the stop",
        fn(shared: ActOutcome(PoolSession, HoldsAndStop)) {
          shared.outcome.after_stop
          |> should
          |> be_error
          |> be_equal(PoolStopped)
          |> or_fail_with("Expected PoolStopped")
        },
      ),
    ],
  )
}
