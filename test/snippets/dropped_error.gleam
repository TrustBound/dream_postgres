import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/transaction.{commit, keep_both, step, transaction}
import gleam/function
import snippets/create_user.{create_user}

/// A wrong transaction: its step drops the error of a failed statement.
/// PostgreSQL then answers COMMIT with ROLLBACK, and `commit` gives the
/// error of the failed statement.
pub fn create_user_and_drop_error(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Nil, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> step(insert_and_drop_error(_, email, name))
  |> commit
}

fn insert_and_drop_error(
  connection: Connection,
  email: String,
  name: String,
) -> Result(Nil, Error(PostgresError)) {
  let _dropped_error = create_user(connection, email, name)
  Ok(Nil)
}
