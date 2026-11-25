import dream_postgres/client as postgres

pub fn users_fingerprint(
  connection: postgres.Connection,
  schema: String,
) -> Result(String, postgres.QueryError) {
  postgres.schema_fingerprint(connection, [schema <> ".users"])
}
