//// Recorded queries guide: a query that changed after the recording
////
//// The SQL now has a `LIMIT 1`, so the recording of the old SQL does not
//// match it.

import dream_postgres_client
import gleam/dynamic/decode
import gleam/result
import snippets/guide_recording_users.{type User, User}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(List(User), dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "SELECT id, name, email FROM users WHERE id = $1 LIMIT 1",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}
