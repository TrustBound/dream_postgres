import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, all, column_at, column_named, query, row,
}
import dream_postgres/codec.{int, text}

/// Gives the id and the name of each user. The reader reads the first
/// column by position and the name column by name, and skips the email.
pub fn user_names(
  connection: Connection,
) -> Result(List(#(Int, String)), Error(PostgresError)) {
  let id_and_name = {
    use id <- column_at(1, int)
    use name <- column_named("name", text)
    row(#(id, name))
  }
  "SELECT id, email, name FROM users ORDER BY id"
  |> query
  |> all(id_and_name, connection)
}
