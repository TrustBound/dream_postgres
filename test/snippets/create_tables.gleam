import dream_errors.{type Error}
import dream_postgres.{type Connection, type PostgresError, script}

/// Makes the tables of the examples: users, and the accounts of users.
pub fn create_tables(
  connection: Connection,
) -> Result(Nil, Error(PostgresError)) {
  "
  CREATE TABLE users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL
  );
  CREATE TABLE accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id),
    balance bigint NOT NULL DEFAULT 0
  );
  "
  |> script(connection)
}
