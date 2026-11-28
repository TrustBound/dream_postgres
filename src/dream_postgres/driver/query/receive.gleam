//// One message of the server in a step: the phase of the step picks the answer.

import dream_postgres/driver/message.{
  type BackendMessage, ErrorResponse, NoticeResponse, NotificationResponse,
  ParameterStatus, ReadyForQuery,
}
import dream_postgres/driver/query/copy_answers.{
  copy_end_answer, copy_out_answer,
}
import dream_postgres/driver/query/extended_answers.{
  bind_answer, close_answer, columns_answer, execute_answer, parameter_answer,
  parse_answer, statement_answer,
}
import dream_postgres/driver/query/machine.{
  type Machine, type Transition, Ready, keep, server_error, unexpected,
}
import dream_postgres/driver/query/simple_query_answers.{simple_query_row_answer}
import dream_postgres/driver/query/step.{
  type UnexpectedMessage, AwaitingBindComplete, AwaitingCloseComplete,
  AwaitingCopyComplete, AwaitingParameterDescription, AwaitingParseComplete,
  AwaitingPortalColumns, AwaitingReadyForQuery, AwaitingReadyForQueryAfterError,
  AwaitingStatementColumns, AwaitingStatementResult, CopyingIn, Notice,
  Notification, ParameterChanged, ReadingCopyOut, ReadingExecuteRows,
  ReadingSimpleQueryRows,
}

fn ready_answer(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ReadyForQuery(status:) -> Ok(Ready(status:, machine:))
    _ -> unexpected(machine, message)
  }
}

/// Takes the messages that every phase allows, then gives the others to
/// the handler of the phase.
pub fn receive(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case message {
    ParameterStatus(name:, value:) ->
      Ok(keep(machine, ParameterChanged(name:, value:)))
    NoticeResponse(report:) -> Ok(keep(machine, Notice(report:)))
    NotificationResponse(process_id:, channel:, payload:) ->
      Ok(keep(machine, Notification(process_id:, channel:, payload:)))
    ErrorResponse(report:) -> server_error(machine, report)
    _ -> receive_in_phase(machine, message)
  }
}

fn receive_in_phase(
  machine: Machine,
  message: BackendMessage,
) -> Result(Transition, UnexpectedMessage) {
  case machine.phase {
    AwaitingParseComplete -> parse_answer(machine, message)
    AwaitingParameterDescription -> parameter_answer(machine, message)
    AwaitingStatementColumns | AwaitingPortalColumns ->
      columns_answer(machine, message)
    AwaitingBindComplete -> bind_answer(machine, message)
    AwaitingCloseComplete -> close_answer(machine, message)
    ReadingExecuteRows -> execute_answer(machine, message)
    AwaitingStatementResult -> statement_answer(machine, message)
    ReadingSimpleQueryRows -> simple_query_row_answer(machine, message)
    ReadingCopyOut -> copy_out_answer(machine, message)
    AwaitingCopyComplete | CopyingIn -> copy_end_answer(machine, message)
    AwaitingReadyForQuery | AwaitingReadyForQueryAfterError ->
      ready_answer(machine, message)
  }
}
