//// Record the queries of a test against a real database, then play them
//// back with no database.
////
//// A recorder keeps the queries of one test in one file,
//// `<directory>/<name>.json`, in the order they ran. It runs in one of
//// three modes, the constructors of `Mode`:
////
//// - `Record`: each query runs on the real database, and the recorder
////   writes the query, its parameters and its result (the rows and the
////   count, or the error) to the file before the query returns. A query
////   that the recorder cannot record fails.
//// - `Playback`: no pool starts and nothing connects. Each query gets the
////   result of its recording. A query with no recording fails, and never
////   reaches a database.
//// - `Passthrough`: each query runs on the real database, and nothing is
////   recorded.
////
//// A query that the recorder fails returns
//// `dream_postgres_client.InterceptorFailed`, and `error` reads the
//// `RecorderError` back from it.
////
//// `recording` documents the file format.
////
//// ## Example
////
//// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_postgres/recorder
//// import dream_postgres_client
//// import gleam/result
//// import gleam/string
//// import snippets/guide_recording_setup.{connect, start_recorder}
//// import snippets/guide_recording_users.{type User, create_user, find_user}
////
//// pub fn create_and_find(
////   db: dream_postgres_client.Connection,
//// ) -> Result(User, dream_postgres_client.QueryError) {
////   use id <- result.try(create_user(db, "Ada", "ada@example.com"))
////   find_user(db, id)
//// }
////
//// pub fn run_recorded(
////   mode: recorder.Mode,
////   database_url: String,
////   directory: String,
//// ) -> Result(User, String) {
////   use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
////   use db <- result.try(connect(recording, database_url))
////   let user = create_and_find(db) |> result.map_error(string.inspect)
////   // In record mode, each query was on disk when it returned
////   use Nil <- result.try(recorder.stop(recording))
////   user
//// }
//// ```

import dream_postgres/client as postgres
import dream_postgres/recording.{
  type RecordedQuery, type RecordedResult, type RecordedValue, type Recording,
  Failed, RecordedQuery, Recording, Returned,
}
import dream_postgres_client
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string

/// Why the recorder failed a query.
///
/// The query returns `dream_postgres_client.InterceptorFailed`, and `error`
/// reads the `RecorderError` back from it.
///
/// - `NoRecording`: in playback mode, no recording in the file at `path`
///   matches the query. `parameters` is the text of the parameters, as
///   `recording.values_to_json` writes them. `sql` and `parameters` are
///   those after the query transformer. `nearest` holds at most 3
///   recordings of the same SQL, nearest first: see `NearestRecording`.
/// - `PlayedAlready`: in playback mode, each recording in the file at
///   `path` that matches the query was played already.
/// - `WriteFailed`: in record mode, the recorder could not write the file
///   at `path`. `reason` is the error of the file system, such as
///   `permission denied`. The query ran on the database.
/// - `NotRecordable`: a parameter or a value of the result of the query is
///   a term that a recording cannot hold, such as a process.
/// - `RecorderStopped`: the recorder had stopped already, so it could not
///   record or play the query.
pub type RecorderError {
  NoRecording(
    sql: String,
    parameters: String,
    path: String,
    nearest: List(NearestRecording),
  )
  PlayedAlready(sql: String, parameters: String, path: String)
  WriteFailed(path: String, reason: String)
  NotRecordable(sql: String, reason: String)
  RecorderStopped(sql: String)
}

/// A recording near a query that no recording matches.
///
/// - `position`: the place of the recording in the file, 1 for the first.
/// - `recorded`: the parameters of the recording, as
///   `recording.values_to_json` writes them.
/// - `requested`: the parameters of the query, after the query transformer.
///
/// A candidate is a recording that the key would match if the query had
/// the recording's parameters: so with `sql_and_parameters` it has the same
/// SQL, and with `normalized_sql_and_parameters` the same SQL apart from
/// whitespace. The SQL is the same, so the parameters are the part that
/// differs. The nearest candidates have the fewest parameters that differ,
/// where each value that one list has and the other has not counts too.
/// Candidates with the same count are in file order. A recording with the
/// same parameters as a nearer one is left out. A miss names at most 3.
pub type NearestRecording {
  NearestRecording(position: Int, recorded: String, requested: String)
}

// The reason that the recorder gives to
// `dream_postgres_client.InterceptorFailed`. The tag keeps it apart from the
// reason of any other interceptor.
type Failure {
  DreamPostgresRecorderError(error: RecorderError)
}

/// Gives the text that two queries must share to match.
///
/// In playback mode, a query gets the result of the first recording that
/// it was not given yet whose key is the same as its own. Use
/// `sql_and_parameters` (the default), `normalized_sql_and_parameters`,
/// `sql_only`, or your own function.
pub type MatchKey =
  fn(RecordedQuery) -> String

/// Changes a query before the recorder computes its key, and before it
/// writes the query to the file, in both record and playback mode.
///
/// Use it to remove a secret from the parameters: the file then never
/// holds the secret, and a query with the secret still matches its
/// recording.
pub type QueryTransformer =
  fn(RecordedQuery) -> RecordedQuery

/// Changes a result before the recorder writes it to the file, in record
/// mode only. The query is the one that `QueryTransformer` gave.
///
/// Use it to remove a secret from the rows. Playback then gives the rows
/// without the secret.
pub type ResultTransformer =
  fn(RecordedQuery, RecordedResult) -> RecordedResult

