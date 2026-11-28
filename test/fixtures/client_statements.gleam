//// Statements that several client tests run: on a table `name (id int4)`,
//// a division by zero, and a read of a setting.

import dream_errors.{type Error}
import dream_postgres/codecs
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{affected, all, one, parameter, query}
import dream_postgres/row.{single}

/// Inserts a row with `id` into `table`, and gives the row count.
///
/// ## Example
///
/// ```gleam
/// client_statements.insert(connection, "held_rows", 1)
/// // -> Ok(1)
/// ```
pub fn insert(
  connection: Connection,
  table: String,
  id: Int,
) -> Result(Int, Error(PostgresError)) {
  query("INSERT INTO " <> table <> " (id) VALUES ($1)")
  |> parameter(codecs.int, id)
  |> affected(connection)
}

/// The ids of `table`, lowest first.
///
/// ## Example
///
/// ```gleam
/// client_statements.ids(connection, "held_rows")
/// // -> Ok([1, 2])
/// ```
pub fn ids(
  connection: Connection,
  table: String,
) -> Result(List(Int), Error(PostgresError)) {
  query("SELECT id FROM " <> table <> " ORDER BY id")
  |> all(single(codecs.int), connection)
}

/// Runs `SELECT 1 / 0`, which the server refuses with SQLSTATE 22012.
///
/// ## Example
///
/// ```gleam
/// client_statements.divide_by_zero(connection)
/// // -> Error(..)
/// ```
pub fn divide_by_zero(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT 1 / 0")
  |> one(single(codecs.int), connection)
}

/// The value of the setting `name`.
///
/// ## Example
///
/// ```gleam
/// client_statements.setting(connection, "transaction_isolation")
/// // -> Ok("read committed")
/// ```
pub fn setting(
  connection: Connection,
  name: String,
) -> Result(String, Error(PostgresError)) {
  query("SELECT current_setting($1)")
  |> parameter(codecs.text, name)
  |> one(single(codecs.text), connection)
}
