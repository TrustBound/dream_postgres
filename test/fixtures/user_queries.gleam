//// The queries of the recorder tests: a `users` table, recorded against
//// the real server and played back with no database.

import dream_postgres_client
import gleam/dynamic/decode
import gleam/result
import gleam/string

pub fn create_table(
  db: dream_postgres_client.Connection,
) -> Result(
  dream_postgres_client.Returned(Nil),
  dream_postgres_client.QueryError,
) {
  dream_postgres_client.query(
    "CREATE TABLE users (id serial PRIMARY KEY, name text UNIQUE)",
  )
  |> dream_postgres_client.execute(db)
}

/// Inserts a user and gives the new id.
pub fn insert_user(
  db: dream_postgres_client.Connection,
  name: String,
) -> Result(Int, dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "INSERT INTO users (name) VALUES ($1) RETURNING id",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.text(name))
  |> dream_postgres_client.returning(decode.at([0], decode.int))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map(first_or_zero)
}

fn first_or_zero(ids: List(Int)) -> Int {
  case ids {
    [id, ..] -> id
    [] -> 0
  }
}

pub fn user_names(
  db: dream_postgres_client.Connection,
) -> Result(List(String), dream_postgres_client.QueryError) {
  dream_postgres_client.query("SELECT name FROM users ORDER BY id")
  |> dream_postgres_client.returning(decode.at([0], decode.string))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

pub fn count_users(
  db: dream_postgres_client.Connection,
) -> Result(Int, dream_postgres_client.QueryError) {
  dream_postgres_client.query("SELECT count(*)::int FROM users")
  |> dream_postgres_client.returning(decode.at([0], decode.int))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map(first_or_zero)
}

/// Runs the queries of `users.json` in order, and gives each result as
/// text.
pub fn scenario(db: dream_postgres_client.Connection) -> List(String) {
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
  db: dream_postgres_client.Connection,
  first: String,
  second: String,
) -> Result(
  #(Int, Int),
  dream_postgres_client.TransactionError(dream_postgres_client.QueryError),
) {
  use transaction <- dream_postgres_client.transaction(db)
  use first_id <- result.try(insert_user(transaction, first))
  use second_id <- result.map(insert_user(transaction, second))
  #(first_id, second_id)
}

/// Runs the queries of `transaction.json` in order, and gives each result
/// as text.
pub fn transaction_scenario(
  db: dream_postgres_client.Connection,
) -> List(String) {
  [
    string.inspect(create_table(db)),
    string.inspect(insert_two(db, "Ada", "Ada")),
    string.inspect(count_users(db)),
    string.inspect(insert_two(db, "Ada", "Grace")),
    string.inspect(user_names(db)),
  ]
}
