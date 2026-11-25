import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/option.{type Option}

pub fn nickname_or_none(
  connection: postgres.Connection,
  nickname: Option(String),
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT coalesce($1::text, 'none')"
  |> postgres.query
  |> postgres.parameter(postgres.nullable(postgres.text, nickname))
  |> postgres.returning(decode.at([0], decode.string))
  |> postgres.execute(connection)
}
