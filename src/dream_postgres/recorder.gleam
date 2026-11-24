//// Record the queries of a test against a real database, then play them
//// back with no database.
////
//// A recorder keeps the queries of one test in one file,
//// `<directory>/<name>.json`, in the order they ran. It runs in one of
//// three modes, the constructors of `Mode`:
////
//// - `Record`: each query runs on the real database, and the recorder
////   writes the query, its parameters and its result (the rows and the
////   count, or the error) to the file before the query returns.
//// - `Playback`: no pool starts and nothing connects. Each query gets the
////   result of its recording. A query with no recording gets an error that
////   names it, and never reaches a database.
//// - `Passthrough`: each query runs on the real database, and nothing is
////   recorded.
////
//// `recording` documents the file format.
////
//// ## Example
////
//// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_pog as pog
//// import dream_postgres/recorder
//// import gleam/result
//// import gleam/string
//// import snippets/guide_recording_setup.{connect, start_recorder}
//// import snippets/guide_recording_users.{type User, create_user, find_user}
////
//// pub fn create_and_find(db: pog.Connection) -> Result(User, pog.QueryError) {
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

import dream_pog as pog
import dream_postgres/client as postgres
import dream_postgres/recording.{
  type RecordedQuery, type RecordedResult, type RecordedValue, type Recording,
  Failed, RecordedQuery, Recording, Returned,
}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// The `code` of the `pog.PostgresqlError` that a query gets in playback
/// mode when no recording matches it.
pub const no_recording_code = "NOREC"

/// The `name` of the `pog.PostgresqlError` that a query gets in playback
/// mode when no recording matches it.
pub const no_recording_name = "no_recording"

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
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
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
/// ) -> Result(pog.Connection, String) {
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
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
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
/// ) -> Result(pog.Connection, String) {
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
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
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
/// ) -> Result(pog.Connection, String) {
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
/// ### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/client as postgres
/// import dream_postgres/recorder
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
/// ) -> Result(pog.Connection, String) {
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
/// `Error("The recorder mode \"replay\" is not known. Use \"record\", \"playback\" or \"passthrough\".")`.
///
/// ## Example
///
/// ### Read the mode from a text <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_parse_mode.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
/// ### Match the SQL with its whitespace made the same <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_key.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
/// ### Hide a secret before it reaches the file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_scrub.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recorder
/// import dream_postgres/recording.{
///   type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
/// }
/// import gleam/dynamic/decode
/// import gleam/list
/// import gleam/result
///
/// const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"
///
/// const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"
///
/// pub fn find_tokens(
///   db: pog.Connection,
///   user_name: String,
/// ) -> Result(List(String), pog.QueryError) {
///   pog.query(select_tokens)
///   |> pog.parameter(pog.text(user_name))
///   |> pog.returning(decode.at([0], decode.string))
///   |> pog.execute(db)
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
/// ### Hide a secret before it reaches the file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_scrub.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recorder
/// import dream_postgres/recording.{
///   type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
/// }
/// import gleam/dynamic/decode
/// import gleam/list
/// import gleam/result
///
/// const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"
///
/// const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"
///
/// pub fn find_tokens(
///   db: pog.Connection,
///   user_name: String,
/// ) -> Result(List(String), pog.QueryError) {
///   pog.query(select_tokens)
///   |> pog.parameter(pog.text(user_name))
///   |> pog.returning(decode.at([0], decode.string))
///   |> pog.execute(db)
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
/// - `Error(message)`: the directory or the name is missing or not valid, the file cannot be written (record mode), or the
///   file cannot be read or is not a recording file (playback mode)
///
/// ## Example
///
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recorder
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(db: pog.Connection) -> Result(User, pog.QueryError) {
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
  use Nil <- result.try(write_file(path, recording.to_json([])))
  use server <- result.map(start_server(
    RecordState(path:, recordings: [], failure: None),
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
    PlaybackState(path:, entries:),
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
///   interceptor that records each query. A query in `pog.transaction` is
///   recorded too.
/// - Playback mode starts no pool and opens no connection: it returns
///   `pog.disconnected`, and every query gets the result of its recording.
///   `config` is not used, so the database does not have to exist.
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
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recorder
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(db: pog.Connection) -> Result(User, pog.QueryError) {
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
      |> pog.interceptor(Some(record_interceptor(server, settings)))
      |> postgres.connect()
    PlaybackMode(server:, settings:) ->
      Ok(pog.disconnected(playback_interceptor(server, settings)))
  }
}

/// Stop the recorder process.
///
/// In record mode, each query is on disk when it returns, so `stop` does
/// not write. It returns the first error that the recorder met while it
/// wrote the file or read a result, if any: the query that met it still
/// returned its live result.
///
/// ## Returns
///
/// - `Ok(Nil)`: the recorder stopped, and every query was recorded
/// - `Error(message)`: a query could not be recorded, or the recorder had
///   stopped already
///
/// ## Example
///
/// ### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_pog as pog
/// import dream_postgres/recorder
/// import gleam/result
/// import gleam/string
/// import snippets/guide_recording_setup.{connect, start_recorder}
/// import snippets/guide_recording_users.{type User, create_user, find_user}
///
/// pub fn create_and_find(db: pog.Connection) -> Result(User, pog.QueryError) {
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
  stop: fn(Subject(Result(Nil, String))) -> message,
) -> Result(Nil, String) {
  call(server, stop)
  |> result.replace_error("The recorder had stopped already.")
  |> result.flatten()
}

/// The default key: the SQL text exactly, and every parameter.
///
/// ## Example
///
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
/// ### The three keys of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_keys.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
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
) -> pog.Interceptor {
  pog.Interceptor(fn(request) {
    pog.Capture(on_result: fn(result) { add(server, settings, request, result) })
  })
}

