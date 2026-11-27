import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, named, one, parameter, query,
  secret_parameter, single,
}
import dream_postgres/codec.{bool, text}

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
