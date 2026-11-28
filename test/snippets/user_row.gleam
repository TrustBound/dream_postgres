import dream_postgres/codecs.{int, text}
import dream_postgres/row.{type Row, column, row}

pub type User {
  User(id: Int, email: String, name: String)
}

/// Reads the columns id, email and name, in this order, into a User.
pub fn user_row() -> Row(User) {
  use id <- column(int)
  use email <- column(text)
  use name <- column(text)
  row(User(id:, email:, name:))
}