// Runs in the process of the query, before the query returns. A failure
// here cannot change the result of the query (`pog.Capture` returns
// `Nil`), so the recorder keeps it, and `stop` returns it.
fn add(
  server: Server(RecordMessage),
  settings: Settings,
  request: pog.InterceptRequest,
  result: Result(#(Int, List(Dynamic)), pog.QueryError),
) -> Nil {
  let message = case to_recording(settings, request, result) {
    Ok(recording) -> Add(recording, _)
    Error(problem) -> Problem(problem, _)
  }
  case call(server, message) {
    // The recorder keeps a failed write itself
    Ok(Nil) -> Nil
    // The recorder stopped. Nothing can keep the failure.
    Error(Nil) -> Nil
  }
}

fn to_recording(
  settings: Settings,
  request: pog.InterceptRequest,
  result: Result(#(Int, List(Dynamic)), pog.QueryError),
) -> Result(Recording, String) {
  use query <- result.try(to_query(settings, request))
  use recorded <- result.map(to_result(result))
  Recording(query:, result: settings.result_transformer(query, recorded))
}

fn to_query(
  settings: Settings,
  request: pog.InterceptRequest,
) -> Result(RecordedQuery, String) {
  use parameters <- result.map(
    list.try_map(request.parameters, fn(parameter) {
      to_recorded(to_dynamic(parameter))
    })
    |> result.map_error(fn(term) {
      "A parameter of " <> request.sql <> " cannot be recorded: " <> term
    }),
  )
  settings.query_transformer(RecordedQuery(sql: request.sql, parameters:))
}

fn to_result(
  result: Result(#(Int, List(Dynamic)), pog.QueryError),
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
  use count <- result.try(to_recorded(dynamic.int(count)))
  use rows <- result.map(list.try_map(rows, to_recorded))
  Returned(count:, rows:)
}

fn playback_interceptor(
  server: Server(PlaybackMessage),
  settings: Settings,
) -> pog.Interceptor {
  pog.Interceptor(fn(request) { play(server, settings, request) })
}

fn play(
  server: Server(PlaybackMessage),
  settings: Settings,
  request: pog.InterceptRequest,
) -> pog.InterceptResult {
  let answer = {
    use query <- result.try(to_query(settings, request))
    call(server, Play(settings.key(query), query, _))
    |> result.replace_error("The recorder had stopped already.")
    |> result.flatten()
  }
  case answer {
    Ok(Returned(count:, rows:)) ->
      pog.Respond(count: from_count(count), rows: list.map(rows, from_recorded))
    Ok(Failed(error)) -> pog.Fail(error)
    Error(message) -> pog.Fail(no_recording(message))
  }
}

fn no_recording(message: String) -> pog.QueryError {
  pog.PostgresqlError(
    code: no_recording_code,
    name: no_recording_name,
    message: message,
  )
}

// The count of a recording is the term that the driver gave, which is an
// atom such as `table` for some commands.
fn from_count(count: RecordedValue) -> Int {
  coerce(from_recorded(count))
}

@external(erlang, "dream_postgres_recorder_ffi", "to_recorded")
fn to_recorded(term: Dynamic) -> Result(RecordedValue, String)

@external(erlang, "dream_postgres_recorder_ffi", "from_recorded")
fn from_recorded(value: RecordedValue) -> Dynamic

@external(erlang, "dream_postgres_recorder_ffi", "to_dynamic")
fn to_dynamic(value: pog.Value) -> Dynamic

@external(erlang, "dream_postgres_recorder_ffi", "to_dynamic")
fn coerce(value: Dynamic) -> Int

@external(erlang, "dream_postgres_recorder_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "dream_postgres_recorder_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

// The recorder processes. A recorder in record mode and one in playback
// mode run different processes, with different messages, so a message of
// one mode never reaches the process of the other.

type RecordMessage {
  Add(recording: Recording, reply: Subject(Nil))
  Problem(message: String, reply: Subject(Nil))
  StopRecording(reply: Subject(Result(Nil, String)))
}

type RecordState {
  RecordState(
    path: String,
    recordings: List(Recording),
    failure: Option(String),
  )
}

type PlaybackMessage {
  Play(
    key: String,
    query: RecordedQuery,
    reply: Subject(Result(RecordedResult, String)),
  )
  StopPlayback(reply: Subject(Result(Nil, String)))
}

type PlaybackState {
  PlaybackState(path: String, entries: List(Entry))
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
      let state = add_recording(state, recording)
      process.send(reply, Nil)
      actor.continue(state)
    }
    Problem(problem, reply) -> {
      process.send(reply, Nil)
      actor.continue(keep_failure(state, problem))
    }
    StopRecording(reply) -> {
      process.send(reply, failure_result(state.failure))
      actor.stop()
    }
  }
}

fn failure_result(failure: Option(String)) -> Result(Nil, String) {
  case failure {
    Some(problem) -> Error(problem)
    None -> Ok(Nil)
  }
}

// The recordings of the state are newest first. The whole file is written
// again for each query, so the file on disk always holds every query that
// returned.
fn add_recording(state: RecordState, recording: Recording) -> RecordState {
  let recordings = [recording, ..state.recordings]
  let state = RecordState(..state, recordings:)
  case write_file(state.path, recording.to_json(list.reverse(recordings))) {
    Ok(Nil) -> state
    Error(problem) -> keep_failure(state, problem)
  }
}

fn keep_failure(state: RecordState, problem: String) -> RecordState {
  case state.failure {
    None -> RecordState(..state, failure: Some(problem))
    Some(_) -> state
  }
}

fn handle_playback(
  state: PlaybackState,
  message: PlaybackMessage,
) -> actor.Next(PlaybackState, PlaybackMessage) {
  case message {
    Play(key, query, reply) -> {
      let #(answer, entries) = take(state.entries, key, query, state.path)
      process.send(reply, answer)
      actor.continue(PlaybackState(..state, entries:))
    }
    StopPlayback(reply) -> {
      process.send(reply, Ok(Nil))
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
) -> #(Result(RecordedResult, String), List(Entry)) {
  let #(before, rest) =
    list.split_while(entries, fn(entry) { entry.played || entry.key != key })
  case rest {
    [entry, ..after] -> #(
      Ok(entry.recording.result),
      list.append(before, [Entry(..entry, played: True), ..after]),
    )
    [] -> #(Error(miss_message(entries, key, query, path)), entries)
  }
}

fn miss_message(
  entries: List(Entry),
  key: String,
  query: RecordedQuery,
  path: String,
) -> String {
  let matching = list.count(entries, fn(entry) { entry.key == key })
  let describe =
    query.sql <> " with the parameters " <> parameters_text(query.parameters)
  case matching {
    0 -> "No recording in " <> path <> " matches " <> describe
    _ ->
      "Each recording in "
      <> path
      <> " that matches "
      <> describe
      <> " was played already"
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
