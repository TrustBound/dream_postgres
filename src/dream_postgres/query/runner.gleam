//// The runners: they prepare a query, check its parameters and its row
//// reader against the prepared statement, run it, and read its rows. A
//// runner works on an `Executor`, the three calls it needs from a
//// connection, so the same steps serve a pooled connection, a transaction,
//// and a test. Each query goes through the interceptors first, and the
//// last step of the chain prepares, checks and runs it.

import dream_errors.{type Error}
import dream_postgres/codec/codec_type.{type TypeLookup}
import dream_postgres/driver/cell.{
  type Cell, type ColumnDescription, type CommandResult, type Format,
  type StatementDescription, type TypeDescription, Array, Base, Composite,
  Domain, Enum, Multirange, Pseudo, Range,
}
import dream_postgres/error.{
  type PostgresError, type Reason, InterceptorFailed, PostgresError, TooManyRows,
  UnknownType,
}
import dream_postgres/interceptor.{
  type Answer, type Interceptor, type Outcome, type Request, CopyFromAnswer,
  CopyToAnswer, Request, SqlAnswer, Statement, StatementAnswer,
}
import dream_postgres/query/definition.{type Query}
import dream_postgres/row/reader.{type CheckedRow, type Row, DescribedColumn}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// What a runner needs from a connection.
pub type Executor {
  Executor(
    /// Prepares the SQL, with the name of its query when it has one, and
    /// gives its description.
    prepare: fn(String, Option(String)) -> Result(StatementDescription, Reason),
    /// Prepares the SQL and gives the server's description of it now, also
    /// when the connection holds the statement in its cache. The checks of
    /// `verify_queries` use it, so a changed schema always shows.
    describe_current: fn(String, Option(String)) ->
      Result(StatementDescription, Reason),
    /// Gives what a type OID is.
    describe_type: fn(Int) -> Result(TypeDescription, Reason),
    /// Runs the SQL, with the name of its query when it has one, with the
    /// written parameters, and asks for each column in the given format.
    run: fn(String, Option(String), List(Cell), List(Format)) ->
      Result(CommandResult, RunFailure),
  )
}

/// The lowest layer of the chain of a runner: what answers a request after
/// the last interceptor.
pub type LowestLayer {
  /// The database: the last step prepares the SQL of the request, checks
  /// it and runs it with the executor.
  DatabaseLayer(executor: Executor)
  /// A function that answers each request with no database, such as the
  /// recording of a recorder in playback mode.
  AnsweringLayer(answer: fn(Request) -> Outcome)
}

/// Why a run did not give a result.
pub type RunFailure {
  /// The server made the statement prepare again, and the description
  /// changed. The runner checks again and runs again.
  StatementChanged(description: StatementDescription)
  /// The run failed.
  RunFailed(reason: Reason)
}

/// Runs a query through the interceptors and reads every row.
pub fn all(
  query: Query,
  reader: Row(a),
  lowest: LowestLayer,
  interceptors: List(Interceptor),
) -> Result(List(a), Error(PostgresError)) {
  {
    use ran <- result.try(
      run_command(query, lowest, interceptors, fn(columns, cache, lookup) {
        check_reader(reader, columns, cache, lookup)
      }),
    )
    list.try_map(ran.result.rows, fn(cells) {
      reader.read(ran.checked, cells, ran.lookup)
    })
  }
  |> result.map_error(failure(query, _))
}

/// Runs a query through the interceptors that gives exactly one row, and
/// reads it. No row is `NotFound`, and more than one row is `TooManyRows`.
pub fn one(
  query: Query,
  reader: Row(a),
  lowest: LowestLayer,
  interceptors: List(Interceptor),
) -> Result(a, Error(PostgresError)) {
  use found <- result.try(maybe_one(query, reader, lowest, interceptors))
  case found {
    Some(value) -> Ok(value)
    None -> Error(error.no_rows_error(definition.name(query)))
  }
}