/// What a recorder does with each query.
///
/// - `Record`: the query runs on the real database, and the recorder writes
///   it and its result to the file before the query returns.
/// - `Playback`: nothing connects, and the query gets the result of its
///   recording.
/// - `Passthrough`: the query runs on the real database, and nothing is
///   recorded.
///
/// Set it with `mode`. For a mode in a text, for example from an
/// environment variable, use `parse_mode`.
pub type Mode {
  Record
  Playback
  Passthrough
}

/// The settings of a recorder, before it starts.
///
/// Make one with `new`, change it with `directory`, `name`, `mode`, `key`,
/// `query_transformer` and `result_transformer`, then start it with
/// `start`.
pub opaque type RecorderBuilder {
  RecorderBuilder(
    mode: Mode,
    directory: Option(String),
    name: Option(String),
    key: MatchKey,
    query_transformer: QueryTransformer,
    result_transformer: ResultTransformer,
  )
}

/// A recorder that runs. Give it to `connect`, and stop it with `stop`.
pub opaque type Recorder {
  RecordMode(server: Server(RecordMessage), settings: Settings)
  PlaybackMode(server: Server(PlaybackMessage), settings: Settings)
  PassthroughMode
}

type Server(message) {
  Server(pid: Pid, subject: Subject(message))
}

type Settings {
  Settings(
    key: MatchKey,
    query_transformer: QueryTransformer,
    result_transformer: ResultTransformer,
  )
}

/// Make the settings of a recorder.
///
/// The defaults: mode `Passthrough`, no directory, no name, the key
/// `sql_and_parameters`, and transformers that change nothing.
///
/// ## Example
///
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/erlang/process
/// import gleam/result
/// import gleam/string
///
/// pub fn start_recorder(
///   mode: recorder.Mode,
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(mode)
///   |> recorder.start()
/// }
///
/// /// In playback mode, nothing connects to `database_url`.
/// pub fn connect(
///   recording: recorder.Recorder,
///   database_url: String,
/// ) -> Result(dream_postgres_client.Connection, String) {
///   use config <- result.try(
///     postgres.parse_config(process.new_name("test_database"), database_url)
///     |> result.map_error(string.inspect),
///   )
///   recorder.connect(recording, config)
///   |> result.map_error(string.inspect)
/// }
/// ```
pub fn new() -> RecorderBuilder {
  RecorderBuilder(
    mode: Passthrough,
    directory: None,
    name: None,
    key: sql_and_parameters,
    query_transformer: keep_query,
    result_transformer: keep_result,
  )
}

fn keep_query(query: RecordedQuery) -> RecordedQuery {
  query
}

fn keep_result(
  _query: RecordedQuery,
  result: RecordedResult,
) -> RecordedResult {
  result
}

/// Set the directory of the recording files. Record and playback mode need
/// it. Record mode makes it when it does not exist.
///
/// ## Example
///
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/erlang/process
/// import gleam/result
/// import gleam/string
///
/// pub fn start_recorder(
///   mode: recorder.Mode,
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(mode)
///   |> recorder.start()
/// }
///
/// /// In playback mode, nothing connects to `database_url`.
/// pub fn connect(
///   recording: recorder.Recorder,
///   database_url: String,
/// ) -> Result(dream_postgres_client.Connection, String) {
///   use config <- result.try(
///     postgres.parse_config(process.new_name("test_database"), database_url)
///     |> result.map_error(string.inspect),
///   )
///   recorder.connect(recording, config)
///   |> result.map_error(string.inspect)
/// }
/// ```
pub fn directory(
  builder: RecorderBuilder,
  directory: String,
) -> RecorderBuilder {
  RecorderBuilder(..builder, directory: Some(directory))
}

/// Set the name of the recording, usually the name of the test. The file is
/// `<directory>/<name>.json`. Record and playback mode need it.
///
/// A name has letters, digits, `_`, `-` and `.` only, and does not start
/// with `.`, so it is always one file in the directory.
///
/// ## Example
///
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/erlang/process
/// import gleam/result
/// import gleam/string
///
/// pub fn start_recorder(
///   mode: recorder.Mode,
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(mode)
///   |> recorder.start()
/// }
///
/// /// In playback mode, nothing connects to `database_url`.
/// pub fn connect(
///   recording: recorder.Recorder,
///   database_url: String,
/// ) -> Result(dream_postgres_client.Connection, String) {
///   use config <- result.try(
///     postgres.parse_config(process.new_name("test_database"), database_url)
///     |> result.map_error(string.inspect),
///   )
///   recorder.connect(recording, config)
///   |> result.map_error(string.inspect)
/// }
/// ```
pub fn name(builder: RecorderBuilder, name: String) -> RecorderBuilder {
  RecorderBuilder(..builder, name: Some(name))
}

/// Set the mode: `Record`, `Playback` or `Passthrough`.
///
/// For a mode in a text, for example from an environment variable, use
/// `parse_mode` first.
///
/// ## Example
///
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/erlang/process
/// import gleam/result
/// import gleam/string
///
/// pub fn start_recorder(
///   mode: recorder.Mode,
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(mode)
///   |> recorder.start()
/// }
///
/// /// In playback mode, nothing connects to `database_url`.
/// pub fn connect(
///   recording: recorder.Recorder,
///   database_url: String,
/// ) -> Result(dream_postgres_client.Connection, String) {
///   use config <- result.try(
///     postgres.parse_config(process.new_name("test_database"), database_url)
///     |> result.map_error(string.inspect),
///   )
///   recorder.connect(recording, config)
///   |> result.map_error(string.inspect)
/// }
/// ```
pub fn mode(builder: RecorderBuilder, mode: Mode) -> RecorderBuilder {
  RecorderBuilder(..builder, mode: mode)
}

