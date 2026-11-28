import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/transaction.{
  commit, keep_both_errors, run_transaction, step, transaction,
}
import gleam/function
import gleam/list
import gleam/result
import snippets/create_user.{create_user}
import snippets/user_row.{type User}

/// Stores each person as a user in one transaction, and gives the number
/// of users stored. A person whose email has a user already fails only
/// its own savepoint, and the others are stored.
pub fn import_users(
  connection: Connection,
  people: List(#(String, String)),
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> run_transaction(import_each(_, people))
}

fn import_each(
  transaction_connection: Connection,
  people: List(#(String, String)),
) -> Result(Int, Error(PostgresError)) {
  people
  |> list.map(import_one(transaction_connection, _))
  |> list.count(result.is_ok)
  |> Ok
}

/// A transaction on the connection of a transaction runs as a savepoint.
fn import_one(
  transaction_connection: Connection,
  person: #(String, String),
) -> Result(User, Error(PostgresError)) {
  let #(email, name) = person
  transaction(
    transaction_connection,
    database: function.identity,
    rollback_also_failed: keep_both_errors,
  )
  |> step(create_user(_, email, name))
  |> commit
}
