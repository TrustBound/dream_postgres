import dream_postgres/client as postgres
import gleam/dynamic/decode
import gleam/time/timestamp.{type Timestamp}

pub fn one_hour_later(
  connection: postgres.Connection,
  value: Timestamp,
) -> Result(postgres.Returned(Timestamp), postgres.QueryError) {
  "SELECT $1::timestamp + interval '1 hour'"
  |> postgres.query
  |> postgres.parameter(postgres.timestamp(value))
  |> postgres.returning(decode.at([0], postgres.timestamp_decoder()))
  |> postgres.execute(connection)
}
