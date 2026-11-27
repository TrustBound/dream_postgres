import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, type Row, column, named, one, parameter,
  query, row,
}
import dream_postgres/codec.{int, text}

pub type FindUserRow {
  FindUserRow(id: Int, name: String, email: String)
}

fn find_user_row() -> Row(FindUserRow) {
  use id <- column(int)
  use name <- column(text)
  use email <- column(text)
  row(FindUserRow(id:, name:, email:))
}

pub fn find_user(
  connection: Connection,
  id: Int,
) -> Result(FindUserRow, Error(PostgresError)) {
  "SELECT id, name, email FROM users WHERE id = $1"
  |> query
  |> named("user.find")
  |> parameter(int, id)
  |> one(find_user_row(), connection)
}
