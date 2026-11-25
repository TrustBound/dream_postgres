import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn fingerprint_text(
  connection: postgres.Connection,
  tables: List(String),
) -> Result(postgres.Returned(String), postgres.QueryError) {
  postgres.schema_fingerprint_sql
  |> postgres.query
  |> postgres.parameter(postgres.array(postgres.text, tables))
  |> postgres.returning(decode.at([0], decode.string))
  |> postgres.execute(connection)
}