/// Runs a query through the interceptors that gives at most one row, and
/// reads it. More than one row is `TooManyRows`.
pub fn maybe_one(
  query: Query,
  reader: Row(a),
  lowest: LowestLayer,
  interceptors: List(Interceptor),
) -> Result(Option(a), Error(PostgresError)) {
  use values <- result.try(all(query, reader, lowest, interceptors))
  case values {
    [] -> Ok(None)
    [value] -> Ok(Some(value))
    _ -> Error(failure(query, TooManyRows(count: list.length(values))))
  }
}

/// Runs a command through the interceptors and gives the row count of its
/// tag, for example 3 for `UPDATE 3`. The rows of a command that gives
/// rows are not read.
pub fn affected(
  query: Query,
  lowest: LowestLayer,
  interceptors: List(Interceptor),
) -> Result(Int, Error(PostgresError)) {
  run_command(query, lowest, interceptors, no_reader)
  |> result.map(fn(ran) { ran.result.count })
  |> result.map_error(failure(query, _))
}

/// Prepares a query and checks it as a run of `all` checks it: its
/// parameters' codecs against the parameter types, and the reader against
/// the columns. The query does not run, and goes through no interceptor.
pub fn check_rows(
  query: Query,
  reader: Row(a),
  executor: Executor,
) -> Result(Nil, Error(PostgresError)) {
  check_statement(query, executor, fn(columns, cache, lookup) {
    check_reader(reader, columns, cache, lookup)
  })
}

/// Prepares a command and checks its parameters' codecs against the
/// parameter types, as a run of `affected` checks them. The command does
/// not run, and goes through no interceptor.
pub fn check_command(
  query: Query,
  executor: Executor,
) -> Result(Nil, Error(PostgresError)) {
  check_statement(query, executor, no_reader)
}

/// Sends the request through the interceptors, in the order they were
/// added: the first one gets the request first. `last` is the end of the
/// chain, which runs the request on the database.
pub fn intercept(
  interceptors: List(Interceptor),
  request: Request,
  last: fn(Request) -> Outcome,
) -> Outcome {
  let chain =
    list.fold_right(interceptors, last, fn(next, outer_interceptor) {
      fn(request) { outer_interceptor(request, next) }
    })
  chain(request)
}

// --- The steps ---------------------------------------------------------------------

type Ran(checked) {
  Ran(result: CommandResult, checked: checked, lookup: TypeLookup)
}

// Checks the columns of a statement before the run, and gives what the
// read needs and the format of each column.
type ColumnCheck(checked) =
  fn(List(ColumnDescription), TypeCache, TypeLookup) ->
    Result(#(checked, List(Format)), Reason)

// Sends the request of the query through the interceptors, then checks the
// columns of the answer with the types that it holds. The answer of an
// interceptor goes through the same check as the answer of the database.
fn run_command(
  query: Query,
  lowest: LowestLayer,
  interceptors: List(Interceptor),
  check_columns: ColumnCheck(checked),
) -> Result(Ran(checked), Reason) {
  let request =
    Request(
      sql: definition.sql(query),
      name: definition.name(query),
      parameters: definition.values(query),
      kind: Statement,
    )
  use answer <- result.try(
    intercept(interceptors, request, answer_from_lowest(
      _,
      lowest,
      check_columns,
    )),
  )
  use #(description, types, command_result) <- result.try(statement_answer(
    answer,
  ))
  let cache =
    TypeCache(
      describe_type: unknown_type,
      types: types
        |> list.map(fn(description) { #(description.id, description) })
        |> dict.from_list,
    )
  let lookup = lookup_of(cache)
  use #(checked, _formats) <- result.try(check_columns(
    description.columns,
    cache,
    lookup,
  ))
  Ok(Ran(result: command_result, checked:, lookup:))
}

