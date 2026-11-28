//// The entry that the recorder writes for a request that went to the server:
//// its SQL, its parameters, its rows and its ending.

import dream_postgres/error.{type Reason}
import dream_postgres/interceptor.{
  type Outcome, type Request, CopyFrom, CopyFromAnswer, CopyTo, CopyToAnswer,
  Request, Sql, SqlAnswer, Statement, StatementAnswer,
}
import dream_postgres/internal/cell.{
  type Cell, type CommandResult, type StatementDescription, type TypeDescription,
  CommandResult,
}
import dream_postgres/internal/copy_request.{
  type RowFeed, CopyRows, RecordedRows,
}
import dream_postgres/internal/query.{
  type Value, type WriteEvent, SecretWritten, TypeChecked, TypeLookedUp, Written,
}
import dream_postgres/internal/recorder/recorder_state.{
  type WriteSeen, WriteSeen,
}
import dream_postgres/recording.{
  type RecordedFailure, type RecordedRequest, type WrittenParameter,
  type WrittenParameters, type WrittenRows, RecordedCopyFrom, RecordedCopyTo,
  RecordedSql, RecordedStatement, RecordedStream, SecretCell, StatementReply,
  WrittenParameters, WrittenRows,
}
import dream_postgres/secrets.{type Secrets}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn watched_request(request: Request, seen: Subject(WriteSeen)) -> Request {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      Request(
        ..request,
        kind: CopyFrom(
          table:,
          columns:,
          rows: copy_request.map_rows(rows, fn(row_number, values) {
            watched_values(values, row_number, seen)
          }),
        ),
      )
    Statement | Sql | CopyTo ->
      Request(
        ..request,
        parameters: watched_values(request.parameters, 0, seen),
      )
  }
}

fn watched_values(
  values: List(Value),
  row_number: Int,
  seen: Subject(WriteSeen),
) -> List(Value) {
  list.index_map(values, fn(value, position) {
    query.watch(value, fn(event) {
      process.send(seen, WriteSeen(row_number:, position:, event:))
    })
  })
}

pub fn receive_all(
  seen: Subject(WriteSeen),
  received: List(WriteSeen),
) -> List(WriteSeen) {
  case process.receive(seen, 0) {
    Ok(write_seen) -> receive_all(seen, [write_seen, ..received])
    Error(Nil) -> list.reverse(received)
  }
}

// The request with each value that was written set to what it was
// written as.
pub fn written_request(request: Request, events: List(WriteSeen)) -> Request {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      Request(
        ..request,
        kind: CopyFrom(
          table:,
          columns:,
          rows: feed_rows(rows, [])
            |> list.index_map(fn(values, row_number) {
              written_values(values, events, row_number)
            })
            |> copy_request.feed(fn(values) { values }),
        ),
      )
    Statement | Sql | CopyTo ->
      Request(
        ..request,
        parameters: written_values(request.parameters, events, 0),
      )
  }
}

fn written_values(
  values: List(Value),
  events: List(WriteSeen),
  row_number: Int,
) -> List(Value) {
  list.index_map(values, fn(value, position) {
    let seen_here =
      events
      |> list.filter(fn(seen) {
        seen.row_number == row_number && seen.position == position
      })
      |> list.map(fn(seen) { seen.event })
    written_value(
      value,
      list.filter_map(seen_here, checked_type) |> list.first,
      list.filter_map(seen_here, write_of) |> list.first,
    )
  })
}

fn written_value(
  value: Value,
  checked: Result(TypeDescription, Nil),
  write: Result(WriteEvent, Nil),
) -> Value {
  case checked, write {
    Ok(type_description), Ok(Written(cell:)) ->
      query.written_as(value, type_description, cell)
    Ok(type_description), Ok(SecretWritten(..)) ->
      query.written_secret(value, type_description)
    Ok(_), Ok(TypeChecked(..))
    | Ok(_), Ok(TypeLookedUp(..))
    | Ok(_), Error(Nil)
    | Error(Nil), _
    -> value
  }
}

fn checked_type(event: WriteEvent) -> Result(TypeDescription, Nil) {
  case event {
    TypeChecked(type_description:) -> Ok(type_description)
    TypeLookedUp(..) | Written(..) | SecretWritten(..) -> Error(Nil)
  }
}

