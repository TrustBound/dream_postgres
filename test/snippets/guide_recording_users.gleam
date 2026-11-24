//// Recorded queries guide: the module under test
////
//// Two queries on the users table. They take a connection, so the same
//// functions run on a pool, on a recording pool and on a playback
//// connection.

import dream_pog as pog
import gleam/dynamic/decode
import gleam/result

pub type User {
  User(id: Int, name: String, email: String)
}

pub fn create_user(
  db: pog.Connection,
  name: String,
  email: String,
) -> Result(Int, pog.QueryError) {
  pog.query("INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id")
  |> pog.parameter(pog.text(name))
  |> pog.parameter(pog.text(email))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

pub fn find_user(db: pog.Connection, id: Int) -> Result(User, pog.QueryError) {
  pog.query("SELECT id, name, email FROM users WHERE id = $1")
  |> pog.parameter(pog.int(id))
  |> pog.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

// No row is an error here, so a test sees it.
fn first(rows: List(a)) -> Result(a, pog.QueryError) {
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(pog.PostgresqlError("P0002", "no_data_found", "No row"))
  }
}
