import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{
  commit, keep_both_errors, step, step_with, transaction,
}
import gleam/function
import snippets/create_user.{create_user}
import snippets/user_row.{type User}

/// Stores a new user and an account for the user in one transaction, and
/// gives the id of the account.
pub fn sign_up(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> step(create_user(_, email, name))
  |> step_with(open_account)
  |> commit
}

/// Opens an account for the user that the step before stored.
fn open_account(
  connection: Connection,
  user: User,
) -> Result(Int, Error(PostgresError)) {
  "INSERT INTO accounts (user_id) VALUES ($1) RETURNING id"
  |> query
  |> parameter(int, user.id)
  |> one(single(int), connection)
}