/// Read a mode from a text, for example from an environment variable such
/// as `RECORD_QUERIES=record`.
///
/// The texts are `"record"`, `"playback"` and `"passthrough"`. They are
/// case-sensitive. Any other text gives an error that names it, such as
/// `Error("The recorder mode \"replay\" is not known. Use \"record\",
/// \"playback\" or \"passthrough\".")`.
///
/// ## Example
///
/// ### Read the mode from a text <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_parse_mode.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import gleam/result
///
/// pub fn start_from_text(
///   mode_text: String,
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   use mode <- result.try(recorder.parse_mode(mode_text))
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(mode)
///   |> recorder.start()
/// }
/// ```
pub fn parse_mode(text: String) -> Result(Mode, String) {
  case text {
    "record" -> Ok(Record)
    "playback" -> Ok(Playback)
    "passthrough" -> Ok(Passthrough)
    _ ->
      Error(
        "The recorder mode "
        <> string.inspect(text)
        <> " is not known. Use \"record\", \"playback\" or \"passthrough\".",
      )
  }
}

/// Set the function that decides which recording a query matches in
/// playback mode.
///
/// ## Example
///
/// ### Match the SQL with its whitespace made the same <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_key.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
///
/// pub fn playback_ignoring_whitespace(
///   directory: String,
///   test_name: String,
/// ) -> Result(recorder.Recorder, String) {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(test_name)
///   |> recorder.mode(recorder.Playback)
///   |> recorder.key(recorder.normalized_sql_and_parameters)
///   |> recorder.start()
/// }
/// ```
pub fn key(builder: RecorderBuilder, key: MatchKey) -> RecorderBuilder {
  RecorderBuilder(..builder, key: key)
}

/// Set the function that changes each query before it is matched and
/// written. See `QueryTransformer`.
///
/// ## Example
///
/// ### Hide a secret before it reaches the file <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_scrub.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres/recording.{
///   type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
/// }
/// import dream_postgres_client
/// import gleam/dynamic/decode
/// import gleam/list
/// import gleam/result
///
/// const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"
///
/// const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"
///
/// pub fn find_tokens(
///   db: dream_postgres_client.Connection,
///   user_name: String,
/// ) -> Result(List(String), dream_postgres_client.QueryError) {
///   dream_postgres_client.query(select_tokens)
///   |> dream_postgres_client.parameter(dream_postgres_client.text(user_name))
///   |> dream_postgres_client.returning(decode.at([0], decode.string))
///   |> dream_postgres_client.execute(db)
///   |> result.map(fn(returned) { returned.rows })
/// }
///
/// pub fn scrubbing_builder(
///   directory: String,
///   name: String,
/// ) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(name)
///   |> recorder.query_transformer(hide_token_parameter)
///   |> recorder.result_transformer(hide_token_column)
/// }
///
/// // Runs in record and in playback mode, so a played-back INSERT with the
/// // real token still matches its recording.
/// fn hide_token_parameter(query: RecordedQuery) -> RecordedQuery {
///   case query.sql, query.parameters {
///     sql, [user_name, _token] if sql == insert_session ->
///       RecordedQuery(..query, parameters: [user_name, Text("[hidden]")])
///     _, _ -> query
///   }
/// }
///
/// // Runs in record mode only: playback gives the hidden rows.
/// fn hide_token_column(
///   query: RecordedQuery,
///   result: RecordedResult,
/// ) -> RecordedResult {
///   case query.sql, result {
///     sql, Returned(count:, rows:) if sql == select_tokens ->
///       Returned(
///         count:,
///         rows: list.map(rows, fn(_row) { Tuple([Text("[hidden]")]) }),
///       )
///     _, _ -> result
///   }
/// }
/// ```
pub fn query_transformer(
  builder: RecorderBuilder,
  transformer: QueryTransformer,
) -> RecorderBuilder {
  RecorderBuilder(..builder, query_transformer: transformer)
}

/// Set the function that changes each result before it is written. See
/// `ResultTransformer`.
///
/// ## Example
///
/// ### Hide a secret before it reaches the file <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_scrub.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres/recording.{
///   type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
/// }
/// import dream_postgres_client
/// import gleam/dynamic/decode
/// import gleam/list
/// import gleam/result
///
/// const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"
///
/// const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"
///
/// pub fn find_tokens(
///   db: dream_postgres_client.Connection,
///   user_name: String,
/// ) -> Result(List(String), dream_postgres_client.QueryError) {
///   dream_postgres_client.query(select_tokens)
///   |> dream_postgres_client.parameter(dream_postgres_client.text(user_name))
///   |> dream_postgres_client.returning(decode.at([0], decode.string))
///   |> dream_postgres_client.execute(db)
///   |> result.map(fn(returned) { returned.rows })
/// }
///
/// pub fn scrubbing_builder(
///   directory: String,
///   name: String,
/// ) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> recorder.directory(directory)
///   |> recorder.name(name)
///   |> recorder.query_transformer(hide_token_parameter)
///   |> recorder.result_transformer(hide_token_column)
/// }
///
/// // Runs in record and in playback mode, so a played-back INSERT with the
/// // real token still matches its recording.
/// fn hide_token_parameter(query: RecordedQuery) -> RecordedQuery {
///   case query.sql, query.parameters {
///     sql, [user_name, _token] if sql == insert_session ->
///       RecordedQuery(..query, parameters: [user_name, Text("[hidden]")])
///     _, _ -> query
///   }
/// }
///
/// // Runs in record mode only: playback gives the hidden rows.
/// fn hide_token_column(
///   query: RecordedQuery,
///   result: RecordedResult,
/// ) -> RecordedResult {
///   case query.sql, result {
///     sql, Returned(count:, rows:) if sql == select_tokens ->
///       Returned(
///         count:,
///         rows: list.map(rows, fn(_row) { Tuple([Text("[hidden]")]) }),
///       )
///     _, _ -> result
///   }
/// }
/// ```
pub fn result_transformer(
  builder: RecorderBuilder,
  transformer: ResultTransformer,
) -> RecorderBuilder {
  RecorderBuilder(..builder, result_transformer: transformer)
}

