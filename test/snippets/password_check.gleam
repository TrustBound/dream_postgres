import dream_errors.{type Error}
import dream_postgres/codec.{bool, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query, secret_parameter}
import dream_postgres/row.{single}

/// Checks a password against its stored SHA-256 hash in hex. The password
/// is a secret parameter, so a recording of this query never holds it.
pub fn password_matches(
  connection: Connection,
  password: String,
  stored_hash: String,
) -> Result(Bool, Error(PostgresError)) {
  "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
  |> query
  |> named("password.matches")
  |> secret_parameter(text, password)
  |> parameter(text, stored_hash)
  |> one(single(bool), connection)
}
