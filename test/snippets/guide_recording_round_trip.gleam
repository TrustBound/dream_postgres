//// Recorded queries guide: record a test once, then play it back
////
//// `create_and_find` is the code under test. `run_recorded` runs it with a
//// recorder in a mode, and stops the recorder.

import dream_pog as pog
import dream_postgres/recorder
import gleam/result
import gleam/string
import snippets/guide_recording_setup.{connect, start_recorder}
import snippets/guide_recording_users.{type User, create_user, find_user}

pub fn create_and_find(db: pog.Connection) -> Result(User, pog.QueryError) {
  use id <- result.try(create_user(db, "Ada", "ada@example.com"))
  find_user(db, id)
}

pub fn run_recorded(
  mode: String,
  database_url: String,
  directory: String,
) -> Result(User, String) {
  use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
  use db <- result.try(connect(recording, database_url))
  let user = create_and_find(db) |> result.map_error(string.inspect)
  // In record mode, each query was on disk when it returned
  use Nil <- result.try(recorder.stop(recording))
  user
}
