import dream_errors.{type Error}
import dream_postgres/codec.{int, text, timestamp_with_time_zone, uuid}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query, secret_parameter}
import dream_postgres/row.{type Row, column, row}
import dream_uuid.{type Uuid}
import gleam/result
import gleam/time/timestamp.{type Timestamp}

pub type ApiKey {
  ApiKey(id: Uuid, owner: Int, token: String, created_at: Timestamp)
}

fn api_key_row() -> Row(ApiKey) {
  use id <- column(uuid)
  use owner <- column(int)
  use token <- column(text)
  use created_at <- column(timestamp_with_time_zone)
  row(ApiKey(id:, owner:, token:, created_at:))
}

/// The code under test: it creates an API key for the owner, then reads
/// it back by the id that the database made.
pub fn create_api_key(
  connection: Connection,
  owner: Int,
  password: String,
) -> Result(ApiKey, Error(PostgresError)) {
  use created <- result.try(
    "INSERT INTO api_keys (owner, token, password_hash)
VALUES ($1, 'sk_live_' || md5(random()::text), md5($2))
RETURNING id, owner, token, created_at"
    |> query
    |> named("api_key.create")
    |> parameter(int, owner)
    |> secret_parameter(text, password)
    |> one(api_key_row(), connection),
  )
  "SELECT id, owner, token, created_at FROM api_keys WHERE id = $1"
  |> query
  |> named("api_key.find")
  |> parameter(uuid, created.id)
  |> one(api_key_row(), connection)
}
