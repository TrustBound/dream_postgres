//// Queries guide: the query functions
////
//// Query functions in the same shape as the ones Squirrel generates: each
//// takes a connection and the parameters, and returns
//// `Result(pog.Returned(Row), pog.QueryError)`.

import dream_pog as pog
import gleam/dynamic/decode

pub type FindUserRow {
  FindUserRow(id: Int, name: String, email: String)
}

pub fn find_user(
  db: pog.Connection,
  id: Int,
) -> Result(pog.Returned(FindUserRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(FindUserRow(id:, name:, email:))
  }
  "SELECT id, name, email FROM users WHERE id = $1"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

pub type ListUsersRow {
  ListUsersRow(id: Int, name: String)
}

pub fn list_users(
  db: pog.Connection,
) -> Result(pog.Returned(ListUsersRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(ListUsersRow(id:, name:))
  }
  "SELECT id, name FROM users ORDER BY name"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

pub type CreateUserRow {
  CreateUserRow(id: Int)
}

pub fn create_user(
  db: pog.Connection,
  name: String,
  email: String,
) -> Result(pog.Returned(CreateUserRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(CreateUserRow(id:))
  }
  "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id"
  |> pog.query
  |> pog.parameter(pog.text(name))
  |> pog.parameter(pog.text(email))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
