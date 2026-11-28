import dream_errors.{type Error}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import dream_postgres/row.{column_at, column_named, row}

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
