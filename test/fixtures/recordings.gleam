//// Directories for the recording files of the recorder tests, and the
//// helpers that read them.
////
//// Each test gets its own directory under `build/test_recordings`, and the
//// directory is deleted when the test returns. The recording files that
//// the playback tests read with no database are in
//// `test/fixtures/recordings`.

import dream_postgres/client as postgres
import dream_postgres/recorder
import dream_postgres_client
import fixtures/database_url
import fixtures/test_database
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/result

/// The directory of the committed recording files.
pub const fixtures = "test/fixtures/recordings"

@external(erlang, "database_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "database_ffi", "read_file")
fn read_file_ffi(path: String) -> Result(String, Nil)

@external(erlang, "recorder_ffi", "delete_directory")
fn delete_directory(path: String) -> Nil

@external(erlang, "recorder_ffi", "make_read_only")
pub fn make_read_only(path: String) -> Nil

@external(erlang, "recorder_ffi", "is_registered")
fn is_registered_ffi(name: process.Name(dream_postgres_client.Message)) -> Bool

/// Gives `run` a new directory path that does not exist yet, and deletes
/// the directory after `run` returns.
pub fn with_directory(run: fn(String) -> a) -> a {
  let directory = "build/test_recordings/" <> int.to_string(unique_integer())
  let value = run(directory)
  delete_directory(directory)
  value
}

/// Returns the text of a file, or an empty string when it cannot be read.
pub fn read(path: String) -> String {
  read_file_ffi(path)
  |> result.unwrap("")
}

/// True when a pool runs under the name.
pub fn is_registered(
  name: process.Name(dream_postgres_client.Message),
) -> Bool {
  is_registered_ffi(name)
}

/// Starts a recorder in `mode` for the recording `name` in `directory`.
pub fn start(
  mode: recorder.Mode,
  directory: String,
  name: String,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(name)
  |> recorder.mode(mode)
  |> recorder.start()
}

/// Runs `sql` and gives its rows before they are decoded.
pub fn rows(
  db: dream_postgres_client.Connection,
  sql: String,
) -> Result(List(Dynamic), dream_postgres_client.QueryError) {
  dream_postgres_client.query(sql)
  |> dream_postgres_client.returning(decode.dynamic)
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

@external(erlang, "recorder_ffi", "make_writable")
pub fn make_writable(path: String) -> Nil

/// Starts a recorder in record mode for `<directory>/<name>.json`, gives
/// `run` a connection whose tables are in a new, empty schema, stops the
/// recorder and drops the schema. Gives the value of `run` and the result
/// of `recorder.stop`.
pub fn record_in_schema(
  builder: recorder.RecorderBuilder,
  run: fn(dream_postgres_client.Connection) -> a,
) -> #(a, Result(Nil, String)) {
  in_schema(builder, recorder.Record, run)
}

/// Starts a recorder in `mode`, gives `run` a connection whose tables are
/// in a new, empty schema, stops the recorder and drops the schema.
pub fn in_schema(
  builder: recorder.RecorderBuilder,
  mode: recorder.Mode,
  run: fn(dream_postgres_client.Connection) -> a,
) -> #(a, Result(Nil, String)) {
  use <- test_database.with_own_pools()
  let schema = "recorder_" <> int.to_string(unique_integer())
  let assert Ok(admin) =
    test_database.config()
    |> postgres.pool_size(1)
    |> postgres.connect()
  let assert Ok(_created) =
    test_database.execute(admin, "CREATE SCHEMA " <> schema)
  let assert Ok(recording) = recorder.start(builder |> recorder.mode(mode))
  let assert Ok(db) =
    recorder.connect(
      recording,
      test_database.config()
        |> postgres.pool_size(1)
        |> dream_postgres_client.connection_parameter(
          name: "search_path",
          value: schema,
        ),
    )
  let value = run(db)
  let stopped = recorder.stop(recording)
  let assert Ok(_dropped) =
    test_database.execute(admin, "DROP SCHEMA " <> schema <> " CASCADE")
  #(value, stopped)
}

/// Starts a recorder in playback mode, gives `run` its connection, and
/// stops the recorder. The config of the connection points at a port where
/// nothing listens.
pub fn play(
  builder: recorder.RecorderBuilder,
  run: fn(dream_postgres_client.Connection) -> a,
) -> a {
  let assert Ok(playback) =
    recorder.start(builder |> recorder.mode(recorder.Playback))
  let assert Ok(db) = recorder.connect(playback, unreachable_config())
  let value = run(db)
  let assert Ok(Nil) = recorder.stop(playback)
  value
}

/// A config for a port where nothing listens, with its own pool name.
pub fn unreachable_config() -> postgres.Config {
  let assert Ok(config) =
    postgres.parse_config(
      process.new_name("unreachable"),
      database_url.unused_database_url(),
    )
  config
}

/// A builder for the recording `name` in `directory`.
pub fn builder(directory: String, name: String) -> recorder.RecorderBuilder {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(name)
}

@external(erlang, "recorder_ffi", "write_file")
fn write_file(path: String, content: String) -> Nil

/// Writes `content` to the file at `path`.
pub fn write(path: String, content: String) -> Nil {
  write_file(path, content)
}
