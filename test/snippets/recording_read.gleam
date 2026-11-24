//// Recording: read the SQL of a recording file

import dream_postgres/recording
import gleam/list
import gleam/result

pub fn recorded_sql(file_text: String) -> Result(List(String), String) {
  use recordings <- result.map(recording.from_json(file_text))
  list.map(recordings, fn(entry) { entry.query.sql })
}
