//// A request that the process does not run: why, and what the caller gets.

import dream_postgres/driver/connection/copy_exchange.{
  CopyFaultFailed, StartRefused,
}
import dream_postgres/driver/connection/copy_process.{answer_session}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  type Request, type StatementRequest, CopyRequest, HousekeepingRunRequest,
  HousekeepingSimpleQueryRequest, PrepareStatement, RunStatement,
  SettledStatusRequest, SimpleQueryRequest, StatementRequest,
}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type PrepareError, type Refusal, type RequestFailure,
  type RunError, type SettleError, type SimpleQueryError, HousekeepingFailed,
  HousekeepingNotConnected, PrepareFailed, PrepareNotConnected,
  PrepareUnencodable, RefusedNotConnected, RefusedWithFailure, RunFailed,
  RunNotConnected, RunUnencodable, SettleFailed, SettleNotConnected,
  SimpleQueryNotConnected, SimpleQueryRequestFailed, SimpleQueryUnencodable,
}
import dream_postgres/driver/connection/state.{
  type Running, type Ticket, RunningCachedRun, RunningCopy,
  RunningHousekeepingRun, RunningHousekeepingSimpleQuery, RunningNamedPrepare,
  RunningPrepare, RunningRun, RunningSimpleQuery,
}
import dream_postgres/driver/encode.{encode}
import dream_postgres/driver/message.{type EncodeError, type FrontendMessage}
import gleam/bit_array.{concat}
import gleam/erlang/process
import gleam/list.{try_map}
import gleam/option.{None}
import gleam/result

pub fn refuse_ticket(ticket: Ticket, refusal: Refusal) -> Nil {
  process.cancel_timer(ticket.timer)
  refuse(ticket.request, refusal)
}

/// Refuses a request that the process does not run, with the request's
/// own error.
fn refuse(request: Request, refusal: Refusal) -> Nil {
  case request {
    StatementRequest(statement) -> refuse_statement(statement, refusal)
    SettledStatusRequest(reply: reply_to) ->
      reply(reply_to, Error(settle_refusal(refusal)))
    SimpleQueryRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(simple_query_refusal(refusal)))
    HousekeepingRunRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(housekeeping_refusal(refusal)))
    HousekeepingSimpleQueryRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(housekeeping_refusal(refusal)))
    CopyRequest(reply: reply_to, ..) ->
      reply(reply_to, Error(StartRefused(refusal)))
  }
}

fn refuse_statement(statement: StatementRequest, refusal: Refusal) -> Nil {
  case statement {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(prepare_refusal(refusal)))
    RunStatement(details) -> reply(details.reply, Error(run_refusal(refusal)))
  }
}

/// Fails the request that runs: the connection broke, or its deadline
/// passed.
pub fn refuse_running(running: Running, failure: RequestFailure) -> Nil {
  case running {
    RunningPrepare(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareFailed(failure)))
    RunningRun(reply: reply_to, ..) ->
      reply(reply_to, Error(RunFailed(failure)))
    RunningSimpleQuery(reply: reply_to, ..) ->
      reply(reply_to, Error(SimpleQueryRequestFailed(failure)))
    RunningHousekeepingRun(reply: reply_to, ..) ->
      reply(reply_to, Error(HousekeepingFailed(failure)))
    RunningHousekeepingSimpleQuery(reply: reply_to, ..) ->
      reply(reply_to, Error(HousekeepingFailed(failure)))
    RunningNamedPrepare(request:, ..) ->
      refuse_statement(request, RefusedWithFailure(failure))
    RunningCachedRun(details:, ..) ->
      reply(details.reply, Error(RunFailed(failure)))
    RunningCopy(session:, ..) ->
      answer_session(session, Error(CopyFaultFailed(failure)), None)
  }
}

fn settle_refusal(refusal: Refusal) -> SettleError {
  case refusal {
    RefusedWithFailure(failure) -> SettleFailed(failure)
    RefusedNotConnected(error) -> SettleNotConnected(error)
  }
}

fn simple_query_refusal(refusal: Refusal) -> SimpleQueryError {
  case refusal {
    RefusedWithFailure(failure) -> SimpleQueryRequestFailed(failure)
    RefusedNotConnected(error) -> SimpleQueryNotConnected(error)
  }
}

fn housekeeping_refusal(refusal: Refusal) -> HousekeepingError {
  case refusal {
    RefusedWithFailure(failure) -> HousekeepingFailed(failure)
    RefusedNotConnected(error) -> HousekeepingNotConnected(error)
  }
}

fn prepare_refusal(refusal: Refusal) -> PrepareError {
  case refusal {
    RefusedWithFailure(failure) -> PrepareFailed(failure)
    RefusedNotConnected(error) -> PrepareNotConnected(error)
  }
}

fn run_refusal(refusal: Refusal) -> RunError {
  case refusal {
    RefusedWithFailure(failure) -> RunFailed(failure)
    RefusedNotConnected(error) -> RunNotConnected(error)
  }
}

pub fn simple_query_unencodable(
  reply_to: ReplyTo(Result(List(Outcome), SimpleQueryError)),
  error: EncodeError,
) -> Nil {
  reply(reply_to, Error(SimpleQueryUnencodable(error)))
}

pub fn statement_unencodable(
  statement: StatementRequest,
  error: EncodeError,
) -> Nil {
  case statement {
    PrepareStatement(reply: reply_to, ..) ->
      reply(reply_to, Error(PrepareUnencodable(error)))
    RunStatement(details) -> reply(details.reply, Error(RunUnencodable(error)))
  }
}

pub fn encode_all(
  messages: List(FrontendMessage),
) -> Result(BitArray, EncodeError) {
  try_map(messages, encode) |> result.map(concat)
}

pub fn statement_sql(statement: StatementRequest) -> String {
  case statement {
    PrepareStatement(sql:, ..) -> sql
    RunStatement(details) -> details.sql
  }
}
