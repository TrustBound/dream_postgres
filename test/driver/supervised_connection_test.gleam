//// Proves a supervised connection whose server is down when it starts: it
//// stays up, refuses each kind of request as not connected, and connects
//// once the server listens.

import dream_postgres/driver/connection.{
  type ChunkError, type Connection, type ConnectionEvent, type CopyError,
  type HousekeepingError, type Outcome, type PrepareError, type RunError,
  type ScriptError, type SettleError, Backoff, ConnectFailed, Connected,
  ConnectionConfig, CopyNotConnected, HousekeepingNotConnected,
  PrepareNotConnected, RunNotConnected, ScriptNotConnected, SettleNotConnected,
  TransportRefused, supervised,
}
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
import fixtures/copy_callbacks.{send_nothing}
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
      "refuses a script with ScriptNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_script
        |> should
        |> be_error
        |> be_equal(ScriptNotConnected(TransportRefused(ConnectRefused)))
        |> or_fail_with("Expected ScriptNotConnected")
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
      "refuses a housekeeping script with HousekeepingNotConnected before its first login",
      fn(outcome: LateServer) {
        // Assert
        outcome.early_housekeeping_script
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
    early_script: Result(List(Outcome), ScriptError),
    early_prepare: Result(StatementDescription, PrepareError),
    early_run: Result(Outcome, RunError),
    early_settle: Result(TransactionStatus, SettleError),
    early_copy: Result(Int, CopyError(ChunkError)),
    early_housekeeping_run: Result(Outcome, HousekeepingError),
    early_housekeeping_script: Result(List(Outcome), HousekeepingError),
    connected_event: Result(ConnectionEvent, Nil),
    late_request: Result(List(Outcome), ScriptError),
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
      reconnect: Backoff(10, 100),
      events: Some(events),
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
  let early_script =
    connection.run_script(connection, connection.statement("SELECT 1"), 5000)
  let early_prepare =
    connection.prepare(connection, connection.statement("SELECT 1"), 5000)
  let early_run =
    connection.run(connection, connection.statement("SELECT 1"), [], [], 5000)
  let early_settle = connection.settled_transaction_status(connection, 5000)
  let early_copy =
    connection.copy_from(
      connection,
      connection.statement("COPY items FROM STDIN"),
      5000,
      send_nothing,
    )
  let early_housekeeping_run =
    connection.run_housekeeping(connection, catalog_load, 5000)
  let early_housekeeping_script =
    connection.run_housekeeping_script(connection, rollback, 5000)
  use Nil <- try(start_forwarder(port, first_driver_server.port))
  let connected_event = next_event_after_failed_connects(events)
  let late_request =
    connection.run_script(connection, connection.statement("SELECT 1"), 5000)
  Ok(LateServer(
    connection:,
    first_event:,
    early_script:,
    early_prepare:,
    early_run:,
    early_settle:,
    early_copy:,
    early_housekeeping_run:,
    early_housekeeping_script:,
    connected_event:,
    late_request:,
  ))
}

fn stop_late_server(outcome: LateServer) -> Result(Nil, String) {
  stop_connection(outcome.connection)
}
