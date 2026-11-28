//// Record the queries of a test in one run, and play them back in the
//// next run with no database.
////
//// ### Record a test, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/error.{type PostgresError}
//// import dream_postgres/recorder.{
////   type Mode, type Recorder, intercept, match_on, mode, new, start,
//// }
//// import dream_postgres/recorder/match.{sql_and_parameters}
//// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
////
//// /// Starts the recorder of the test that creates an API key. The test
//// /// gives the mode, which it reads from its own config.
//// pub fn start_api_key_recorder(
////   recorder_mode: Mode,
//// ) -> Result(Recorder, Error(PostgresError)) {
////   new(file: "test/recordings/api_key_create.json")
////   |> mode(recorder_mode)
////   |> match_on(sql_and_parameters)
////   |> intercept(generated_uuids(keep: []))
////   |> intercept(timestamps_near_now(window_days: 400))
////   |> start
//// }
//// ```
////
//// Attach the started recorder to the config of the app with
//// `config.record`, and start the connection as the app does. In
//// `Record` mode the connection is a live pool, and the recorder saves
//// each request and the answer of PostgreSQL before the answer returns.
//// In `Playback` mode nothing connects: after the interceptors of the
//// config, the recording answers each request. The code under test is the
//// same in both modes, and the recorded cells go through the same codecs
//// and the same checks as live ones.
////
//// Playback follows the recorded order. The key of each request, from
//// `match_on`, must be the key of the next recorded request, else the
//// request fails with `RequestNotMatched`, which names both SQL texts. A
//// request after the last recorded one fails with `RequestNotRecorded`.
////
//// The interceptors of `intercept` change only the copy that the
//// recorder keeps: in `Record` mode what it saves, and in `Playback` mode
//// the request before its key is made. The secrets of the config apply
//// to the copy first. The app always gets the real answer in `Record`
//// mode, and the saved answer in `Playback` mode.

import dream_errors.{type Error}
import dream_postgres/copy/request.{
  type RowWatcher, CopyRows, RecordedRows, RowWatcher,
}
import dream_postgres/driver/cell.{
  type Cell, type StatementDescription, type TypeDescription,
}
import dream_postgres/error.{
  type PostgresError, type Reason, RecorderNotStarted, RecordingInUse,
  RecordingNotFound, RecordingNotWritten,
}
import dream_postgres/interceptor.{
  type Interceptor, type Outcome, type Request, CopyFromAnswer, CopyToAnswer,
  SqlAnswer, StatementAnswer,
}
import dream_postgres/recorder/match
import dream_postgres/recorder/recorder_process.{handle_message}
import dream_postgres/recorder/recorder_state.{
  type Message, type Session, type State, AbortedBy, OwnerDown, PassingThrough,
  PlayingBack, Save, Saving, State, Stop, Take, claim, recorder_down,
  start_failure,
}
import dream_postgres/recorder/recording_file.{
  is_file, read_recording, write_recording,
}
import dream_postgres/recorder/replay.{type Replay, Replay}
import dream_postgres/recorder/written_entry.{
  every_type, receive_all, watched_request, written_request,
}
import dream_postgres/recording.{type RecordedEntry}
import dream_postgres/secrets.{type Secrets}
import gleam/erlang/process.{type Down, type Pid, type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/result

/// What a recorder does with the requests of its connection.
pub type Mode {
  /// Each request runs on the database, and the recorder saves it and its
  /// answer to the recording file before the answer returns. The file is
  /// new for each run.
  Record
  /// Nothing connects: the recording answers each request. A missing file
  /// fails `start` with `RecordingNotFound`.
  Playback
  /// `Playback` when the recording file exists, else `Record`.
  RecordMissing
  /// Each request runs on the database, and nothing is saved or read.
  Passthrough
}

/// The settings of a recorder, before it starts.
pub opaque type RecorderBuilder {
  RecorderBuilder(
    path: String,
    mode: Mode,
    key: fn(Request) -> String,
    interceptors: List(Interceptor),
  )
}

/// A started recorder. Attach it to a config with `config.record`.
/// It stops with `pool.stop` of its connection, or when the
/// process that started it ends.
pub opaque type Recorder {
  Recorder(session: Session, subject: Subject(Message), pid: Pid)
}

/// How `pool.start` uses a recorder.
@internal
pub type Attachment {
  /// A pool, with this interceptor after all other interceptors.
  RecordingPool(interceptor: Interceptor)
  /// A pool with no interceptor of the recorder.
  PlainPool
  /// No pool: the replay answers each request. `recorder` is the
  /// recorder to stop with the connection.
  NoPool(replay: Replay, recorder: Recorder)
}

/// A recorder of the recording file at `path`, in `Playback` mode, with
/// the key `match.sql_and_parameters` and no interceptor.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn new(file path: String) -> RecorderBuilder {
  RecorderBuilder(
    path:,
    mode: Playback,
    key: match.sql_and_parameters,
    interceptors: [],
  )
}

