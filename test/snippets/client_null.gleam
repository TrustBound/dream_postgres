import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn null_is_null(
  connection: postgres.Connection,
) -> Result(postgres.Returned(Bool), postgres.QueryError) {
  "SELECT $1::text IS NULL"
  |> postgres.query
  |> postgres.parameter(postgres.null())
  |> postgres.returning(decode.at([0], decode.bool))
  |> postgres.execute(connection)
}
