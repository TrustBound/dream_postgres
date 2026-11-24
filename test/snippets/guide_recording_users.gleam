//// Recorded queries guide: the module under test
////
//// Two queries on the users table. They take a connection, so the same
//// functions run on a pool, on a recording pool and on a playback
//// connection.

import dream_postgres_client
import gleam/dynamic/decode
import gleam/result

pub type User {
  User(id: Int, name: String, email: String)
}

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Result(Int, dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.text(name))
  |> dream_postgres_client.parameter(dream_postgres_client.text(email))
  |> dream_postgres_client.returning(decode.at([0], decode.int))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(User, dream_postgres_client.QueryError) {
  dream_postgres_client.query("SELECT id, name, email FROM users WHERE id = $1")
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

// No row is an error here, so a test sees it.
fn first(rows: List(a)) -> Result(a, dream_postgres_client.QueryError) {
  case rows {
    [row, ..] -> Ok(row)
    [] ->
      Error(dream_postgres_client.PostgresqlError(
        "P0002",
        "no_data_found",
        "No row",
      ))
  }
}
