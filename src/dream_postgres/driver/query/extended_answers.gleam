//// The answers of the server in the Extended Query flow: ParseComplete,
//// ParameterDescription, RowDescription, BindComplete, CloseComplete and the
//// rows of Execute.

import dream_postgres/driver/message.{
  type BackendMessage, BindComplete, CloseComplete, CommandComplete, DataRow,
  EmptyQueryResponse, NoData, ParameterDescriptions, ParseComplete,
  ReadyForQuery, RowDescription,
}
import dream_postgres/driver/query/copy_answers.{copy_answer}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, Machine, Ready, advance, unexpected, wait_with,
}
import dream_postgres/driver/query/result_rows.{
  add_row, complete_command, finish_statement, with_columns,
}
import dream_postgres/driver/query/step.{
  type UnexpectedMessage, ReadingSimpleQueryRows,
}
import gleam/result

pub fn parse_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParseComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

pub fn parameter_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParameterDescriptions(parameters:) ->
      Ok(wait_with(advance(Machine(..machine, parameters:))))
    _ -> unexpected(machine, message)
  }
}

pub fn columns_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    RowDescription(columns:) ->
      Ok(wait_with(advance(with_columns(machine, columns))))
    NoData -> Ok(wait_with(advance(with_columns(machine, []))))
    _ -> unexpected(machine, message)
  }
}

pub fn close_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    CloseComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

pub fn bind_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    BindComplete -> Ok(wait_with(advance(machine)))
    _ -> unexpected(machine, message)
  }
}

/// The answers to an Execute, which end with exactly one of
/// CommandComplete, EmptyQueryResponse, ErrorResponse or the start of a
/// COPY. An empty query gives the empty tag and the count 0.
pub fn execute_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    DataRow(values:) -> add_row(machine, values)
    CommandComplete(tag:) ->
      complete_command(machine, tag)
      |> result.map(advance)
      |> result.map(wait_with)
    EmptyQueryResponse -> Ok(wait_with(advance(machine)))
    _ -> copy_answer(machine, message)
  }
}

pub fn statement_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    RowDescription(columns:) -> {
      let described = with_columns(machine, columns)
      Ok(wait_with(Machine(..described, phase: ReadingSimpleQueryRows)))
    }
    CommandComplete(tag:) -> finish_statement(machine, tag)
    EmptyQueryResponse -> Ok(wait_with(machine))
    ReadyForQuery(status:) -> Ok(Ready(status:, machine:))
    _ -> copy_answer(machine, message)
  }
}