/// Sets the mode.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn mode(builder: RecorderBuilder, mode: Mode) -> RecorderBuilder {
  RecorderBuilder(..builder, mode:)
}

/// Sets the key of each request: `match.sql_and_parameters`,
/// `match.sql_only`, or a function of the app. The recorder saves the key
/// with each request, and playback compares the key of each request with
/// the key of the next recorded request.
///
/// ### Match on the SQL only <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_sql_only_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_only}
///
/// /// A recorder that takes any parameters of the recorded SQL, for a test
/// /// whose parameters change in each run.
/// pub fn start_sql_only_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_list.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_only)
///   |> start
/// }
/// ```
pub fn match_on(
  builder: RecorderBuilder,
  key: fn(Request) -> String,
) -> RecorderBuilder {
  RecorderBuilder(..builder, key:)
}

/// Adds an interceptor that runs only on the copy that the recorder
/// keeps, after the interceptors added before. In `Record` mode it
/// changes what is saved: the request and the answer. In `Playback` mode
/// it changes the request before its key is made, and the app gets the
/// saved answer. See `dream_postgres/recorder/normalize`.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn intercept(
  builder: RecorderBuilder,
  added_interceptor: Interceptor,
) -> RecorderBuilder {
  RecorderBuilder(
    ..builder,
    interceptors: list.append(builder.interceptors, [added_interceptor]),
  )
}

