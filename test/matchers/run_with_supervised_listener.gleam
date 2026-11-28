//// A matcher that starts a listener under a supervisor, behind a closed
//// gate in front of the server of the chosen version, runs work with the
//// gate and the pool of that server, and stops the supervisor and the
//// gate.

import dream_postgres/config
import dream_postgres/error
import dream_postgres/listener.{type ListenerName}
import dream_postgres/pool.{type Connection}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/listener_gate.{
  type Gate, break_gate, start_gate, stop_gate, wait_refused,
}
import fixtures/server_pools.{type ServerPools}
import fixtures/supervisors
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string

/// Start a gate proxy to the server of the chosen version with the gate
/// closed, and a supervisor with the listener of the client tests' config
/// under `name` through the gate. Wait until the gate refused the
/// listener's connection, so its session is not up when `work` starts.
/// Run `work` with the gate and the pool of that server, then stop the
/// supervisor and the gate. The chain goes on with what `work` gives, or
/// fails when a start or `work` fails.
///
/// ## Example
///
/// ```gleam
/// pools
/// |> should
/// |> run_with_supervised_listener(name, fn(gate, _connection) {
///   use _subscription <- result.try(
///     listen(named_listener(name), "jobs", messages)
///     |> result.map_error(error.describe),
///   )
///   open_gate(gate)
///   listen_messages.receive_messages(messages, count: 2, within: 5000)
/// })
/// |> be_ok()
/// |> or_fail_with("Expected the named listener to answer")
/// ```
pub fn run_with_supervised_listener(
  result: MatchResult(ServerPools),
  name: ListenerName,
  work: fn(Gate, Connection) -> Result(a, String),
) -> MatchResult(a) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(pools) -> run_on_chosen(pools, name, work) |> matched
  }
}

fn run_on_chosen(
  pools: ServerPools,
  name: ListenerName,
  work: fn(Gate, Connection) -> Result(a, String),
) -> Result(a, String) {
  use pool <- result.try(server_pools.chosen(pools))
  use #(gate_port, gate) <- result.try(start_gate(pool.port))
  break_gate(gate)
  let outcome = run_behind_gate(gate_port, gate, pool.connection, name, work)
  stop_gate(gate)
  outcome
}

fn run_behind_gate(
  gate_port: Int,
  gate: Gate,
  connection: Connection,
  name: ListenerName,
  work: fn(Gate, Connection) -> Result(a, String),
) -> Result(a, String) {
  use child <- result.try(
    server_pools.config(gate_port)
    |> config.reconnect_delays(
      first_delay_milliseconds: 10,
      longest_delay_milliseconds: 50,
    )
    |> listener.supervised_listener(name:)
    |> result.map_error(error.describe_error),
  )
  use started <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  wait_refused(gate)
  let outcome = work(gate, connection)
  supervisors.stop_supervisor(started.pid)
  outcome
}

fn matched(outcome: Result(a, String)) -> MatchResult(a) {
  case outcome {
    Ok(value) -> MatchOk(value)
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "run_with_supervised_listener",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected the supervised listener to start and the work to succeed",
        )),
      ))
  }
}
