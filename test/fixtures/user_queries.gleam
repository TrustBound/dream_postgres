//// The queries of the recorder tests: a `users` table, recorded against
//// the real server and played back with no database.

import dream_pog as pog
import gleam/dynamic/decode
import gleam/result
import gleam/string

pub fn create_table(
  db: pog.Connection,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query("CREATE TABLE users (id serial PRIMARY KEY, name text UNIQUE)")
  |> pog.execute(db)
}

/// Inserts a user and gives the new id.
pub fn insert_user(
  db: pog.Connection,
  name: String,
) -> Result(Int, pog.QueryError) {
  pog.query("INSERT INTO users (name) VALUES ($1) RETURNING id")
  |> pog.parameter(pog.text(name))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map(first_or_zero)
}

fn first_or_zero(ids: List(Int)) -> Int {
  case ids {
    [id, ..] -> id
    [] -> 0
  }
}

pub fn user_names(db: pog.Connection) -> Result(List(String), pog.QueryError) {
  pog.query("SELECT name FROM users ORDER BY id")
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

pub fn count_users(db: pog.Connection) -> Result(Int, pog.QueryError) {
  pog.query("SELECT count(*)::int FROM users")
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map(first_or_zero)
}

/// Runs the queries of `users.json` in order, and gives each result as
/// text.
pub fn scenario(db: pog.Connection) -> List(String) {
  [
    string.inspect(create_table(db)),
    string.inspect(insert_user(db, "Ada")),
    string.inspect(insert_user(db, "Ada")),
    string.inspect(user_names(db)),
    string.inspect(count_users(db)),
    string.inspect(insert_user(db, "Grace")),
    string.inspect(count_users(db)),
  ]
}

/// The results of `scenario`, live and played back.
pub const scenario_results = [
  "Ok(Returned(0, []))",
  "Ok(1)",
  "Error(ConstraintViolated(\"duplicate key value violates unique constraint \\\"users_name_key\\\"\", \"users_name_key\", \"Key (name)=(Ada) already exists.\"))",
  "Ok([\"Ada\"])",
  "Ok(1)",
  "Ok(3)",
  "Ok(2)",
]

/// Inserts two users in one transaction, and gives the error of the
/// transaction when one insert fails.
pub fn insert_two(
  db: pog.Connection,
  first: String,
  second: String,
) -> Result(#(Int, Int), pog.TransactionError(pog.QueryError)) {
  use transaction <- pog.transaction(db)
  use first_id <- result.try(insert_user(transaction, first))
  use second_id <- result.map(insert_user(transaction, second))
  #(first_id, second_id)
}

/// Runs the queries of `transaction.json` in order, and gives each result
/// as text.
pub fn transaction_scenario(db: pog.Connection) -> List(String) {
  [
    string.inspect(create_table(db)),
    string.inspect(insert_two(db, "Ada", "Ada")),
    string.inspect(count_users(db)),
    string.inspect(insert_two(db, "Ada", "Grace")),
    string.inspect(user_names(db)),
  ]
}
