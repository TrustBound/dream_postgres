//// The Simple Query protocol: one Query message, and the results of each of its
//// statements.

import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/message.{type BackendMessage, Query}
import dream_postgres/driver/query/extended_query.{to_step}
import dream_postgres/driver/query/machine.{
  type Machine, ColumnFormats, SimpleProtocol, new_machine, outcome, step_result,
}
import dream_postgres/driver/query/receive.{receive}
import dream_postgres/driver/query/step.{
  type HousekeepingStart, type Outcome, type SimpleQueryFailure, type Start,
  type StatementResult, type Step, type UnexpectedMessage,
  AwaitingStatementResult, HousekeepingStart, SimpleQueryFailure, Start,
}
import dream_postgres/internal/cell.{type TransactionStatus}
import gleam/list.{reverse}
import gleam/result

/// The state of a simple query step.
pub opaque type SimpleQueryState {
  SimpleQueryState(machine: Machine)
}

/// Starts a simple query: one Query message that holds one or more SQL
/// statements.
///
/// ## Parameters
///
/// - `sql`: the SQL statements
///
/// ## Returns
///
/// The messages to send and the state for `step_simple_query`.
pub fn start_simple_query(sql: String) -> Start(SimpleQueryState) {
  Start(messages: [Query(sql)], state: simple_query_state())
}

/// Starts to run a driver housekeeping statement with the simple query
/// protocol, as `start_simple_query`.
///
/// ## Parameters
///
/// - `sql`: the housekeeping statement
///
/// ## Returns
///
/// The bytes to send and the state for `step_simple_query`.
pub fn start_housekeeping_simple_query(
  sql: HousekeepingSql,
) -> HousekeepingStart(SimpleQueryState) {
  HousekeepingStart(
    bytes: housekeeping_sql.query_message(sql),
    state: simple_query_state(),
  )
}

fn simple_query_state() -> SimpleQueryState {
  new_machine(SimpleProtocol, AwaitingStatementResult, [], ColumnFormats([]))
  |> SimpleQueryState
}

/// Reads one message from the server in a simple query step. The outcome
/// has one result for each statement, in order, with each cell in the
/// format that its RowDescription gives (text, except for a `FETCH` from a
/// binary cursor). An empty simple query, with only spaces or comments, gets an
/// EmptyQueryResponse and gives no results. After an error, the results of
/// the statements before it come with the failure.
///
/// ## Parameters
///
/// - `state`: the state from `start_simple_query` or from the last step
/// - `message`: the message from the server
///
/// ## Returns
///
/// - `Ok(step)`: what to do next, or the outcome with the result of each
///   statement
/// - `Error(UnexpectedMessage)`: the protocol does not allow the message
///   here
pub fn step_simple_query(
  state: SimpleQueryState,
  message: BackendMessage,
) -> Result(
  Step(SimpleQueryState, Outcome(List(StatementResult), SimpleQueryFailure)),
  UnexpectedMessage,
) {
  receive(state.machine, message)
  |> result.map(to_step(_, SimpleQueryState, simple_query_outcome))
}

fn simple_query_outcome(
  machine: Machine,
  status: TransactionStatus,
) -> Outcome(List(StatementResult), SimpleQueryFailure) {
  let completed = reverse(machine.results)
  step_result(machine, completed)
  |> result.map_error(SimpleQueryFailure(completed, _))
  |> outcome(machine, status, _)
}
