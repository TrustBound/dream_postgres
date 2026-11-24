//// Getting started guide: Step 3
////
//// Runs a first query with the connection from the context of the program,
//// and turns the result into a greeting.

import dream_postgres/query
import dream_postgres_client
import gleam/dynamic/decode

pub type Context {
  Context(db: dream_postgres_client.Connection)
}

pub type User {
  User(id: Int, name: String)
}

pub fn greet_user(context: Context, id: Int) -> String {
  find_user(context.db, id)
  |> greeting
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(
  dream_postgres_client.Returned(User),
  dream_postgres_client.QueryError,
) {
  dream_postgres_client.query("SELECT id, name FROM users WHERE id = $1")
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning(user_decoder())
  |> dream_postgres_client.execute(db)
}

pub fn greeting(
  result: Result(
    dream_postgres_client.Returned(User),
    dream_postgres_client.QueryError,
  ),
) -> String {
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
