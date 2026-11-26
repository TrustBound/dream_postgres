import dream_postgres/client.{
  type Connection, type QueryError, schema_fingerprint,
}

pub fn users_fingerprint(
  connection: Connection,
  schema: String,
) -> Result(String, QueryError) {
  schema_fingerprint(connection, [schema <> ".users"])
}
