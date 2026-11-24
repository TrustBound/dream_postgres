//// Recorder: the three keys of a query
////
//// Gives the key of each match function for one query, to show what each
//// one keeps.

import dream_postgres/recorder
import dream_postgres/recording.{Integer, RecordedQuery}

pub fn keys() -> List(String) {
  let query =
    RecordedQuery(sql: "SELECT name\n  FROM users WHERE id = $1", parameters: [
      Integer(7),
    ])
  [
    recorder.sql_and_parameters(query),
    recorder.normalized_sql_and_parameters(query),
    recorder.sql_only(query),
  ]
}