/// Start a recorder.
///
/// - Record mode writes the file with no queries at once, so the file never
///   keeps the queries of an earlier run, and a directory that cannot be
///   written is an error here.
/// - Playback mode reads the file.
/// - Passthrough mode does nothing.
///
/// ## Returns
///
/// - `Ok(Recorder)`: the recorder runs
/// - `Error(message)`: the directory or the name is missing or not valid, the
///   file cannot be written (record mode), or the file cannot be read or is not
///   a recording file (playback mode)
///
/// ## Example
///
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(
///   db: dream_postgres_client.Connection,
/// ) -> Result(User, dream_postgres_client.QueryError) {
///   use id <- result.try(create_user(db, "Ada", "ada@example.com"))
///   find_user(db, id)
/// }
///
/// pub fn run_recorded(
///   mode: recorder.Mode,
///   database_url: String,
///   directory: String,
/// ) -> Result(User, String) {
///   use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
///   use db <- result.try(connect(recording, database_url))
///   let user = create_and_find(db) |> result.map_error(string.inspect)
///   // In record mode, each query was on disk when it returned
///   use Nil <- result.try(recorder.stop(recording))
///   user
/// }
/// ```
pub fn start(builder: RecorderBuilder) -> Result(Recorder, String) {
  let settings =
    Settings(
      key: builder.key,
      query_transformer: builder.query_transformer,
      result_transformer: builder.result_transformer,
    )
  case builder.mode {
    Passthrough -> Ok(PassthroughMode)
    Record -> start_record(builder, settings)
    Playback -> start_playback(builder, settings)
  }
}

fn start_record(
  builder: RecorderBuilder,
  settings: Settings,
) -> Result(Recorder, String) {
  use path <- result.try(file_path(builder))
  use Nil <- result.try(
    write_file(path, recording.to_json([]))
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )
  use server <- result.map(start_server(
    RecordState(path:, recordings: []),
    handle_record,
  ))
  RecordMode(server:, settings:)
}

fn start_playback(
  builder: RecorderBuilder,
  settings: Settings,
) -> Result(Recorder, String) {
  use path <- result.try(file_path(builder))
  use text <- result.try(read_file(path))
  use recordings <- result.try(
    recording.from_json(text)
    |> result.map_error(fn(message) { path <> ": " <> message }),
  )
  let entries =
    list.map(recordings, fn(recording) {
      Entry(key: settings.key(recording.query), recording:, played: False)
    })
  use server <- result.map(start_server(
    PlaybackState(path:, key_of: settings.key, entries:),
    handle_playback,
  ))
  PlaybackMode(server:, settings:)
}

fn file_path(builder: RecorderBuilder) -> Result(String, String) {
  case builder.directory, builder.name {
    None, _ -> Error("The recorder needs a directory: call recorder.directory.")
    _, None -> Error("The recorder needs a name: call recorder.name.")
    Some(directory), Some(name) -> directory_and_name(directory, name)
  }
}

fn directory_and_name(
  directory: String,
  name: String,
) -> Result(String, String) {
  case is_valid_name(name) {
    True -> Ok(directory <> "/" <> name <> ".json")
    False ->
      Error(
        "The recording name "
        <> string.inspect(name)
        <> " is not valid. Use letters, digits, _, - and ., and do not start with a dot.",
      )
  }
}

fn is_valid_name(name: String) -> Bool {
  name != ""
  && !string.starts_with(name, ".")
  && list.all(string.to_graphemes(name), is_name_character)
}

fn is_name_character(character: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
    character,
  )
}

