//// The answer that the recorder gives from a recording: the entry that fits a
//// request, and the result that it records.

import dream_postgres/copy/executor
import dream_postgres/copy/request.{type RowFeed}
import dream_postgres/driver/cell.{type TypeDescription}
import dream_postgres/error.{type Reason, RequestNotMatched, RequestNotRecorded}
import dream_postgres/interceptor.{
  type Interceptor, type Outcome, type Request, CopyFrom, CopyTo, Request, Sql,
  Statement,
}
import dream_postgres/query/definition.{type Value}
import dream_postgres/query/runner
import dream_postgres/recorder/recorder_state.{type State, State}
import dream_postgres/recorder/written_entry.{
  feed_rows, recorded_outcome, recorded_sql,
}
import dream_postgres/recording.{
  type RecordedEntry, type RecordedFailure, type RecordedRequest,
  RecordedCopyFrom, RecordedCopyTo, RecordedSql, RecordedStatement,
  WrittenParameters, WrittenRows,
}
import dream_postgres/secrets.{type Secrets}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result

// Runs the interceptors of the recorder on its copy of the request, with
// `outcome` at the end of the chain. Gives the request that reached the
// end, or the copy when an interceptor answered by itself, and the
// outcome that the interceptors made.
pub fn intercepted_copy(
  interceptors: List(Interceptor),
  request: Request,
  outcome: Outcome,
) -> #(Request, Outcome) {
  let reached_end = process.new_subject()
  let changed_outcome =
    runner.intercept(interceptors, request, fn(final_request) {
      process.send(reached_end, final_request)
      outcome
    })
  let final_request = process.receive(reached_end, 0) |> result.unwrap(request)
  #(final_request, changed_outcome)
}

// Answers a request with the next entry of the recording, when the key of
// the request is the key of the entry. A request that the entry does not
// answer leaves the recording as it was.
pub fn take(
  state: State,
  request: Request,
  secrets: Secrets,
) -> #(Outcome, State) {
  let sql = secrets.replace_text(secrets, request.sql)
  case state.waiting {
    [] -> #(Error(RequestNotRecorded(sql:)), state)
    [entry, ..rest] ->
      answered(
        state,
        entry,
        rest,
        answer_of_entry(state, entry, Request(..request, sql:)),
      )
  }
}

fn answered(
  state: State,
  entry: RecordedEntry,
  rest: List(RecordedEntry),
  answer: Result(Outcome, Reason),
) -> #(Outcome, State) {
  case answer {
    Ok(outcome) -> #(outcome, given(state, entry, rest))
    Error(reason) -> #(Error(reason), state)
  }
}

// The saved outcome of the entry, or why the entry does not answer the
// request: its key is another, or its values cannot be written with the
// recorded types, as a live run could not write them.
fn answer_of_entry(
  state: State,
  entry: RecordedEntry,
  request: Request,
) -> Result(Outcome, Reason) {
  let recorded_sql = recorded_sql(entry.request)
  let not_matched = RequestNotMatched(recorded_sql:, sql: request.sql)
  use written <- result.try(
    written_like(request, entry.request)
    |> result.map_error(fn(reason) {
      case request.sql == recorded_sql {
        True -> reason
        False -> not_matched
      }
    }),
  )
  let outcome = recorded_outcome(entry.request)
  let #(final_request, _changed_outcome) =
    intercepted_copy(state.interceptors, written, outcome)
  case state.key(final_request) == entry.key {
    True -> Ok(outcome)
    False -> Error(not_matched)
  }
}

// The state after an entry answered: a failed answer fails the
// transaction, and the first failure is what it failed with. An answer
// that succeeded means no transaction is failed.
fn given(
  state: State,
  entry: RecordedEntry,
  rest: List(RecordedEntry),
) -> State {
  case entry_failure(entry.request) {
    Ok(Nil) -> State(..state, waiting: rest, aborted_by: None)
    Error(failure) ->
      State(
        ..state,
        waiting: rest,
        aborted_by: option.or(state.aborted_by, Some(failure.server_error)),
      )
  }
}

fn entry_failure(request: RecordedRequest) -> Result(Nil, RecordedFailure) {
  case request {
    RecordedStatement(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedSql(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedCopyFrom(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedCopyTo(outcome:, ..) -> result.replace(outcome, Nil)
  }
}

// The request with its values written with the recorded types, as the
// live run wrote them.
fn written_like(
  request: Request,
  recorded: RecordedRequest,
) -> Result(Request, Reason) {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      rows_written_like(rows, columns, recorded)
      |> result.map(fn(rows) {
        Request(..request, kind: CopyFrom(table:, columns:, rows:))
      })
    Statement | Sql | CopyTo ->
      parameters_written_like(request.parameters, recorded)
      |> result.map(fn(parameters) { Request(..request, parameters:) })
  }
}

fn parameters_written_like(
  values: List(Value),
  recorded: RecordedRequest,
) -> Result(List(Value), Reason) {
  case recorded {
    RecordedStatement(
      parameters: Some(WrittenParameters(types: parameter_types, ..)),
      types:,
      ..,
    ) ->
      definition.write_values(values, parameter_types, lookup_of(types))
      |> result.map(fn(written) {
        list.zip(values, parameter_types)
        |> list.map2(written.values, fn(pair, cell) {
          definition.written_as(pair.0, pair.1, cell)
        })
      })
    RecordedStatement(parameters: None, ..)
    | RecordedSql(..)
    | RecordedCopyFrom(..)
    | RecordedCopyTo(..) -> Ok(values)
  }
}

fn rows_written_like(
  rows: RowFeed,
  columns: List(String),
  recorded: RecordedRequest,
) -> Result(RowFeed, Reason) {
  case recorded {
    RecordedCopyFrom(
      rows: Some(WrittenRows(types: column_types, ..)),
      types:,
      ..,
    ) ->
      feed_rows(rows, [])
      |> list.try_map(fn(values) {
        executor.write_row(values, column_types, lookup_of(types), columns)
        |> result.map(fn(fields) {
          list.zip(values, column_types)
          |> list.map2(fields, fn(pair, field) {
            definition.written_as(pair.0, pair.1, executor.field_cell(field))
          })
        })
      })
      |> result.map(request.feed(_, fn(values) { values }))
    RecordedCopyFrom(rows: None, ..)
    | RecordedStatement(..)
    | RecordedSql(..)
    | RecordedCopyTo(..) -> Ok(rows)
  }
}

fn lookup_of(
  types: List(TypeDescription),
) -> fn(Int) -> Result(TypeDescription, Nil) {
  let by_id =
    types
    |> list.map(fn(type_description) {
      #(type_description.id, type_description)
    })
    |> dict.from_list
  dict.get(by_id, _)
}
