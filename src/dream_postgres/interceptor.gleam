//// Interceptors: functions that every query and `run_sql` call of a connection
//// goes through, in the order they were added to the config.
////
//// An interceptor gets the request and `next`, the rest of the chain. It
//// can change the request, change or replace the outcome, answer without
//// the database, refuse, or only watch.
////
//// ### Two interceptors <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/request_tagging.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_postgres/interceptor.{type Outcome, type Request, Request}
//// import gleam/io
//// import gleam/option
//// import gleam/order
//// import gleam/time/duration
//// import gleam/time/timestamp
////
//// /// Puts a comment in front of the SQL, so that `pg_stat_activity` and the
//// /// server log show which app sent it.
//// pub fn tag_with_app_name(
////   request: Request,
////   next: fn(Request) -> Outcome,
//// ) -> Outcome {
////   next(Request(..request, sql: "/* billing */ " <> request.sql))
//// }
////
//// /// Prints the name of each request that took more than 500 milliseconds,
//// /// or its SQL when it has no name.
//// pub fn log_slow_queries(
////   request: Request,
////   next: fn(Request) -> Outcome,
//// ) -> Outcome {
////   let started = timestamp.system_time()
////   let outcome = next(request)
////   let elapsed = timestamp.difference(started, timestamp.system_time())
////   case duration.compare(elapsed, duration.milliseconds(500)) {
////     order.Gt ->
////       io.println("slow query: " <> option.unwrap(request.name, request.sql))
////     order.Lt | order.Eq -> Nil
////   }
////   outcome
//// }
//// ```
////
//// The last `next` prepares the SQL of the request, checks the parameters
//// and the row reader against the prepared statement, and runs it. So a
//// changed query is still checked before it runs. The outcome of the chain,
//// also an outcome that an interceptor made, goes through the same row
//// reader and the same error mapping as a real one: a simulated deadlock
//// is `Retry`, and in a transaction it rolls the transaction back.

import dream_postgres/codec.{type Field}
import dream_postgres/error.{
  type Reason, ClosedByServer, ConnectionLost, ErrorSeverity, InterceptorFailed,
  QueryTimeout, Server, ServerError,
}
import dream_postgres/internal/cell.{
  type CommandResult, type StatementDescription, type TypeDescription, Base,
  ColumnDescription, CommandResult, StatementDescription, TypeDescription,
}
import dream_postgres/internal/copy_request
import dream_postgres/internal/query
import dream_postgres/sql_state.{type SqlState}
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string

/// A function of the request and the rest of the chain.
pub type Interceptor =
  fn(Request, fn(Request) -> Outcome) -> Outcome

/// What the app asked for, before the SQL is prepared.
pub type Request {
  Request(
    /// The SQL text.
    sql: String,
    /// The name that `query.named` gave the query, if any.
    name: Option(String),
    /// The parameters with their codecs, `$1` first. A `run_sql` call has none.
    parameters: List(Parameter),
    /// Whether the SQL is one statement with parameters or a `run_sql` call.
    kind: RequestKind,
  )
}

/// A parameter of a request: its codec and its value, as
/// `codec.field(codec.int, 7)` makes it.
pub type Parameter =
  Field

/// How a request runs.
pub type RequestKind {
  /// One statement, prepared and run with its parameters: the requests of
  /// `all`, `one`, `maybe_one` and `affected`.
  Statement
  /// SQL that runs with the simple query protocol: the requests of
  /// `query.run_sql`, and the `BEGIN`, `COMMIT`, `ROLLBACK` and
  /// savepoint commands of a transaction.
  Sql
  /// A binary `COPY ... FROM STDIN` of `copy.copy_from`: the
  /// SQL of the request is the COPY, and the rows are made from the rows
  /// of the app one at a time, when they are sent.
  CopyFrom(table: Table, columns: List(String), rows: RowFeed)
  /// A binary `COPY (...) TO STDOUT` of `copy.copy_to`: the SQL
  /// of the request is the query inside the COPY.
  CopyTo
}

/// The table of a `CopyFrom` request.
pub type Table =
  copy_request.Table

/// The rows of a `CopyFrom` request.
pub type RowFeed =
  copy_request.RowFeed

/// The rows of a `CopyToAnswer`: where they come from, and the watchers
/// that see each of them.
pub type CopyRows =
  copy_request.CopyRows

/// The outcome of a request: the answer, or why there is none.
pub type Outcome =
  Result(Answer, Reason)

/// The answer to a request. It holds all that the row reader needs, so an
/// answer that no database gave reads the same as one that a database
/// gave.
pub type Answer {
  /// The answer to a `Statement`: the description of the prepared
  /// statement, the type of each of its columns with the types of their
  /// parts, and the rows, in cells, with the command tag.
  StatementAnswer(
    description: StatementDescription,
    types: List(TypeDescription),
    result: CommandResult,
  )
  /// The answer to a `Sql`: the result of each statement, in order.
  SqlAnswer(results: List(CommandResult))
  /// The answer to a `CopyFrom`: the number of rows stored.
  CopyFromAnswer(count: Int)
  /// The answer to a `CopyTo`: the description of the query, the type of
  /// each of its columns with the types of their parts, and its rows. The
  /// rows are read one at a time after the reader of the COPY is checked.
  CopyToAnswer(
    description: StatementDescription,
    types: List(TypeDescription),
    rows: CopyRows,
  )
}

/// A result column of an answer that `rows` makes: its name and the name
/// of its PostgreSQL base type, such as `int4` or `text`.
pub type Column {
  Column(name: String, type_name: String)
}