/// Start a pool for the recorder, or, in playback mode, make a connection
/// with no pool.
///
/// - Record mode starts the pool of `config` with `client.connect`, with an
///   interceptor that records each query. A query in
///   `dream_postgres_client.transaction` is recorded too.
/// - Playback mode starts no pool and opens no connection: it returns
///   `dream_postgres_client.disconnected`, and every query gets the result of
///   its recording. `config` is not used, so the database does not have to
///   exist.
/// - Passthrough mode starts the pool of `config` with `client.connect`.
///
/// ## Returns
///
/// - `Ok(Connection)`: use it as any other connection
/// - `Error(StartError)`: the error of `client.connect` (record and
///   passthrough mode)
///
/// ## Example
///
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(
///   db: dream_postgres_client.Connection,
/// ) -> Result(User, dream_postgres_client.QueryError) {
///   use id <- result.try(create_user(db, "Ada", "ada@example.com"))
///   find_user(db, id)
/// }
///
/// pub fn run_recorded(
///   mode: recorder.Mode,
///   database_url: String,
///   directory: String,
/// ) -> Result(User, String) {
///   use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
///   use db <- result.try(connect(recording, database_url))
///   let user = create_and_find(db) |> result.map_error(string.inspect)
///   // In record mode, each query was on disk when it returned
///   use Nil <- result.try(recorder.stop(recording))
///   user
/// }
/// ```
pub fn connect(
  recorder: Recorder,
  config: postgres.Config,
) -> Result(postgres.Connection, actor.StartError) {
  case recorder {
    PassthroughMode -> postgres.connect(config)
    RecordMode(server:, settings:) ->
      config
      |> dream_postgres_client.interceptor(
        Some(record_interceptor(server, settings)),
      )
      |> postgres.connect()
    PlaybackMode(server:, settings:) ->
      Ok(
        dream_postgres_client.disconnected(playback_interceptor(
          server,
          settings,
        )),
      )
  }
}

/// Stop the recorder process.
///
/// In record mode, each query is on disk when it returns, so `stop` does
/// not write. A query that the recorder could not record failed already,
/// with a `RecorderError`.
///
/// ## Returns
///
/// - `Ok(Nil)`: the recorder stopped
/// - `Error(message)`: the recorder had stopped already
///
/// ## Example
///
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres_client
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(
///   db: dream_postgres_client.Connection,
/// ) -> Result(User, dream_postgres_client.QueryError) {
///   use id <- result.try(create_user(db, "Ada", "ada@example.com"))
///   find_user(db, id)
/// }
///
/// pub fn run_recorded(
///   mode: recorder.Mode,
///   database_url: String,
///   directory: String,
/// ) -> Result(User, String) {
///   use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
///   use db <- result.try(connect(recording, database_url))
///   let user = create_and_find(db) |> result.map_error(string.inspect)
///   // In record mode, each query was on disk when it returned
///   use Nil <- result.try(recorder.stop(recording))
///   user
/// }
/// ```
pub fn stop(recorder: Recorder) -> Result(Nil, String) {
  case recorder {
    PassthroughMode -> Ok(Nil)
    RecordMode(server:, ..) -> stop_server(server, StopRecording)
    PlaybackMode(server:, ..) -> stop_server(server, StopPlayback)
  }
}

fn stop_server(
  server: Server(message),
  stop: fn(Subject(Nil)) -> message,
) -> Result(Nil, String) {
  call(server, stop)
  |> result.replace_error("The recorder had stopped already.")
}

/// The default key: the SQL text exactly, and every parameter.
///
/// ## Example
///
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres/recording.{Integer, RecordedQuery}
///
/// pub fn keys() -> List(String) {
///   let query =
///     RecordedQuery(sql: "SELECT name\n  FROM users WHERE id = $1", parameters: [
///       Integer(7),
///     ])
///   [
///     recorder.sql_and_parameters(query),
///     recorder.normalized_sql_and_parameters(query),
///     recorder.sql_only(query),
///   ]
/// }
/// ```
pub fn sql_and_parameters(query: RecordedQuery) -> String {
  query.sql <> "\n" <> parameters_text(query.parameters)
}

/// The SQL text with each run of whitespace outside quotes made one space,
/// and with no whitespace at the start or the end, and every parameter. A
/// query that only changed its line breaks or its indentation still
/// matches.
///
/// ## Example
///
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres/recording.{Integer, RecordedQuery}
///
/// pub fn keys() -> List(String) {
///   let query =
///     RecordedQuery(sql: "SELECT name\n  FROM users WHERE id = $1", parameters: [
///       Integer(7),
///     ])
///   [
///     recorder.sql_and_parameters(query),
///     recorder.normalized_sql_and_parameters(query),
///     recorder.sql_only(query),
///   ]
/// }
/// ```
pub fn normalized_sql_and_parameters(query: RecordedQuery) -> String {
  normalize_sql(query.sql) <> "\n" <> parameters_text(query.parameters)
}

/// The SQL text exactly, and no parameters. Queries with the same SQL get
/// their recordings in recorded order, whatever their parameters.
///
/// ## Example
///
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres/recording.{Integer, RecordedQuery}
///
/// pub fn keys() -> List(String) {
///   let query =
///     RecordedQuery(sql: "SELECT name\n  FROM users WHERE id = $1", parameters: [
///       Integer(7),
///     ])
///   [
///     recorder.sql_and_parameters(query),
///     recorder.normalized_sql_and_parameters(query),
///     recorder.sql_only(query),
///   ]
/// }
/// ```
pub fn sql_only(query: RecordedQuery) -> String {
  query.sql
}

fn parameters_text(parameters: List(RecordedValue)) -> String {
  recording.values_to_json(parameters)
}

// Whitespace outside '...' and "..." becomes one space. A quote inside
// quotes is written two times, so it ends the quote and starts it again,
// which keeps the state right.
type SqlState {
  SqlState(text: List(String), quote: Option(String), space: Bool)
}

fn normalize_sql(sql: String) -> String {
  let state =
    string.to_graphemes(string.trim(sql))
    |> list.fold(SqlState(text: [], quote: None, space: False), add_character)
  string.concat(list.reverse(state.text))
}

fn add_character(state: SqlState, character: String) -> SqlState {
  case state.quote, is_whitespace(character), character {
    None, True, _ -> SqlState(..state, space: True)
    None, False, "'" | None, False, "\"" ->
      SqlState(..push(state, character), quote: Some(character))
    None, False, _ -> push(state, character)
    Some(quote), _, _ if quote == character ->
      SqlState(..push(state, character), quote: None)
    Some(_), _, _ -> SqlState(..state, text: [character, ..state.text])
  }
}

fn push(state: SqlState, character: String) -> SqlState {
  case state.space {
    True ->
      SqlState(..state, text: [character, " ", ..state.text], space: False)
    False -> SqlState(..state, text: [character, ..state.text])
  }
}

fn is_whitespace(character: String) -> Bool {
  list.contains([" ", "\n", "\t", "\r", "\r\n"], character)
}

// The interceptors

fn record_interceptor(
  server: Server(RecordMessage),
  settings: Settings,
) -> dream_postgres_client.Interceptor {
  dream_postgres_client.Interceptor(fn(request) {
    dream_postgres_client.Capture(on_result: fn(result) {
      add(server, settings, request, result)
      |> result.map_error(to_reason)
    })
  })
}

// Runs in the process of the query, before the query returns. An error
// here fails the query.
fn add(
  server: Server(RecordMessage),
  settings: Settings,
  request: dream_postgres_client.InterceptRequest,
  result: Result(#(Int, List(Dynamic)), dream_postgres_client.QueryError),
) -> Result(Nil, RecorderError) {
  use recording <- result.try(to_recording(settings, request, result))
  call(server, Add(recording, _))
  |> result.replace_error(RecorderStopped(sql: recording.query.sql))
  |> result.flatten()
}

fn to_recording(
  settings: Settings,
  request: dream_postgres_client.InterceptRequest,
  result: Result(#(Int, List(Dynamic)), dream_postgres_client.QueryError),
) -> Result(Recording, RecorderError) {
  use query <- result.try(to_query(settings, request))
  use recorded <- result.map(
    to_result(result)
    |> result.map_error(not_recordable(query.sql, "A value of the result", _)),
  )
  Recording(query:, result: settings.result_transformer(query, recorded))
}

fn to_query(
  settings: Settings,
  request: dream_postgres_client.InterceptRequest,
) -> Result(RecordedQuery, RecorderError) {
  use parameters <- result.map(
    list.try_map(request.parameters, fn(parameter) {
      to_recorded(to_dynamic(parameter))
    })
    |> result.map_error(not_recordable(request.sql, "A parameter", _)),
  )
  settings.query_transformer(RecordedQuery(sql: request.sql, parameters:))
}

fn not_recordable(sql: String, what: String, term: String) -> RecorderError {
  NotRecordable(sql:, reason: what <> " cannot be recorded: " <> term)
}

fn to_result(
  result: Result(#(Int, List(Dynamic)), dream_postgres_client.QueryError),
) -> Result(RecordedResult, String) {
  case result {
    Error(error) -> Ok(Failed(error))
    Ok(#(count, rows)) -> to_returned(count, rows)
  }
}

fn to_returned(
  count: Int,
  rows: List(Dynamic),
) -> Result(RecordedResult, String) {
  use rows <- result.map(list.try_map(rows, to_recorded))
  Returned(count:, rows:)
}

fn playback_interceptor(
  server: Server(PlaybackMessage),
  settings: Settings,
) -> dream_postgres_client.Interceptor {
  dream_postgres_client.Interceptor(fn(request) {
    play(server, settings, request)
  })
}

fn play(
  server: Server(PlaybackMessage),
  settings: Settings,
  request: dream_postgres_client.InterceptRequest,
) -> dream_postgres_client.InterceptResult {
  let answer = {
    use query <- result.try(to_query(settings, request))
    call(server, Play(settings.key(query), query, _))
    |> result.replace_error(RecorderStopped(sql: query.sql))
    |> result.flatten()
  }
  case answer {
    Ok(Returned(count:, rows:)) ->
      dream_postgres_client.Respond(count:, rows: list.map(rows, from_recorded))
    Ok(Failed(query_error)) -> dream_postgres_client.Fail(query_error)
    Error(recorder_error) ->
      dream_postgres_client.Fail(
        dream_postgres_client.InterceptorFailed(to_reason(recorder_error)),
      )
  }
}

fn to_reason(recorder_error: RecorderError) -> Dynamic {
  failure_to_dynamic(DreamPostgresRecorderError(recorder_error))
}

/// Reads the recorder's error back from a query error.
///
/// ## Returns
///
/// - `Ok(RecorderError)`: the recorder failed the query
/// - `Error(Nil)`: the error is not from this recorder: an error of the
///   database, or the `dream_postgres_client.InterceptorFailed` of another
///   interceptor
///
/// ## Example
///
/// ### Explain a query error <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/recorder_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recorder
/// import dream_postgres_client
///
/// pub fn explain(query_error: dream_postgres_client.QueryError) -> String {
///   case recorder.error(query_error) {
///     Ok(recorder.NoRecording(sql:, parameters:, path:, ..)) ->
///       "Record again: " <> path <> " has no " <> sql <> " with " <> parameters
///     Ok(_other) -> "The recorder failed the query"
///     Error(Nil) -> "The database failed the query"
///   }
/// }
/// ```
pub fn error(
  query_error: dream_postgres_client.QueryError,
) -> Result(RecorderError, Nil) {
  case query_error {
    dream_postgres_client.InterceptorFailed(reason:) ->
      decode.run(reason, failure_decoder())
      |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

/// The text of a recorder error, for a test failure or a log line.
///
/// A `NoRecording` names the query, then each nearest recording with its
/// parameters on a `-` line and the query's parameters on a `+` line.
///
/// ### The text of a query with no recording <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_recording_miss_text.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```text
/// No recording matches SELECT id, name, email FROM users WHERE id = $1 with [2]
/// Nearest recording in test/fixtures/recordings/create_and_find.json:
///   parameters:
///   - [1]
///   + [2]
/// ```
///
/// When no recording has the SQL, the second line names the file that the
/// recorder searched: `No recording in <path> has this SQL`.
pub fn describe_error(error: RecorderError) -> String {
  case error {
    NoRecording(sql:, parameters:, path:, nearest:) ->
      "No recording matches "
      <> sql
      <> " with "
      <> parameters
      <> "\n"
      <> describe_nearest(path, nearest)
    PlayedAlready(sql:, parameters:, path:) ->
      "Each recording of "
      <> sql
      <> " with "
      <> parameters
      <> " in "
      <> path
      <> " was played already"
    WriteFailed(path:, reason:) -> "Could not write " <> path <> ": " <> reason
    NotRecordable(sql:, reason:) -> "Cannot record " <> sql <> ": " <> reason
    RecorderStopped(sql:) -> "The recorder stopped before " <> sql
  }
}

fn describe_nearest(path: String, nearest: List(NearestRecording)) -> String {
  case nearest {
    [] -> "No recording in " <> path <> " has this SQL"
    [first, ..rest] ->
      [
        describe_candidate("Nearest recording in ", path, first),
        ..list.map(rest, describe_candidate(
          "Next nearest recording in ",
          path,
          _,
        ))
      ]
      |> string.join("\n")
  }
}

fn describe_candidate(
  label: String,
  path: String,
  candidate: NearestRecording,
) -> String {
  label
  <> path
  <> ":\n  parameters:\n  - "
  <> candidate.recorded
  <> "\n  + "
  <> candidate.requested
}

fn failure_decoder() -> decode.Decoder(RecorderError) {
  use Nil <- decode.then(tag("dream_postgres_recorder_error"))
  decode.at([1], recorder_error_decoder())
}

fn recorder_error_decoder() -> decode.Decoder(RecorderError) {
  decode.one_of(
    variant("no_recording", {
      use sql <- decode.field(1, decode.string)
      use parameters <- decode.field(2, decode.string)
      use path <- decode.field(3, decode.string)
      use nearest <- decode.field(4, decode.list(nearest_decoder()))
      decode.success(NoRecording(sql:, parameters:, path:, nearest:))
    }),
    [
      variant("played_already", miss_decoder(PlayedAlready)),
      variant("write_failed", {
        use path <- decode.field(1, decode.string)
        use reason <- decode.field(2, decode.string)
        decode.success(WriteFailed(path:, reason:))
      }),
      variant("not_recordable", {
        use sql <- decode.field(1, decode.string)
        use reason <- decode.field(2, decode.string)
        decode.success(NotRecordable(sql:, reason:))
      }),
      variant("recorder_stopped", {
        use sql <- decode.field(1, decode.string)
        decode.success(RecorderStopped(sql:))
      }),
    ],
  )
}

fn nearest_decoder() -> decode.Decoder(NearestRecording) {
  use position <- decode.field(1, decode.int)
  use recorded <- decode.field(2, decode.string)
  use requested <- decode.field(3, decode.string)
  decode.success(NearestRecording(position:, recorded:, requested:))
}

fn miss_decoder(
  make: fn(String, String, String) -> RecorderError,
) -> decode.Decoder(RecorderError) {
  use sql <- decode.field(1, decode.string)
  use parameters <- decode.field(2, decode.string)
  use path <- decode.field(3, decode.string)
  decode.success(make(sql, parameters, path))
}

// A decoder of the constructor `name`: the first element of its tuple is
// the atom `name`.
fn variant(
  name: String,
  fields: decode.Decoder(RecorderError),
) -> decode.Decoder(RecorderError) {
  use Nil <- decode.then(tag(name))
  fields
}

fn tag(name: String) -> decode.Decoder(Nil) {
  use found <- decode.field(0, atom.decoder())
  case found == atom.create(name) {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, name)
  }
}

@external(erlang, "dream_postgres_recorder_ffi", "to_recorded")
fn to_recorded(term: Dynamic) -> Result(RecordedValue, String)

@external(erlang, "dream_postgres_recorder_ffi", "from_recorded")
fn from_recorded(value: RecordedValue) -> Dynamic

@external(erlang, "dream_postgres_recorder_ffi", "to_dynamic")
fn to_dynamic(value: dream_postgres_client.Value) -> Dynamic

@external(erlang, "dream_postgres_recorder_ffi", "to_dynamic")
fn failure_to_dynamic(failure: Failure) -> Dynamic

@external(erlang, "dream_postgres_recorder_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "dream_postgres_recorder_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

// The recorder processes. A recorder in record mode and one in playback
// mode run different processes, with different messages, so a message of
// one mode never reaches the process of the other.

type RecordMessage {
  Add(recording: Recording, reply: Subject(Result(Nil, RecorderError)))
  StopRecording(reply: Subject(Nil))
}

type RecordState {
  RecordState(path: String, recordings: List(Recording))
}

type PlaybackMessage {
  Play(
    key: String,
    query: RecordedQuery,
    reply: Subject(Result(RecordedResult, RecorderError)),
  )
  StopPlayback(reply: Subject(Nil))
}

type PlaybackState {
  PlaybackState(path: String, key_of: MatchKey, entries: List(Entry))
}

type Entry {
  Entry(key: String, recording: Recording, played: Bool)
}

fn start_server(
  state: state,
  handle: fn(state, message) -> actor.Next(state, message),
) -> Result(Server(message), String) {
  actor.new(state)
  |> actor.on_message(handle)
  |> actor.start()
  |> result.map(fn(started) { Server(pid: started.pid, subject: started.data) })
  |> result.replace_error("The recorder process did not start.")
}

fn handle_record(
  state: RecordState,
  message: RecordMessage,
) -> actor.Next(RecordState, RecordMessage) {
  case message {
    Add(recording, reply) -> {
      let #(state, written) = add_recording(state, recording)
      process.send(reply, written)
      actor.continue(state)
    }
    StopRecording(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

// The recordings of the state are newest first. The whole file is written
// again for each query, so the file on disk always holds every query that
// returned its result. When the write fails, the state keeps the
// recordings of before: the query fails, so it is not recorded.
fn add_recording(
  state: RecordState,
  recording: Recording,
) -> #(RecordState, Result(Nil, RecorderError)) {
  let recordings = [recording, ..state.recordings]
  case write_file(state.path, recording.to_json(list.reverse(recordings))) {
    Ok(Nil) -> #(RecordState(..state, recordings:), Ok(Nil))
    Error(reason) -> #(state, Error(WriteFailed(path: state.path, reason:)))
  }
}

fn handle_playback(
  state: PlaybackState,
  message: PlaybackMessage,
) -> actor.Next(PlaybackState, PlaybackMessage) {
  case message {
    Play(key, query, reply) -> {
      let #(answer, entries) =
        take(state.entries, key, query, state.path, state.key_of)
      process.send(reply, answer)
      actor.continue(PlaybackState(..state, entries:))
    }
    StopPlayback(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

// Matching wins over order: the query gets the first recording with its key
// that it was not given yet. So queries that run at the same time, in any
// order, each get their own recording, and the same query run two times
// gets its two results in recorded order.
fn take(
  entries: List(Entry),
  key: String,
  query: RecordedQuery,
  path: String,
  key_of: MatchKey,
) -> #(Result(RecordedResult, RecorderError), List(Entry)) {
  let #(before, rest) =
    list.split_while(entries, fn(entry) { entry.played || entry.key != key })
  case rest {
    [entry, ..after] -> #(
      Ok(entry.recording.result),
      list.append(before, [Entry(..entry, played: True), ..after]),
    )
    [] -> #(Error(miss_error(entries, key, query, path, key_of)), entries)
  }
}

fn miss_error(
  entries: List(Entry),
  key: String,
  query: RecordedQuery,
  path: String,
  key_of: MatchKey,
) -> RecorderError {
  let matching = list.count(entries, fn(entry) { entry.key == key })
  let parameters = parameters_text(query.parameters)
  case matching {
    0 ->
      NoRecording(
        sql: query.sql,
        parameters:,
        path:,
        nearest: nearest_recordings(entries, key_of, query),
      )
    _ -> PlayedAlready(sql: query.sql, parameters:, path:)
  }
}

/// The most recordings that a miss names.
const nearest_limit = 3

// The recordings that the key would match if the query had their
// parameters, fewest differing parameters first, then in file order, with
// no two that have the same parameters.
fn nearest_recordings(
  entries: List(Entry),
  key_of: MatchKey,
  query: RecordedQuery,
) -> List(NearestRecording) {
  let requested = parameters_text(query.parameters)
  entries
  |> list.index_map(fn(entry, index) {
    #(index + 1, entry.key, entry.recording.query.parameters)
  })
  |> list.filter(fn(candidate) {
    let #(_position, key, parameters) = candidate
    key_of(RecordedQuery(..query, parameters:)) == key
  })
  |> first_of_each_parameters()
  |> list.map(fn(candidate) {
    #(changed_count(candidate.2, query.parameters), candidate)
  })
  |> list.sort(fn(left, right) {
    int.compare(left.0, right.0)
    |> order.break_tie(int.compare(left.1.0, right.1.0))
  })
  |> list.take(nearest_limit)
  |> list.map(fn(scored) {
    let #(_count, #(position, _key, parameters)) = scored
    NearestRecording(
      position:,
      recorded: parameters_text(parameters),
      requested:,
    )
  })
}

// Keeps the first candidate with each list of parameters.
fn first_of_each_parameters(
  candidates: List(#(Int, String, List(RecordedValue))),
) -> List(#(Int, String, List(RecordedValue))) {
  list.fold(candidates, [], fn(kept, candidate) {
    case
      list.any(kept, fn(earlier: #(Int, String, List(RecordedValue))) {
        earlier.2 == candidate.2
      })
    {
      True -> kept
      False -> [candidate, ..kept]
    }
  })
  |> list.reverse()
}

// The number of places where two parameter lists differ. A value that one
// list has and the other has not counts as a place that differs.
fn changed_count(left: List(RecordedValue), right: List(RecordedValue)) -> Int {
  case left, right {
    [], rest | rest, [] -> list.length(rest)
    [a, ..left_rest], [b, ..right_rest] ->
      case a == b {
        True -> 0
        False -> 1
      }
      + changed_count(left_rest, right_rest)
  }
}

// Sends a message and waits for the answer. When the recorder process
// stopped, the answer is `Error(Nil)`, not a crash of the caller.
fn call(
  server: Server(message),
  make: fn(Subject(a)) -> message,
) -> Result(a, Nil) {
  let reply = process.new_subject()
  let monitor = process.monitor(server.pid)
  process.send(server.subject, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive_forever()
  process.demonitor_process(monitor)
  answer
}
