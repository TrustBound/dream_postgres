import dream_errors.{type Error}
import dream_postgres/codecs.{int, nullable, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import dream_postgres/row.{column, row}
import gleam/option.{type Option}

/// Gives the email of each user and the balance of the user's account. A
/// user with no account has no balance: the column is NULL, read as None.
pub fn balances(
  connection: Connection,
) -> Result(List(#(String, Option(Int))), Error(PostgresError)) {
  let email_and_balance = {
    use email <- column(text)
    use balance <- column(nullable(int))
    row(#(email, balance))
  }
  "SELECT users.email, accounts.balance FROM users
  LEFT JOIN accounts ON accounts.user_id = users.id ORDER BY users.id"
  |> query
  |> all(email_and_balance, connection)
}
