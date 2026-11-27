import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, one, query, single, with_interceptor,
}
import dream_postgres/codec.{text}
import snippets/request_tagging.{tag_with_app_name}

/// The SQL text that the server runs, with the tag in front of it.
pub fn current_sql(
  connection: Connection,
) -> Result(String, Error(PostgresError)) {
  query("SELECT current_query()")
  |> one(single(text), with_interceptor(connection, tag_with_app_name))
}