fn write_of(event: WriteEvent) -> Result(WriteEvent, Nil) {
  case event {
    Written(..) | SecretWritten(..) -> Ok(event)
    TypeChecked(..) | TypeLookedUp(..) -> Error(Nil)
  }
}

// Every type that the writes and the answer needed, each one time, in the
// order of their IDs.
pub fn every_type(
  events: List(WriteSeen),
  answer_types: List(TypeDescription),
) -> List(TypeDescription) {
  events
  |> list.filter_map(fn(seen) { event_type(seen.event) })
  |> list.append(answer_types)
  |> list.map(fn(type_description) { #(type_description.id, type_description) })
  |> dict.from_list
  |> dict.values
  |> list.sort(fn(left, right) { int.compare(left.id, right.id) })
}

fn event_type(event: WriteEvent) -> Result(TypeDescription, Nil) {
  case event {
    TypeChecked(type_description:) | TypeLookedUp(type_description:) ->
      Ok(type_description)
    Written(..) | SecretWritten(..) -> Error(Nil)
  }
}

pub fn feed_rows(rows: RowFeed, read: List(List(Value))) -> List(List(Value)) {
  case copy_request.next_row(rows) {
    Some(#(values, rest)) -> feed_rows(rest, [values, ..read])
    None -> list.reverse(read)
  }
}

pub fn secret_free_outcome(
  secrets: Secrets,
  outcome: Outcome,
) -> Result(Outcome, Reason) {
  case outcome {
    Ok(StatementAnswer(description:, types:, result:)) ->
      secrets.replace_columns(secrets, description, types, result.rows)
      |> result.map(fn(rows) {
        Ok(StatementAnswer(
          description:,
          types:,
          result: CommandResult(..result, rows:),
        ))
      })
    Ok(CopyToAnswer(
      description:,
      types:,
      rows: CopyRows(source: RecordedRows(rows:, ending:), watchers:),
    )) ->
      secrets.replace_columns(secrets, description, types, rows)
      |> result.map(fn(rows) {
        Ok(CopyToAnswer(
          description:,
          types:,
          rows: CopyRows(source: RecordedRows(rows:, ending:), watchers:),
        ))
      })
    Ok(CopyToAnswer(..))
    | Ok(SqlAnswer(..))
    | Ok(CopyFromAnswer(..))
    | Error(_) -> Ok(outcome)
  }
}

pub fn recorded_request(
  request: Request,
  outcome: Outcome,
  types: List(TypeDescription),
) -> Option(RecordedRequest) {
  case request.kind, outcome {
    Statement, Ok(StatementAnswer(description:, result:, ..)) ->
      Some(recorded_statement(request, types, description, result))
    Sql, Ok(SqlAnswer(results:)) ->
      Some(RecordedSql(sql: request.sql, outcome: Ok(results)))
    CopyFrom(rows:, ..), Ok(CopyFromAnswer(count:)) ->
      Some(RecordedCopyFrom(
        sql: request.sql,
        rows: written_rows(rows),
        types:,
        outcome: Ok(count),
      ))
    CopyTo,
      Ok(CopyToAnswer(
        description:,
        rows: CopyRows(source: RecordedRows(rows:, ending:), ..),
        ..,
      ))
    -> recorded_copy_to(request, types, description, rows, ending)
    // An answer of another kind than the request: it is not one that
    // PostgreSQL gave, so it is not saved.
    Statement, Ok(_) | Sql, Ok(_) | CopyFrom(..), Ok(_) | CopyTo, Ok(_) -> None
    Statement, Error(reason)
    | Sql, Error(reason)
    | CopyFrom(..), Error(reason)
    | CopyTo, Error(reason)
    ->
      recording.recorded_failure(reason)
      |> option.map(failed_request(request, _, types))
  }
}

fn recorded_statement(
  request: Request,
  types: List(TypeDescription),
  description: StatementDescription,
  result: CommandResult,
) -> RecordedRequest {
  RecordedStatement(
    sql: request.sql,
    parameters: written_parameters(request.parameters),
    types:,
    outcome: Ok(StatementReply(description:, result:)),
  )
}

fn recorded_copy_to(
  request: Request,
  types: List(TypeDescription),
  description: StatementDescription,
  rows: List(List(Cell)),
  ending: Result(Nil, Reason),
) -> Option(RecordedRequest) {
  recorded_ending(ending)
  |> option.map(fn(recorded_end) {
    RecordedCopyTo(
      sql: request.sql,
      types:,
      outcome: Ok(RecordedStream(description:, rows:, ending: recorded_end)),
    )
  })
}

fn failed_request(
  request: Request,
  failure: RecordedFailure,
  types: List(TypeDescription),
) -> RecordedRequest {
  case request.kind {
    Statement ->
      RecordedStatement(
        sql: request.sql,
        parameters: written_parameters(request.parameters),
        types:,
        outcome: Error(failure),
      )
    Sql -> RecordedSql(sql: request.sql, outcome: Error(failure))
    CopyFrom(rows:, ..) ->
      RecordedCopyFrom(
        sql: request.sql,
        rows: written_rows(rows),
        types:,
        outcome: Error(failure),
      )
    CopyTo -> RecordedCopyTo(sql: request.sql, types:, outcome: Error(failure))
  }
}

fn recorded_ending(
  ending: Result(Nil, Reason),
) -> Option(Result(Nil, RecordedFailure)) {
  case ending {
    Ok(Nil) -> Some(Ok(Nil))
    Error(reason) -> recording.recorded_failure(reason) |> option.map(Error)
  }
}

// The parameters as written, when each one was written. A secret
// parameter is kept as its codec, with no cell.
fn written_parameters(values: List(Value)) -> Option(WrittenParameters) {
  values
  |> list.try_map(fn(value) {
    case query.written(value) {
      Some(query.WrittenCell(type_description:, cell:)) ->
        Ok(#(type_description, recording.WrittenCell(cell:)))
      Some(query.WrittenSecret(type_description:)) ->
        Ok(#(type_description, SecretCell(codec: query.codec_name(value))))
      None -> Error(Nil)
    }
  })
  |> result.map(fn(written: List(#(TypeDescription, WrittenParameter))) {
    let #(types, parameters) = list.unzip(written)
    WrittenParameters(types:, parameters:)
  })
  |> option.from_result
}

// The rows as written, when each field of each row was written. A field
// of a `copy_from` row is never secret: `codec.field` makes it.
fn written_rows(rows: RowFeed) -> Option(WrittenRows) {
  feed_rows(rows, [])
  |> list.try_map(fn(values) {
    list.try_map(values, fn(value) {
      case query.written(value) {
        Some(query.WrittenCell(type_description:, cell:)) ->
          Ok(#(type_description, cell))
        Some(query.WrittenSecret(..)) | None -> Error(Nil)
      }
    })
  })
  |> result.map(fn(written) {
    WrittenRows(
      types: written
        |> list.first
        |> result.map(fn(row) { list.map(row, fn(field) { field.0 }) })
        |> result.unwrap([]),
      rows: list.map(written, list.map(_, fn(field) { field.1 })),
    )
  })
  |> option.from_result
}

pub fn recorded_sql(request: RecordedRequest) -> String {
  case request {
    RecordedStatement(sql:, ..)
    | RecordedSql(sql:, ..)
    | RecordedCopyFrom(sql:, ..)
    | RecordedCopyTo(sql:, ..) -> sql
  }
}

pub fn recorded_outcome(recorded: RecordedRequest) -> Outcome {
  case recorded {
    RecordedStatement(types:, outcome:, ..) ->
      outcome
      |> result.map(fn(reply) {
        StatementAnswer(
          description: reply.description,
          types:,
          result: reply.result,
        )
      })
      |> result.map_error(recording.failure_reason)
    RecordedSql(outcome:, ..) ->
      outcome
      |> result.map(SqlAnswer)
      |> result.map_error(recording.failure_reason)
    RecordedCopyFrom(outcome:, ..) ->
      outcome
      |> result.map(CopyFromAnswer)
      |> result.map_error(recording.failure_reason)
    RecordedCopyTo(types:, outcome:, ..) ->
      outcome
      |> result.map(fn(stream) {
        CopyToAnswer(
          description: stream.description,
          types:,
          rows: CopyRows(
            source: RecordedRows(
              rows: stream.rows,
              ending: result.map_error(stream.ending, recording.failure_reason),
            ),
            watchers: [],
          ),
        )
      })
      |> result.map_error(recording.failure_reason)
  }
}
