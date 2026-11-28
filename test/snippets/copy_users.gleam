import dream_errors.{type Error}
import dream_postgres/codecs.{int, nullable, text}
import dream_postgres/codecs/composite.{type Field, field}
import dream_postgres/copy.{copy_from, table}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/row.{type Row, column, row}
import gleam/option.{type Option}

pub type User {
  User(id: Int, email: Option(String))
}

/// Reads the columns id and email, in this order, into a User.
pub fn user_row() -> Row(User) {
  use id <- column(int)
  use email <- column(nullable(text))
  row(User(id:, email:))
}

/// The fields of a user for `copy_from`, in the order of the columns.
pub fn user_fields(user: User) -> List(Field) {
  [field(int, user.id), field(nullable(text), user.email)]
}

pub fn load_users(
  connection: Connection,
  users: List(User),
) -> Result(Int, Error(PostgresError)) {
  copy_from(
    connection,
    into: table("users"),
    columns: ["id", "email"],
    rows: users,
    write: user_fields,
  )
}
