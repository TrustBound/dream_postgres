//// Executors for the runner tests that need no server. Each one prepares
//// any SQL to a given statement description, and describes the types of
//// the test catalog (`fixtures/type_catalog`) plus `int4multirange`,
//// `positive_int` and `pair`. A type it does not know fails with
//// `QueryTimeout(stopped_on_server: True)`.

import dream_postgres/error.{type Reason, QueryTimeout}
import dream_postgres/internal/cell.{
  type Cell, type CommandResult, type Format, type StatementDescription,
  type TypeDescription, CommandResult,
}
import dream_postgres/internal/runner.{type Executor, type RunFailure, Executor}
import fixtures/type_catalog
import gleam/list
import gleam/option.{type Option}
import gleam/result

/// An executor whose every run gives `rows`.
///
/// ## Example
///
/// ```gleam
/// fake_executor.returning(posts.statement(), [posts.cells(1, "First")])
/// ```
pub fn returning(
  statement: StatementDescription,
  rows: List(List(Cell)),
) -> Executor {
  Executor(
    prepare: fn(_sql, _name) { Ok(statement) },
    describe_current: fn(_sql, _name) { Ok(statement) },
    describe_type:,
    run: fn(_sql, _name, _parameters, _formats) { Ok(command_result(rows)) },
  )
}

/// An executor that prepares and runs only a query with the name `name`.
/// A prepare with another name fails with
/// `QueryTimeout(stopped_on_server: True)`, and a run with another name
/// gives no row.
///
/// ## Example
///
/// ```gleam
/// fake_executor.returning_for_name(
///   posts.statement(),
///   Some("post.find"),
///   [posts.cells(1, "First")],
/// )
/// ```
pub fn returning_for_name(
  statement: StatementDescription,
  name: Option(String),
  rows: List(List(Cell)),
) -> Executor {
  let prepare = fn(_sql, given_name) {
    case given_name == name {
      True -> Ok(statement)
      False -> Error(QueryTimeout(stopped_on_server: True))
    }
  }
  Executor(
    prepare:,
    describe_current: prepare,
    describe_type:,
    run: fn(_sql, given_name, _parameters, _formats) {
      case given_name == name {
        True -> Ok(command_result(rows))
        False -> Ok(command_result([]))
      }
    },
  )
}

/// An executor whose run gives `rows` only for exactly `parameters` in
/// exactly `formats`, and no row for any other run.
///
/// ## Example
///
/// ```gleam
/// fake_executor.returning_for(
///   posts.statement(),
///   [Binary(<<7:size(32)>>)],
///   [BinaryFormat, BinaryFormat],
///   [posts.cells(1, "First")],
/// )
/// ```
pub fn returning_for(
  statement: StatementDescription,
  parameters: List(Cell),
  formats: List(Format),
  rows: List(List(Cell)),
) -> Executor {
  Executor(
    prepare: fn(_sql, _name) { Ok(statement) },
    describe_current: fn(_sql, _name) { Ok(statement) },
    describe_type:,
    run: fn(_sql, _name, given_parameters, given_formats) {
      case given_parameters == parameters && given_formats == formats {
        True -> Ok(command_result(rows))
        False -> Ok(command_result([]))
      }
    },
  )
}

/// An executor whose every run fails with `failure`.
///
/// ## Example
///
/// ```gleam
/// fake_executor.failing_run(
///   posts.statement(),
///   RunFailed(QueryTimeout(stopped_on_server: True)),
/// )
/// ```
pub fn failing_run(
  statement: StatementDescription,
  failure: RunFailure,
) -> Executor {
  Executor(
    prepare: fn(_sql, _name) { Ok(statement) },
    describe_current: fn(_sql, _name) { Ok(statement) },
    describe_type:,
    run: fn(_sql, _name, _parameters, _formats) { Error(failure) },
  )
}

/// An executor whose run fails with `failure` for exactly `parameters`, and
/// gives `rows` for any other parameters.
///
/// ## Example
///
/// ```gleam
/// fake_executor.failing_for_parameters(
///   statement,
///   [Binary(<<7:size(32)>>)],
///   StatementChanged(changed_statement),
///   [[Binary(<<1:size(32)>>)]],
/// )
/// ```
pub fn failing_for_parameters(
  statement: StatementDescription,
  parameters: List(Cell),
  failure: RunFailure,
  rows: List(List(Cell)),
) -> Executor {
  Executor(
    prepare: fn(_sql, _name) { Ok(statement) },
    describe_current: fn(_sql, _name) { Ok(statement) },
    describe_type:,
    run: fn(_sql, _name, given_parameters, _formats) {
      case given_parameters == parameters {
        True -> Error(failure)
        False -> Ok(command_result(rows))
      }
    },
  )
}

/// An executor whose prepare fails with `reason`. Its run gives no row.
///
/// ## Example
///
/// ```gleam
/// fake_executor.failing_prepare(QueryTimeout(stopped_on_server: True))
/// ```
pub fn failing_prepare(reason: Reason) -> Executor {
  Executor(
    prepare: fn(_sql, _name) { Error(reason) },
    describe_current: fn(_sql, _name) { Error(reason) },
    describe_type:,
    run: fn(_sql, _name, _parameters, _formats) { Ok(command_result([])) },
  )
}

fn command_result(rows: List(List(Cell))) -> CommandResult {
  CommandResult(rows:, tag: "SELECT", count: list.length(rows))
}

fn describe_type(type_id: Int) -> Result(TypeDescription, Reason) {
  [
    type_catalog.int4_multirange(),
    type_catalog.positive_int(),
    type_catalog.pair(),
    ..type_catalog.all()
  ]
  |> list.find(fn(description) { description.id == type_id })
  |> result.replace_error(QueryTimeout(stopped_on_server: True))
}
