//// Recording: write a recording file by hand
////
//// A timeout is hard to get from a real database on purpose. This file
//// makes the query time out in playback mode.

import dream_postgres/recording.{Failed, Integer, RecordedQuery, Recording}
import dream_postgres_client

pub fn timeout_recording() -> String {
  recording.to_json([
    Recording(
      query: RecordedQuery(
        sql: "SELECT id, name, email FROM users WHERE id = $1",
        parameters: [Integer(1)],
      ),
      result: Failed(dream_postgres_client.QueryTimeout),
    ),
  ])
}
