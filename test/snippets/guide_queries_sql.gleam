//// Queries guide: the query functions
////
//// Query functions in the same shape as the ones Squirrel generates: each
//// takes a connection and the parameters, and returns
//// `Result(dream_postgres_client.Returned(Row), dream_postgres_client.QueryError)`.

import dream_postgres_client
import gleam/dynamic/decode

pub type FindUserRow {
  FindUserRow(id: Int, name: String, email: String)
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(
  dream_postgres_client.Returned(FindUserRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(FindUserRow(id:, name:, email:))
  }
  "SELECT id, name, email FROM users WHERE id = $1"
  |> dream_postgres_client.query
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}

pub type ListUsersRow {
  ListUsersRow(id: Int, name: String)
}

pub fn list_users(
  db: dream_postgres_client.Connection,
) -> Result(
  dream_postgres_client.Returned(ListUsersRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(ListUsersRow(id:, name:))
  }
  "SELECT id, name FROM users ORDER BY name"
  |> dream_postgres_client.query
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}

pub type CreateUserRow {
  CreateUserRow(id: Int)
}

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Result(
  dream_postgres_client.Returned(CreateUserRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(CreateUserRow(id:))
  }
  "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id"
  |> dream_postgres_client.query
  |> dream_postgres_client.parameter(dream_postgres_client.text(name))
  |> dream_postgres_client.parameter(dream_postgres_client.text(email))
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}
