//// Proves a supervised connection whose server is down when it starts: it
//// stays up, refuses each kind of request as not connected, and connects
//// once the server listens.

import dream_postgres/driver/connection.{supervised}
import dream_postgres/driver/connection/backoff.{Backoff}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/copy_caller as connection_copy_caller
import dream_postgres/driver/connection/event.{
  type ConnectionEvent, ConnectFailed, Connected, TransportRefused,
}
import dream_postgres/driver/connection/extended_query as connection_extended_query
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/request_failure.{
  type ChunkError, type CopyError, type HousekeepingError, type PrepareError,
  type RunError, type SettleError, type SimpleQueryError, CopyNotConnected,
  HousekeepingNotConnected, PrepareNotConnected, RunNotConnected,
  SettleNotConnected, SimpleQueryNotConnected,
}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_postgres/driver/connection/status as connection_status
import dream_postgres/driver/housekeeping_sql.{catalog_load, rollback}
import dream_postgres/driver/transport.{ConnectRefused}
import dream_postgres/internal/cell.{
  type StatementDescription, type TransactionStatus,
}
import dream_test/context.{type Context}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{describe, it}
import driver/fake_server.{free_port}
import driver/reconnect_server.{
  next_event_after_failed_connects, start_forwarder,
}
import driver/server_connection.{connection_config, next_event, stop_connection}
import driver/servers.{first_driver_server}
import fixtures/backoff_strategies.{capped_delay}
import fixtures/copy_callbacks.{send_nothing}
import fixtures/identity_sink.{identity_sink}
import gleam/erlang/process
import gleam/option.{Some}
import gleam/result.{map_error, try}
import gleam/string.{inspect}

/// The tests of a supervised connection that starts with its server down.
pub fn tests() -> TestSuite {
  describe("a supervised connection whose server is down", late_server_setup(), [
    it("tells ConnectFailed for its first attempt", fn(outcome: LateServer) {
      // Assert
      outcome.first_event
      |> should
      |> be_equal(Ok(ConnectFailed(TransportRefused(ConnectRefused))))
      |> or_fail_with("Expected ConnectFailed")
    }),
    it(
      "refuses a simple query with SimpleQueryNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_simple_query
        |> should
        |> be_error
        |> be_equal(SimpleQueryNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected SimpleQueryNotConnected")
      },
    ),
    it(
      "refuses a prepare with PrepareNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_prepare
        |> should
        |> be_error
        |> be_equal(PrepareNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected PrepareNotConnected")
      },
    ),
    it(
      "refuses a run with RunNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_run
        |> should
        |> be_error
        |> be_equal(RunNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected RunNotConnected")
      },
    ),
    it(
      "refuses a settled status with SettleNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_settle
        |> should
        |> be_error
        |> be_equal(SettleNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected SettleNotConnected")
      },
    ),
    it(
      "refuses a COPY with CopyNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_copy
        |> should
        |> be_error
        |> be_equal(CopyNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected CopyNotConnected")
      },
    ),
    it(
      "refuses a housekeeping run with HousekeepingNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_housekeeping_run
        |> should
        |> be_error
        |> be_equal(HousekeepingNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected HousekeepingNotConnected")
      },
    ),
    it(
      "refuses a housekeeping simple query with HousekeepingNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_housekeeping_simple_query
        |> should
        |> be_error
        |> be_equal(HousekeepingNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected HousekeepingNotConnected")
      },
    ),
    it("tells Connected once the server listens", fn(outcome: LateServer) {
      // Assert
      outcome.connected_event
      |> should
      |> be_equal(Ok(Connected))
      |> or_fail_with("Expected Connected")
    }),
    it("runs a request after its first login", fn(outcome: LateServer) {
      // Assert
      outcome.late_request
      |> should
      |> be_ok
      |> or_fail_with("Expected the request to run")
    }),
  ])
}

/// What a supervised connection did before and after its server listened.
type LateServer {
  LateServer(
    connection: Connection,
    first_event: Result(ConnectionEvent, Nil),
    early_simple_query: Result(List(Outcome), SimpleQueryError),
    early_prepare: Result(StatementDescription, PrepareError),
    early_run: Result(Outcome, RunError),
    early_settle: Result(TransactionStatus, SettleError),
    early_copy: Result(Int, CopyError(ChunkError)),
    early_housekeeping_run: Result(Outcome, HousekeepingError),
    early_housekeeping_simple_query: Result(List(Outcome), HousekeepingError),
    connected_event: Result(ConnectionEvent, Nil),
    late_request: Result(List(Outcome), SimpleQueryError),
  )
}

fn late_server_setup() -> Context(LateServer) {
  context.setup(setup: start_before_server, teardown: stop_late_server)
}

fn start_before_server() -> Result(LateServer, String) {
  let port = free_port()
  let events = process.new_subject()
  use config <- try(connection_config(port))
  let config =
    ConnectionConfig(
      ..config,
      reconnect: Backoff(10, 100, capped_delay),
      events: Some(identity_sink(events)),
    )
  use started <- try(supervised(config).start() |> map_error(inspect))
  watch_late_server(started.data, port, events)
  |> map_error(fn(error) {
    connection.stop(started.data)
    error
  })
}

fn watch_late_server(
  connection: Connection,
  port: Int,
  events: process.Subject(ConnectionEvent),
) -> Result(LateServer, String) {
  let first_event = next_event(events)
  let early_simple_query =
    connection_simple_query.run_simple_query(
      connection,
      connection_statement.statement("SELECT 1"),
      5000,
    )
  let early_prepare =
    connection_extended_query.prepare(
      connection,
      connection_statement.statement("SELECT 1"),
      5000,
    )
  let early_run =
    connection_extended_query.run(
      connection,
      connection_statement.statement("SELECT 1"),
      [],
      [],
      5000,
    )
  let early_settle =
    connection_status.settled_transaction_status(connection, 5000)
  let early_copy =
    connection_copy_caller.copy_from(
      connection,
      connection_statement.statement("COPY items FROM STDIN"),
      5000,
      send_nothing,
    )
  let early_housekeeping_run =
    connection_extended_query.run_housekeeping(connection, catalog_load, 5000)
  let early_housekeeping_simple_query =
    connection_simple_query.run_housekeeping_simple_query(
      connection,
      rollback,
      5000,
    )
  use Nil <- try(start_forwarder(port, first_driver_server.port))
  let connected_event = next_event_after_failed_connects(events)
  let late_request =
    connection_simple_query.run_simple_query(
      connection,
      connection_statement.statement("SELECT 1"),
      5000,
    )
  Ok(LateServer(
    connection:,
    first_event:,
    early_simple_query:,
    early_prepare:,
    early_run:,
    early_settle:,
    early_copy:,
    early_housekeeping_run:,
    early_housekeeping_simple_query:,
    connected_event:,
    late_request:,
  ))
}

fn stop_late_server(outcome: LateServer) -> Result(Nil, String) {
  stop_connection(outcome.connection)
}
