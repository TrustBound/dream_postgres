//// The query checks of the boot check tests. Most are the queries of a
//// table `checked_users (id int4, email text, nickname text)`, listed
//// for `verify` in the shape of a generated model module: each query is
//// built with the placeholder of each parameter's codec.

import dream_postgres.{
  type QueryCheck, checked, checked_command, column, named, parameter, query,
  row,
}
import dream_postgres/codec

/// The columns of the table, as SQL for `CREATE TEMPORARY TABLE`.
pub const columns = "(id int4, email text, nickname text)"

/// The columns of the table with `nickname` changed to `int4`.
pub const changed_columns = "(id int4, email text, nickname int4)"

/// The columns of the table with no `nickname`.
pub const missing_columns = "(id int4, email text)"

/// Every query of the table: `user.read`, `user.create` and
/// `user.delete`.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [boot_checks.queries()])
/// ```
pub fn queries() -> List(QueryCheck) {
  [read(), create(), delete()]
}

/// `user.read`: reads the three columns of the user with an id.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[boot_checks.read()]])
/// ```
pub fn read() -> QueryCheck {
  query("SELECT id, email, nickname FROM checked_users WHERE id = $1")
  |> named("user.read")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> checked({
    use id <- column(codec.int)
    use email <- column(codec.text)
    use nickname <- column(codec.nullable(codec.text))
    row(#(id, email, nickname))
  })
}

/// `user.create`: inserts a user.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[boot_checks.create()]])
/// ```
pub fn create() -> QueryCheck {
  query("INSERT INTO checked_users (id, email, nickname) VALUES ($1, $2, $3)")
  |> named("user.create")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> parameter(codec.text, codec.placeholder(codec.text))
  |> parameter(
    codec.nullable(codec.text),
    codec.placeholder(codec.nullable(codec.text)),
  )
  |> checked_command
}

/// `user.delete`: deletes the user with an id.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[boot_checks.delete()]])
/// ```
pub fn delete() -> QueryCheck {
  query("DELETE FROM checked_users WHERE id = $1")
  |> named("user.delete")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> checked_command
}

/// `user.find_by_email`, which gives its `text` parameter with the `int`
/// codec.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[boot_checks.find_with_wrong_codec()]])
/// ```
pub fn find_with_wrong_codec() -> QueryCheck {
  query("SELECT id FROM checked_users WHERE email = $1")
  |> named("user.find_by_email")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> checked(dream_postgres.single(codec.int))
}

/// `user.insert_one`: inserts the row with the id 1 into the table
/// `checked_rows (id int4)` of `run_with_table`.
///
/// ## Example
///
/// ```gleam
/// verify(connection, [[boot_checks.insert_one()]])
/// ```
pub fn insert_one() -> QueryCheck {
  query("INSERT INTO checked_rows (id) VALUES ($1)")
  |> named("user.insert_one")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> checked_command
}

/// `server.add_one`: reads a number from a parameter, on no table.
///
/// ## Example
///
/// ```gleam
/// verify(pool, [[boot_checks.add_one()]])
/// ```
pub fn add_one() -> QueryCheck {
  query("SELECT $1::int4 + 1")
  |> named("server.add_one")
  |> parameter(codec.int, codec.placeholder(codec.int))
  |> checked(dream_postgres.single(codec.int))
}
