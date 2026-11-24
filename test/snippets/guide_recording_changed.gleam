//// Recorded queries guide: a query that changed after the recording
////
//// The SQL now has a `LIMIT 1`, so the recording of the old SQL does not
//// match it.

import dream_pog as pog
import gleam/dynamic/decode
import gleam/result
import snippets/guide_recording_users.{type User, User}

pub fn find_user(
  db: pog.Connection,
  id: Int,
) -> Result(List(User), pog.QueryError) {
  pog.query("SELECT id, name, email FROM users WHERE id = $1 LIMIT 1")
  |> pog.parameter(pog.int(id))
  |> pog.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}
