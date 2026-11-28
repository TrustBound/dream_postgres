//// A connection with no database: the connection of a recorder in
//// playback mode on an empty recording.

import dream_postgres/config
import dream_postgres/pool.{type Connection}
import dream_postgres/recorder
import dream_postgres/recording.{Recording}
import fixtures/recording_paths
import gleam/erlang/process
import gleam/result
import gleam/string
import simplifile

/// The directory of the empty recordings.
const directory = "build/no_database_recordings"

/// A connection with no database, owned by the calling process: each
/// request that reaches the recording fails with `RequestNotRecorded`,
/// and no transaction is aborted. When the empty recording cannot be
/// written or the recorder does not start, the connection is the handle
/// of a pool name that no pool has, so each request fails with
/// `PoolStopped` and the test that uses it fails.
///
/// ## Example
///
/// ```gleam
/// verify(no_database.connection(), [boot_checks.queries()])
/// ```
pub fn connection() -> Connection {
  let path = recording_paths.unique(in: directory, name: "empty")
  {
    use Nil <- result.try(
      simplifile.create_directory_all(directory)
      |> result.map_error(string.inspect),
    )
    use Nil <- result.try(
      simplifile.write(path, recording.format_recording(Recording(entries: [])))
      |> result.map_error(string.inspect),
    )
    use test_recorder <- result.try(
      recorder.recorder(file: path)
      |> recorder.start_recorder
      |> result.map_error(string.inspect),
    )
    config.default_config()
    |> config.record(test_recorder)
    |> pool.start_pool
    |> result.map_error(string.inspect)
  }
  |> result.lazy_unwrap(fn() {
    pool.named_connection(process.new_name("no_database"))
  })
}
