//// Binary `COPY`: store many rows in a table, or read the rows of a query
//// one at a time.

import dream_errors.{type Error}
import dream_postgres/codec
import dream_postgres/copy/executor
import dream_postgres/copy/request
import dream_postgres/error.{type PostgresError}
import dream_postgres/error/failure.{failure}
import dream_postgres/pool.{type Connection}
import dream_postgres/pool/connection_state.{
  chain_of, copy_from_end, copy_to_end, hold, secret_free_error,
}
import dream_postgres/query.{type Query}
import dream_postgres/query/definition
import dream_postgres/row.{type Row}
import gleam/option.{None, Some}
import gleam/result

/// Stores rows in a table with one binary `COPY ... FROM STDIN`, and gives
/// the number of rows stored. It is the fastest way to load many rows.
///
/// `table` and each name of `columns` are quoted as PostgreSQL
/// identifiers, so each is the exact name: `"Users"` is not `"users"`, and
/// a dot is part of the name. A table of another schema than the search
/// path finds is not reachable by name.
///
/// `write` gives the fields of a row, one for each column in order, with
/// `codec.field`. Before the COPY starts, the types of the columns come
/// from the server and the first row is checked against them like the
/// parameters of a query, so a codec that does not take its column's type
/// fails with `ParameterTypeMismatch` and sends nothing. A binary COPY
/// needs codecs in the binary format, so a value of `codec.custom` fails
/// with `CopyNeedsBinaryCodec`. When any row fails, the COPY ends with no
/// row stored.
///
/// ### Store users with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/copy_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/codec.{type Field, field, int, nullable, text}
/// import dream_postgres/copy.{copy_from, table}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection}
/// import dream_postgres/row.{type Row, column, row}
/// import gleam/option.{type Option}
///
/// pub type User {
///   User(id: Int, email: Option(String))
/// }
///
/// /// Reads the columns id and email, in this order, into a User.
/// pub fn user_row() -> Row(User) {
///   use id <- column(int)
///   use email <- column(nullable(text))
///   row(User(id:, email:))
/// }
///
/// /// The fields of a user for `copy_from`, in the order of the columns.
/// pub fn user_fields(user: User) -> List(Field) {
///   [field(int, user.id), field(nullable(text), user.email)]
/// }
///
/// pub fn load_users(
///   connection: Connection,
///   users: List(User),
/// ) -> Result(Int, Error(PostgresError)) {
///   copy_from(
///     connection,
///     into: table("users"),
///     columns: ["id", "email"],
///     rows: users,
///     write: user_fields,
///   )
/// }
/// ```
pub fn copy_from(
  connection: Connection,
  into table: Table,
  columns columns: List(String),
  rows rows: List(a),
  write write: fn(a) -> List(codec.Field),
) -> Result(Int, Error(PostgresError)) {
  hold(connection, fn(held) {
    executor.copy_from(
      chain_of(held),
      copy_from_end(held),
      table,
      columns,
      rows,
      write,
    )
  })
  |> result.flatten
  |> result.map_error(failure(
    None,
    Some(executor.copy_from_sql(table, columns)),
    _,
  ))
  |> result.map_error(secret_free_error(connection, _))
}

/// The table that `copy_from` stores its rows in.
pub type Table =
  request.Table

/// A table found through the search path, such as `table("users")`. The
/// name is one identifier: a dot in it is part of the name, not a schema.
pub fn table(name: String) -> Table {
  request.table(name)
}

/// A table in a schema, such as `table_in_schema("billing", "invoices")`.
/// The schema and the name are each quoted on their own.
pub fn table_in_schema(schema: String, name: String) -> Table {
  request.table_in_schema(schema, name)
}

/// Reads the rows of a query with one binary `COPY (...) TO STDOUT`, and
/// folds over them: `with` takes the value so far and each row in order,
/// starting `from` the first value. The rows are read one at a time, so
/// the whole result is never in memory.
///
/// The query is prepared first, and the reader is checked against its
/// columns as for `all`. PostgreSQL takes no parameters in a COPY, so a
/// query with parameters fails with `CopyQueryHasParameters` and sends
/// nothing. A binary COPY needs codecs in the binary format, so a reader
/// that reads with `codec.custom` fails with `CopyNeedsBinaryCodec`. A row
/// that the reader cannot read stops the COPY with its reason.
///
/// ### Read every user with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/export_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/copy.{copy_to}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection}
/// import dream_postgres/query.{query}
/// import gleam/list
/// import gleam/result
/// import snippets/copy_users.{type User, user_row}
///
/// pub fn export_users(
///   connection: Connection,
/// ) -> Result(List(User), Error(PostgresError)) {
///   copy_to(
///     connection,
///     query("SELECT id, email FROM users ORDER BY id"),
///     read: user_row(),
///     from: [],
///     with: list.prepend,
///   )
///   |> result.map(list.reverse)
/// }
/// ```
pub fn copy_to(
  connection: Connection,
  query: Query,
  read reader: Row(a),
  from initial: accumulator,
  with fold: fn(accumulator, a) -> accumulator,
) -> Result(accumulator, Error(PostgresError)) {
  hold(connection, fn(held) {
    executor.copy_to(
      chain_of(held),
      copy_to_end(held),
      query,
      reader,
      initial,
      fold,
    )
  })
  |> result.flatten
  |> result.map_error(failure(
    definition.name(query),
    Some(definition.sql(query)),
    _,
  ))
  |> result.map_error(secret_free_error(connection, _))
}
