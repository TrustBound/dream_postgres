//// Getting started guide: Step 3
////
//// Runs a first query with the connection from the context of the program,
//// and turns the result into a greeting.

import dream_postgres/query
import gleam/dynamic/decode
import pog

pub type Context {
  Context(db: pog.Connection)
}

pub type User {
  User(id: Int, name: String)
}

pub fn greet_user(context: Context, id: Int) -> String {
  find_user(context.db, id)
  |> greeting
}

pub fn find_user(
  db: pog.Connection,
  id: Int,
) -> Result(pog.Returned(User), pog.QueryError) {
  pog.query("SELECT id, name FROM users WHERE id = $1")
  |> pog.parameter(pog.int(id))
  |> pog.returning(user_decoder())
  |> pog.execute(db)
}

pub fn greeting(result: Result(pog.Returned(User), pog.QueryError)) -> String {
  case query.first_row(result) {
    Ok(user) -> "Hello, " <> user.name
    Error(query.NotFound) -> "No user with that id"
    Error(query.DatabaseError) -> "The database is not available"
  }
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  decode.success(User(id:, name:))
}
