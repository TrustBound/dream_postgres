//// The check of the queries of an app against the live database, at boot.

import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/internal/connection_state.{
  type HeldConnection, hold, lowest_layer,
}
import dream_postgres/internal/failure.{failure}
import dream_postgres/internal/runner
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{type Query}
import dream_postgres/row.{type Row}
import gleam/list
import gleam/option.{None}
import gleam/result

/// A query and how its rows are read, for `verify`. Make one with
/// `checked` for a query whose rows are read, or `checked_command` for a
/// command whose rows are not read.
pub opaque type QueryCheck {
  QueryCheck(check: fn(runner.Executor) -> Result(Nil, Error(PostgresError)))
}

/// The check of a query whose rows `reader` reads, as `all`, `one` and
/// `maybe_one` read them.
///
/// The check uses the codecs of the parameters, not their values: a query
/// that is built only for the check gives each parameter
/// `codec.placeholder` of its codec.
///
/// ### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/boot_check.{type QueryCheck, checked, checked_command}
/// import dream_postgres/codec.{int, placeholder, text}
/// import dream_postgres/query.{named, parameter, query}
/// import dream_postgres/row.{column, row}
///
/// /// The checks of the queries of the user module. A check uses the codec of
/// /// each parameter, not its value, so each value is a placeholder.
/// pub fn queries() -> List(QueryCheck) {
///   [
///     query("SELECT id, email FROM users WHERE id = $1")
///       |> named("user.find")
///       |> parameter(int, placeholder(int))
///       |> checked({
///         use id <- column(int)
///         use email <- column(text)
///         row(#(id, email))
///       }),
///     query("DELETE FROM users WHERE id = $1")
///       |> named("user.delete")
///       |> parameter(int, placeholder(int))
///       |> checked_command,
///   ]
/// }
/// ```
pub fn checked(query: Query, reader: Row(a)) -> QueryCheck {
  QueryCheck(check: runner.check_rows(query, reader, _))
}

/// The check of a command whose rows are not read, as `affected` runs it.
///
/// ### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/boot_check.{type QueryCheck, checked, checked_command}
/// import dream_postgres/codec.{int, placeholder, text}
/// import dream_postgres/query.{named, parameter, query}
/// import dream_postgres/row.{column, row}
///
/// /// The checks of the queries of the user module. A check uses the codec of
/// /// each parameter, not its value, so each value is a placeholder.
/// pub fn queries() -> List(QueryCheck) {
///   [
///     query("SELECT id, email FROM users WHERE id = $1")
///       |> named("user.find")
///       |> parameter(int, placeholder(int))
///       |> checked({
///         use id <- column(int)
///         use email <- column(text)
///         row(#(id, email))
///       }),
///     query("DELETE FROM users WHERE id = $1")
///       |> named("user.delete")
///       |> parameter(int, placeholder(int))
///       |> checked_command,
///   ]
/// }
/// ```
pub fn checked_command(query: Query) -> QueryCheck {
  QueryCheck(check: runner.check_command(query, _))
}

/// Checks each query against the live database, as a run of the query
/// checks it, and runs none of them: the server prepares each query, then
/// its parameters' codecs are checked against the parameter types, and
/// its reader against the number and the types of the columns, enum
/// labels too. Call it at boot, so a query that no longer fits the schema
/// stops the app with a message that names the query and what changed.
///
/// The checks hold one connection for all queries, and go through no
/// interceptor, because no query runs. Each check asks the server, also for
/// a query that the statement cache of the connection holds, so a change
/// of the schema after an earlier run shows too. The error lists one error for each
/// query that fails, in order. When the pool gives no connection, the
/// error lists that one error. A connection with no database, such as the
/// connection of a recorder in playback mode, has no schema to check, so
/// the error lists one `NoDatabaseToVerify` error.
///
/// ### Check the queries at boot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/check_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/boot_check.{verify}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection}
/// import snippets/user_checks.{queries}
///
/// /// Checks each query of the app against the database, at boot.
/// pub fn check_database(
///   connection: Connection,
/// ) -> Result(Nil, List(Error(PostgresError))) {
///   verify(connection, [queries()])
/// }
/// ```
///
/// A failure reads, for example, `user.find: column 2 (email) is int4, and
/// the query reads it with the text codec`.
pub fn verify(
  connection: Connection,
  checks: List(List(QueryCheck)),
) -> Result(Nil, List(Error(PostgresError))) {
  case hold(connection, check_on_held(_, list.flatten(checks))) {
    Ok(outcome) -> outcome
    Error(reason) -> Error([failure(None, None, reason)])
  }
}

fn check_on_held(
  held: HeldConnection,
  checks: List(QueryCheck),
) -> Result(Nil, List(Error(PostgresError))) {
  case lowest_layer(held) {
    runner.DatabaseLayer(executor:) -> check_each(checks, executor)
    runner.AnsweringLayer(..) ->
      Error([failure(None, None, error.NoDatabaseToVerify)])
  }
}

fn check_each(
  checks: List(QueryCheck),
  executor: runner.Executor,
) -> Result(Nil, List(Error(PostgresError))) {
  let #(_passed, failures) =
    checks
    |> list.map(fn(query_check) { query_check.check(executor) })
    |> result.partition
  case failures {
    [] -> Ok(Nil)
    _ -> Error(list.reverse(failures))
  }
}
