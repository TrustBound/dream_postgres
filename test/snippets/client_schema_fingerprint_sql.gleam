import dream_postgres/client.{
  type Connection, type QueryError, type Returned, array, execute, parameter,
  query, returning, schema_fingerprint_sql, text,
}
import gleam/dynamic/decode.{at, string}

pub fn fingerprint_text(
  connection: Connection,
  tables: List(String),
) -> Result(Returned(String), QueryError) {
  schema_fingerprint_sql
  |> query
  |> parameter(array(text, tables))
  |> returning(at([0], string))
  |> execute(connection)
}
