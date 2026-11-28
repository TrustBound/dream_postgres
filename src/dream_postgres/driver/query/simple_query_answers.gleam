//// The answers of the server in the Simple Query flow.

import dream_postgres/driver/message.{
  type BackendMessage, CommandComplete, DataRow,
}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, unexpected,
}
import dream_postgres/driver/query/result_rows.{add_row, finish_statement}
import dream_postgres/driver/query/step.{type UnexpectedMessage}

pub fn simple_query_row_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    DataRow(values:) -> add_row(machine, values)
    CommandComplete(tag:) -> finish_statement(machine, tag)
    _ -> unexpected(machine, message)
  }
}