/// A result column for `rows`.
///
/// ### Answer a query with rows <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/answer_with_two_posts.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{field, int, text}
/// import dream_postgres/interceptor.{type Outcome, type Request, column, rows}
/// import gleam/option.{None, Some}
///
/// pub fn answer_with_two_posts(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("post.list") ->
///       rows([column("id", "int4"), column("title", "text")], [
///         [field(int, 1), field(text, "First")],
///         [field(int, 2), field(text, "Second")],
///       ])
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn column(name: String, type_name: String) -> Column {
  Column(name:, type_name:)
}

/// An answer of rows, with no database: each row gives one field for each
/// column, in order. Each field is checked against the type of its column
/// and written with its codec, as a parameter is. The command tag is
/// `SELECT` and the number of rows.
///
/// ### Answer a query with rows <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/answer_with_two_posts.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{field, int, text}
/// import dream_postgres/interceptor.{type Outcome, type Request, column, rows}
/// import gleam/option.{None, Some}
///
/// pub fn answer_with_two_posts(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("post.list") ->
///       rows([column("id", "int4"), column("title", "text")], [
///         [field(int, 1), field(text, "First")],
///         [field(int, 2), field(text, "Second")],
///       ])
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn rows(columns: List(Column), values: List(List(Field))) -> Outcome {
  let types =
    list.index_map(columns, fn(result_column, index) {
      TypeDescription(
        id: index + 1,
        schema: "pg_catalog",
        name: result_column.type_name,
        kind: Base,
      )
    })
  // Each column type is a base type, which has no parts to look up.
  let lookup = fn(_type_id) { Error(Nil) }
  use cells <- result.try(
    list.try_map(values, fn(row_values) {
      query.write_values(row_values, types, lookup)
      |> result.map(fn(written) { written.values })
    }),
  )
  let count = list.length(cells)
  Ok(StatementAnswer(
    description: StatementDescription(
      parameters: [],
      columns: list.map2(columns, types, fn(result_column, description) {
        ColumnDescription(
          name: result_column.name,
          type_id: description.id,
          type_modifier: -1,
          table_id: 0,
          column_number: 0,
        )
      }),
    ),
    types:,
    result: CommandResult(
      rows: cells,
      tag: "SELECT " <> int.to_string(count),
      count:,
    ),
  ))
}

/// An answer of a command with no rows and its tag, with no database. The
/// row count is the last number of the tag, or 0 when the tag ends with no
/// number.
///
/// ### Answer a command with its tag <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/answer_three_updates.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/interceptor.{type Outcome, type Request, command}
/// import gleam/option.{None, Some}
///
/// pub fn answer_three_updates(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     // `affected` reads this answer as 3.
///     Some("user.deactivate_all") -> command("UPDATE 3")
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn command(tag: String) -> Outcome {
  let count =
    string.split(tag, " ")
    |> list.last
    |> result.try(int.parse)
    |> result.unwrap(0)
  Ok(StatementAnswer(
    description: StatementDescription(parameters: [], columns: []),
    types: [],
    result: CommandResult(rows: [], tag:, count:),
  ))
}

/// The failure of a server error with the SQLSTATE and the message, as if
/// PostgreSQL had sent it. It maps as a real one: `DeadlockDetected` is
/// `Retry`, and `UniqueViolation` is `Conflict`.
///
/// ### Simulate a deadlock <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_deadlock.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/interceptor.{type Outcome, type Request, server_error}
/// import dream_postgres/sql_state.{DeadlockDetected}
/// import gleam/option.{None, Some}
///
/// pub fn simulate_deadlock(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("account.transfer") ->
///       Error(server_error(DeadlockDetected, "deadlock detected"))
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn server_error(sql_state: SqlState, message: String) -> Reason {
  Server(
    ServerError(
      severity: ErrorSeverity,
      sql_state:,
      message:,
      detail: None,
      hint: None,
      position: None,
      internal_position: None,
      internal_query: None,
      context: None,
      schema: None,
      table: None,
      column: None,
      data_type: None,
      constraint: None,
      file: None,
      line: None,
      routine: None,
      localized_severity: "ERROR",
      other_fields: [],
    ),
  )
}

/// The failure of a connection that the server closed during the query.
/// It is `Unavailable`.
///
/// ### Simulate a lost connection <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_lost_connection.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/interceptor.{type Outcome, type Request, connection_lost}
/// import gleam/option.{None, Some}
///
/// pub fn simulate_lost_connection(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("report.build") -> Error(connection_lost())
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn connection_lost() -> Reason {
  ConnectionLost(ClosedByServer)
}

/// The failure of a query that did not finish before its deadline, and
/// that runs no more on the server. It is `Timeout`.
///
/// ### Simulate a timeout <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/interceptor.{type Outcome, type Request, timeout}
/// import gleam/option.{None, Some}
///
/// pub fn simulate_timeout(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("report.build") -> Error(timeout())
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn timeout() -> Reason {
  QueryTimeout(stopped_on_server: True)
}

/// The failure of a request that the interceptor refused, with its own
/// reason. It is `Failed`, and the request never reaches the database.
///
/// ### Refuse a request <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/refuse_deletes.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/interceptor.{type Outcome, type Request, refuse}
/// import gleam/option.{None, Some}
///
/// pub fn refuse_deletes(
///   request: Request,
///   next: fn(Request) -> Outcome,
/// ) -> Outcome {
///   case request.name {
///     Some("user.delete") -> Error(refuse("the connection is read only"))
///     Some(_) | None -> next(request)
///   }
/// }
/// ```
pub fn refuse(reason: String) -> Reason {
  InterceptorFailed(reason:)
}