fn statement_answer(
  answer: Answer,
) -> Result(
  #(StatementDescription, List(TypeDescription), CommandResult),
  Reason,
) {
  case answer {
    StatementAnswer(description:, types:, result:) ->
      Ok(#(description, types, result))
    SqlAnswer(..) | CopyFromAnswer(..) | CopyToAnswer(..) ->
      Error(InterceptorFailed(
        reason: "an interceptor answered a statement with the answer of another kind of request",
      ))
  }
}

// The types of an answer are all the types its check needs.
fn unknown_type(type_id: Int) -> Result(TypeDescription, Reason) {
  Error(UnknownType(type_id:))
}

fn lookup_of(cache: TypeCache) -> TypeLookup {
  fn(type_id) { dict.get(cache.types, type_id) }
}

// Asks the server to describe the SQL of the query now, and checks its
// parameters and its columns with the types of the description. Nothing
// runs.
fn check_statement(
  query: Query,
  executor: Executor,
  check_columns: ColumnCheck(checked),
) -> Result(Nil, Error(PostgresError)) {
  {
    use description <- result.try(executor.describe_current(
      definition.sql(query),
      definition.name(query),
    ))
    use #(parameter_types, cache) <- result.try(describe_all(
      list.map(description.parameters, fn(parameter) { parameter.type_id }),
      TypeCache(describe_type: executor.describe_type, types: dict.new()),
    ))
    let lookup = lookup_of(cache)
    use Nil <- result.try(definition.check_values(
      definition.values(query),
      parameter_types,
      lookup,
    ))
    check_columns(description.columns, cache, lookup)
    |> result.replace(Nil)
  }
  |> result.map_error(failure(query, _))
}

// The end of the chain: the answer of the lowest layer.
fn answer_from_lowest(
  request: Request,
  lowest: LowestLayer,
  check_columns: ColumnCheck(checked),
) -> Outcome {
  case lowest {
    DatabaseLayer(executor:) ->
      answer_from_database(request, executor, check_columns)
    AnsweringLayer(answer:) -> answer(request)
  }
}

// The end of the chain on a database: prepares the SQL of the request,
// checks it and runs it.
fn answer_from_database(
  request: Request,
  executor: Executor,
  check_columns: ColumnCheck(checked),
) -> Outcome {
  use description <- result.try(executor.prepare(request.sql, request.name))
  answer_described(request, executor, check_columns, description, False)
}

// Checks and runs against a description. After a changed statement it
// checks and runs one more time. A second change in a row asks the caller
// to try again, as the schema is changing while the query runs.
fn answer_described(
  request: Request,
  executor: Executor,
  check_columns: ColumnCheck(checked),
  description: StatementDescription,
  is_second_run: Bool,
) -> Outcome {
  use #(parameter_types, cache) <- result.try(describe_all(
    list.map(description.parameters, fn(parameter) { parameter.type_id }),
    TypeCache(describe_type: executor.describe_type, types: dict.new()),
  ))
  use #(_column_types, cache) <- result.try(describe_all(
    list.map(description.columns, fn(column) { column.type_id }),
    cache,
  ))
  let lookup = lookup_of(cache)
  use written <- result.try(definition.write_values(
    request.parameters,
    parameter_types,
    lookup,
  ))
  use #(_checked, formats) <- result.try(check_columns(
    description.columns,
    cache,
    lookup,
  ))
  case
    executor.run(request.sql, request.name, written.values, formats),
    is_second_run
  {
    Ok(result), _ ->
      Ok(StatementAnswer(description:, types: dict.values(cache.types), result:))
    Error(StatementChanged(description:)), False ->
      answer_described(request, executor, check_columns, description, True)
    Error(StatementChanged(..)), True -> Error(error.StatementChangedDuringRun)
    Error(RunFailed(reason:)), _ -> Error(reason)
  }
}

fn check_reader(
  reader: Row(a),
  columns: List(ColumnDescription),
  cache: TypeCache,
  lookup: TypeLookup,
) -> Result(#(CheckedRow(a), List(Format)), Reason) {
  use #(column_types, _cache) <- result.try(describe_all(
    list.map(columns, fn(column) { column.type_id }),
    cache,
  ))
  let described =
    list.zip(columns, column_types)
    |> list.map(fn(pair) {
      DescribedColumn(column: pair.0, type_description: pair.1)
    })
  use checked <- result.try(reader.check(reader, described, lookup))
  Ok(#(checked, reader.result_formats(checked)))
}