/// Starts the recorder, in a process that ends with the process that
/// starts it. In `Record` mode it writes an empty recording first, and
/// makes each missing directory of the path. In `Playback` mode it reads
/// the recording. A path that another recorder that runs holds fails with
/// `RecordingInUse`.
///
/// ### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/recorder.{
///   type Mode, type Recorder, intercept, match_on, mode, new, start,
/// }
/// import dream_postgres/recorder/match.{sql_and_parameters}
/// import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}
///
/// /// Starts the recorder of the test that creates an API key. The test
/// /// gives the mode, which it reads from its own config.
/// pub fn start_api_key_recorder(
///   recorder_mode: Mode,
/// ) -> Result(Recorder, Error(PostgresError)) {
///   new(file: "test/recordings/api_key_create.json")
///   |> mode(recorder_mode)
///   |> match_on(sql_and_parameters)
///   |> intercept(generated_uuids(keep: []))
///   |> intercept(timestamps_near_now(window_days: 400))
///   |> start
/// }
/// ```
pub fn start(
  builder: RecorderBuilder,
) -> Result(Recorder, Error(PostgresError)) {
  let owner = process.self()
  actor.new_with_initialiser(5000, fn(subject) {
    Ok(initialised(builder, owner, subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map_error(RecorderNotStarted)
  |> result.try(started_recorder)
  |> result.map_error(start_failure)
}

fn started_recorder(
  started: actor.Started(#(Subject(Message), Result(Session, Reason))),
) -> Result(Recorder, Reason) {
  let #(subject, loaded) = started.data
  let recorder = Recorder(session: PassingThrough, subject:, pid: started.pid)
  case loaded {
    Ok(session) -> Ok(Recorder(..recorder, session:))
    Error(reason) -> {
      stop(recorder)
      Error(reason)
    }
  }
}

/// How `pool.start` uses the recorder, with the secrets of the
/// config it is attached to.
@internal
pub fn attachment(recorder: Recorder, secrets: Secrets) -> Attachment {
  case recorder.session {
    Saving ->
      RecordingPool(fn(request, next) {
        record(recorder, secrets, request, next)
      })
    PlayingBack ->
      NoPool(
        Replay(
          answer: fn(request) {
            ask(recorder, Take(request, secrets, _)) |> result.flatten
          },
          aborted_by: fn() { ask(recorder, AbortedBy) },
        ),
        recorder:,
      )
    PassingThrough -> PlainPool
  }
}

/// Stops the recorder. A request after it fails with `RecorderStopped`.
/// `pool.stop` of its connection calls it.
@internal
pub fn stop(recorder: Recorder) -> Nil {
  let monitor = process.monitor(recorder.pid)
  process.send(recorder.subject, Stop)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_down: Down) { Nil })
  |> process.selector_receive_forever
}

// --- The process --------------------------------------------------------------------

fn initialised(
  builder: RecorderBuilder,
  owner: Pid,
  subject: Subject(Message),
) -> actor.Initialised(
  State,
  Message,
  #(Subject(Message), Result(Session, Reason)),
) {
  let owner_monitor = process.monitor(owner)
  let loaded = load(builder)
  actor.initialised(State(
    path: builder.path,
    key: builder.key,
    interceptors: builder.interceptors,
    saved: [],
    waiting: result.map(loaded, fn(session) { session.1 })
      |> result.unwrap([]),
    aborted_by: None,
  ))
  |> actor.selecting(
    process.new_selector()
    |> process.select(subject)
    |> process.select_specific_monitor(owner_monitor, fn(_down: Down) {
      OwnerDown
    }),
  )
  |> actor.returning(#(subject, result.map(loaded, fn(session) { session.0 })))
}

// Takes the path for this process, then makes the file or reads it.
fn load(
  builder: RecorderBuilder,
) -> Result(#(Session, List(RecordedEntry)), Reason) {
  let path = builder.path
  use Nil <- result.try(case claim(path) {
    True -> Ok(Nil)
    False -> Error(RecordingInUse(path:))
  })
  case builder.mode, is_file(path) {
    Record, _ | RecordMissing, False ->
      write_recording(path, [])
      |> result.replace(#(Saving, []))
      |> result.map_error(RecordingNotWritten(path, _))
    Playback, True | RecordMissing, True ->
      read_recording(path)
      |> result.map(fn(entries) { #(PlayingBack, entries) })
    Playback, False -> Error(RecordingNotFound(path:))
    Passthrough, _ -> Ok(#(PassingThrough, []))
  }
}

// Sends a message to the recorder and waits for its answer. A recorder
// that is stopped gives `RecorderStopped`.
fn ask(
  recorder: Recorder,
  make: fn(Subject(answer)) -> Message,
) -> Result(answer, Reason) {
  let reply_to = process.new_subject()
  let monitor = process.monitor(recorder.pid)
  process.send(recorder.subject, make(reply_to))
  let answer =
    process.new_selector()
    |> process.select_map(reply_to, Ok)
    |> process.select_specific_monitor(monitor, recorder_down)
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

// --- The file -----------------------------------------------------------------------

// --- Record -------------------------------------------------------------------------

// Passes the request on with each parameter or row field watched, so the
// recorder sees each cell as it was written and its type, then saves the
// copy of the request with the answer. The app gets the answer of the
// database.
fn record(
  recorder: Recorder,
  secrets: Secrets,
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  let seen = process.new_subject()
  let outcome = next(watched_request(request, seen))
  let events = receive_all(seen, [])
  let copy = written_request(request, events)
  case outcome {
    Ok(CopyToAnswer(description:, types:, rows:)) ->
      Ok(CopyToAnswer(
        description:,
        types:,
        rows: request.watch(
          rows,
          stream_watcher(recorder, secrets, copy, description, types, []),
        ),
      ))
    Ok(StatementAnswer(types:, ..)) ->
      save(recorder, secrets, copy, outcome, every_type(events, types))
    Ok(SqlAnswer(..)) | Ok(CopyFromAnswer(..)) | Error(_) ->
      save(recorder, secrets, copy, outcome, every_type(events, []))
  }
}

fn save(
  recorder: Recorder,
  secrets: Secrets,
  copy: Request,
  outcome: Outcome,
  types: List(TypeDescription),
) -> Outcome {
  ask(recorder, Save(copy, outcome, types, secrets, _))
  |> result.flatten
  |> result.try(fn(_saved) { outcome })
}

// Sees each row of a `copy_to`, and saves the stream when it ends.
fn stream_watcher(
  recorder: Recorder,
  secrets: Secrets,
  copy: Request,
  description: StatementDescription,
  types: List(TypeDescription),
  rows: List(List(Cell)),
) -> RowWatcher {
  RowWatcher(
    take: fn(cells) {
      stream_watcher(recorder, secrets, copy, description, types, [
        cells,
        ..rows
      ])
    },
    finish: fn(ending) {
      let outcome =
        Ok(CopyToAnswer(
          description:,
          types:,
          rows: CopyRows(
            source: RecordedRows(rows: list.reverse(rows), ending:),
            watchers: [],
          ),
        ))
      save(recorder, secrets, copy, outcome, every_type([], types))
      |> result.replace(Nil)
    },
  )
}
// --- Saving -------------------------------------------------------------------------

// --- Playback -----------------------------------------------------------------------