fn no_reader(
  columns: List(ColumnDescription),
  _cache: TypeCache,
  _lookup: TypeLookup,
) -> Result(#(Nil, List(Format)), Reason) {
  Ok(#(Nil, list.map(columns, fn(_column) { cell.TextFormat })))
}

// --- The types of a statement ------------------------------------------------------

// The types described so far for one run. Each type comes with the types
// of its parts (array elements, domain bases, range elements, multirange
// ranges, composite fields), so a codec finds them all without a call to
// the server.
type TypeCache {
  TypeCache(
    describe_type: fn(Int) -> Result(TypeDescription, Reason),
    types: Dict(Int, TypeDescription),
  )
}

/// Describes each type, with the types of its parts, for a statement that
/// is not a query run, such as a COPY. Gives the descriptions in order,
/// and a lookup of every type that was described.
pub fn describe_types(
  executor: Executor,
  type_ids: List(Int),
) -> Result(#(List(TypeDescription), TypeLookup), Reason) {
  use #(descriptions, cache) <- result.try(describe_all(
    type_ids,
    TypeCache(describe_type: executor.describe_type, types: dict.new()),
  ))
  Ok(#(descriptions, lookup_of(cache)))
}

/// Describes each type, with the types of its parts, and gives every type
/// that was described: the types that an answer of the statement needs.
pub fn describe_every_type(
  executor: Executor,
  type_ids: List(Int),
) -> Result(List(TypeDescription), Reason) {
  use #(_descriptions, cache) <- result.try(describe_all(
    type_ids,
    TypeCache(describe_type: executor.describe_type, types: dict.new()),
  ))
  Ok(dict.values(cache.types))
}

/// The types of the type IDs from the types of an answer, in order, and a
/// lookup of every type of the answer. A type that the answer does not
/// hold is `UnknownType`.
pub fn answer_types(
  types: List(TypeDescription),
  type_ids: List(Int),
) -> Result(#(List(TypeDescription), TypeLookup), Reason) {
  let cache =
    TypeCache(
      describe_type: unknown_type,
      types: types
        |> list.map(fn(description) { #(description.id, description) })
        |> dict.from_list,
    )
  use #(descriptions, cache) <- result.try(describe_all(type_ids, cache))
  Ok(#(descriptions, lookup_of(cache)))
}

fn describe_all(
  type_ids: List(Int),
  cache: TypeCache,
) -> Result(#(List(TypeDescription), TypeCache), Reason) {
  list.try_fold(type_ids, #([], cache), fn(described, type_id) {
    let #(descriptions, cache) = described
    use #(description, cache) <- result.try(describe(type_id, cache))
    Ok(#([description, ..descriptions], cache))
  })
  |> result.map(fn(described) { #(list.reverse(described.0), described.1) })
}

fn describe(
  type_id: Int,
  cache: TypeCache,
) -> Result(#(TypeDescription, TypeCache), Reason) {
  case dict.get(cache.types, type_id) {
    Ok(description) -> Ok(#(description, cache))
    Error(Nil) -> {
      use description <- result.try(cache.describe_type(type_id))
      let cache =
        TypeCache(
          ..cache,
          types: dict.insert(cache.types, type_id, description),
        )
      use #(_parts, cache) <- result.try(describe_all(
        part_type_ids(description),
        cache,
      ))
      Ok(#(description, cache))
    }
  }
}

fn part_type_ids(type_description: TypeDescription) -> List(Int) {
  case type_description.kind {
    Array(element_type_id:) -> [element_type_id]
    Domain(base_type_id:) -> [base_type_id]
    Range(element_type_id:) -> [element_type_id]
    Multirange(range_type_id:) -> [range_type_id]
    Composite(fields:) -> list.map(fields, fn(field) { field.1 })
    Base | Enum(..) | Pseudo -> []
  }
}

fn failure(query: Query, reason: Reason) -> Error(PostgresError) {
  PostgresError(
    query_name: definition.name(query),
    sql: Some(definition.sql(query)),
    reason:,
  )
  |> error.postgres_error_to_dream_error
}
