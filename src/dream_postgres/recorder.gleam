//// Record the queries of a test in one run, and play them back in the
//// next run with no database.
////
//// ### Record a test, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres.{type PostgresError}
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
//// `dream_postgres.record`, and start the connection as the app does. In
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
import dream_postgres/error.{
  type PostgresError, type Reason, type ServerError, PostgresError,
  RecorderNotStarted, RecorderStopped, RecordingInUse, RecordingNotDecoded,
  RecordingNotFound, RecordingNotRead, RecordingNotWritten, RequestNotMatched,
  RequestNotRecorded,
}
import dream_postgres/interceptor.{
  type Interceptor, type Outcome, type Request, CopyFrom, CopyFromAnswer, CopyTo,
  CopyToAnswer, Request, Sql, SqlAnswer, Statement, StatementAnswer,
}
import dream_postgres/internal/cell.{
  type Cell, type StatementDescription, type TypeDescription, CommandResult,
}
import dream_postgres/internal/copy
import dream_postgres/internal/copy_request.{
  type RowFeed, type RowWatcher, CopyRows, RecordedRows, RowWatcher,
}
import dream_postgres/internal/query.{
  type Value, type WriteEvent, SecretWritten, TypeChecked, TypeLookedUp, Written,
}
import dream_postgres/internal/replay.{type Replay, Replay}
import dream_postgres/internal/runner
import dream_postgres/posix.{type Posix}
import dream_postgres/recorder/match
import dream_postgres/recording.{
  type RecordedEntry, type RecordedFailure, type RecordedRequest,
  type WrittenParameter, type WrittenParameters, type WrittenRows,
  RecordedCopyFrom, RecordedCopyTo, RecordedEntry, RecordedSql,
  RecordedStatement, RecordedStream, Recording, SecretCell, StatementReply,
  WrittenParameters, WrittenRows,
}
import dream_postgres/secrets.{type Secrets}
import gleam/dict
import gleam/erlang/process.{type Down, type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// A started recorder. Attach it to a config with `dream_postgres.record`.
/// It stops with `dream_postgres.stop` of its connection, or when the
/// process that started it ends.
pub opaque type Recorder {
  Recorder(session: Session, subject: Subject(Message), pid: Pid)
}

/// What a started recorder does: its mode, with `RecordMissing` decided.
type Session {
  Saving
  PlayingBack
  PassingThrough
}

/// How `dream_postgres.start` uses a recorder.
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
/// import dream_postgres.{type PostgresError}
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
/// import dream_postgres.{type PostgresError}
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
/// import dream_postgres.{type PostgresError}
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
/// import dream_postgres.{type PostgresError}
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
/// import dream_postgres.{type PostgresError}
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

fn start_failure(reason: Reason) -> Error(PostgresError) {
  PostgresError(query_name: None, sql: None, reason:)
  |> error.to_dream_error
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

/// How `dream_postgres.start` uses the recorder, with the secrets of the
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
/// `dream_postgres.stop` of its connection calls it.
@internal
pub fn stop(recorder: Recorder) -> Nil {
  let monitor = process.monitor(recorder.pid)
  process.send(recorder.subject, Stop)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_down: Down) { Nil })
  |> process.selector_receive_forever
}

// --- The process --------------------------------------------------------------------

type State {
  State(
    path: String,
    key: fn(Request) -> String,
    interceptors: List(Interceptor),
    /// The entries saved so far, the last one first.
    saved: List(RecordedEntry),
    /// The entries of the recording not given yet, in recorded order.
    waiting: List(RecordedEntry),
    /// The server error of the last failed answer since the last answer
    /// that succeeded: what the transaction failed with.
    aborted_by: Option(ServerError),
  )
}

type Message {
  Save(
    request: Request,
    outcome: Outcome,
    types: List(TypeDescription),
    secrets: Secrets,
    reply: Subject(Result(Nil, Reason)),
  )
  Take(request: Request, secrets: Secrets, reply: Subject(Outcome))
  AbortedBy(reply: Subject(Option(ServerError)))
  Stop
  OwnerDown
}

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

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Save(request:, outcome:, types:, secrets:, reply:) -> {
      let #(saved, state) = save_copy(state, request, outcome, types, secrets)
      process.send(reply, saved)
      actor.continue(state)
    }
    Take(request:, secrets:, reply:) -> {
      let #(outcome, state) = take(state, request, secrets)
      process.send(reply, outcome)
      actor.continue(state)
    }
    AbortedBy(reply:) -> {
      process.send(reply, state.aborted_by)
      actor.continue(state)
    }
    Stop | OwnerDown -> actor.stop()
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

fn recorder_down(_down: Down) -> Result(answer, Reason) {
  Error(RecorderStopped)
}

// Runs the interceptors of the recorder on its copy of the request, with
// `outcome` at the end of the chain. Gives the request that reached the
// end, or the copy when an interceptor answered by itself, and the
// outcome that the interceptors made.
fn intercepted_copy(
  interceptors: List(Interceptor),
  request: Request,
  outcome: Outcome,
) -> #(Request, Outcome) {
  let reached_end = process.new_subject()
  let changed_outcome =
    runner.intercept(interceptors, request, fn(final_request) {
      process.send(reached_end, final_request)
      outcome
    })
  let final_request = process.receive(reached_end, 0) |> result.unwrap(request)
  #(final_request, changed_outcome)
}

// --- The file -----------------------------------------------------------------------

fn write_recording(
  path: String,
  entries: List(RecordedEntry),
) -> Result(Nil, Posix) {
  write_file(path, <<recording.to_file_text(Recording(entries:)):utf8>>)
}

fn read_recording(path: String) -> Result(List(RecordedEntry), Reason) {
  use bytes <- result.try(
    read_file(path) |> result.map_error(RecordingNotRead(path, _)),
  )
  recording.from_file_bytes(bytes)
  |> result.map(fn(read) { read.entries })
  |> result.map_error(fn(decode_error: json.DecodeError) {
    RecordingNotDecoded(path:, reason: decode_error)
  })
}

@external(erlang, "dream_postgres_recorder_ffi", "write_file")
fn write_file(path: String, bytes: BitArray) -> Result(Nil, Posix)

@external(erlang, "dream_postgres_recorder_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, Posix)

@external(erlang, "dream_postgres_recorder_ffi", "is_file")
fn is_file(path: String) -> Bool

/// Takes the path for the process that calls it, until it ends. `False`
/// when another process that runs holds it.
@external(erlang, "dream_postgres_recorder_ffi", "claim")
fn claim(path: String) -> Bool

// --- Record -------------------------------------------------------------------------

// What a watched value of a request did: the number of its row (0 for the
// parameters of a statement), its position, and the event.
type WriteSeen {
  WriteSeen(row_number: Int, position: Int, event: WriteEvent)
}

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
        rows: copy_request.watch(
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

fn watched_request(request: Request, seen: Subject(WriteSeen)) -> Request {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      Request(
        ..request,
        kind: CopyFrom(
          table:,
          columns:,
          rows: copy_request.map_rows(rows, fn(row_number, values) {
            watched_values(values, row_number, seen)
          }),
        ),
      )
    Statement | Sql | CopyTo ->
      Request(
        ..request,
        parameters: watched_values(request.parameters, 0, seen),
      )
  }
}

fn watched_values(
  values: List(Value),
  row_number: Int,
  seen: Subject(WriteSeen),
) -> List(Value) {
  list.index_map(values, fn(value, position) {
    query.watch(value, fn(event) {
      process.send(seen, WriteSeen(row_number:, position:, event:))
    })
  })
}

fn receive_all(
  seen: Subject(WriteSeen),
  received: List(WriteSeen),
) -> List(WriteSeen) {
  case process.receive(seen, 0) {
    Ok(write_seen) -> receive_all(seen, [write_seen, ..received])
    Error(Nil) -> list.reverse(received)
  }
}

// The request with each value that was written set to what it was
// written as.
fn written_request(request: Request, events: List(WriteSeen)) -> Request {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      Request(
        ..request,
        kind: CopyFrom(
          table:,
          columns:,
          rows: feed_rows(rows, [])
            |> list.index_map(fn(values, row_number) {
              written_values(values, events, row_number)
            })
            |> copy_request.feed(fn(values) { values }),
        ),
      )
    Statement | Sql | CopyTo ->
      Request(
        ..request,
        parameters: written_values(request.parameters, events, 0),
      )
  }
}

fn written_values(
  values: List(Value),
  events: List(WriteSeen),
  row_number: Int,
) -> List(Value) {
  list.index_map(values, fn(value, position) {
    let seen_here =
      events
      |> list.filter(fn(seen) {
        seen.row_number == row_number && seen.position == position
      })
      |> list.map(fn(seen) { seen.event })
    written_value(
      value,
      list.filter_map(seen_here, checked_type) |> list.first,
      list.filter_map(seen_here, write_of) |> list.first,
    )
  })
}

fn written_value(
  value: Value,
  checked: Result(TypeDescription, Nil),
  write: Result(WriteEvent, Nil),
) -> Value {
  case checked, write {
    Ok(type_description), Ok(Written(cell:)) ->
      query.written_as(value, type_description, cell)
    Ok(type_description), Ok(SecretWritten(..)) ->
      query.written_secret(value, type_description)
    Ok(_), Ok(TypeChecked(..))
    | Ok(_), Ok(TypeLookedUp(..))
    | Ok(_), Error(Nil)
    | Error(Nil), _
    -> value
  }
}

fn checked_type(event: WriteEvent) -> Result(TypeDescription, Nil) {
  case event {
    TypeChecked(type_description:) -> Ok(type_description)
    TypeLookedUp(..) | Written(..) | SecretWritten(..) -> Error(Nil)
  }
}

fn write_of(event: WriteEvent) -> Result(WriteEvent, Nil) {
  case event {
    Written(..) | SecretWritten(..) -> Ok(event)
    TypeChecked(..) | TypeLookedUp(..) -> Error(Nil)
  }
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

// Every type that the writes and the answer needed, each one time, in the
// order of their IDs.
fn every_type(
  events: List(WriteSeen),
  answer_types: List(TypeDescription),
) -> List(TypeDescription) {
  events
  |> list.filter_map(fn(seen) { event_type(seen.event) })
  |> list.append(answer_types)
  |> list.map(fn(type_description) { #(type_description.id, type_description) })
  |> dict.from_list
  |> dict.values
  |> list.sort(fn(left, right) { int.compare(left.id, right.id) })
}

fn event_type(event: WriteEvent) -> Result(TypeDescription, Nil) {
  case event {
    TypeChecked(type_description:) | TypeLookedUp(type_description:) ->
      Ok(type_description)
    Written(..) | SecretWritten(..) -> Error(Nil)
  }
}

fn feed_rows(rows: RowFeed, read: List(List(Value))) -> List(List(Value)) {
  case copy_request.next_row(rows) {
    Some(#(values, rest)) -> feed_rows(rest, [values, ..read])
    None -> list.reverse(read)
  }
}

// --- Saving -------------------------------------------------------------------------

// Saves the copy of a request with its outcome: the secrets first, then
// the interceptors of the recorder. A request that PostgreSQL did not
// answer is not saved.
fn save_copy(
  state: State,
  copy: Request,
  outcome: Outcome,
  types: List(TypeDescription),
  secrets: Secrets,
) -> #(Result(Nil, Reason), State) {
  let entry = {
    use secret_free <- result.map(secret_free_outcome(secrets, outcome))
    let #(final_request, final_outcome) =
      intercepted_copy(
        state.interceptors,
        Request(..copy, sql: secrets.replace_text(secrets, copy.sql)),
        secret_free,
      )
    recorded_request(final_request, final_outcome, types)
    |> option.map(RecordedEntry(key: state.key(final_request), request: _))
  }
  case entry {
    Ok(Some(entry)) -> {
      let saved = [entry, ..state.saved]
      #(
        write_recording(state.path, list.reverse(saved))
          |> result.map_error(RecordingNotWritten(state.path, _)),
        State(..state, saved:),
      )
    }
    Ok(None) -> #(Ok(Nil), state)
    Error(reason) -> #(Error(reason), state)
  }
}

fn secret_free_outcome(
  secrets: Secrets,
  outcome: Outcome,
) -> Result(Outcome, Reason) {
  case outcome {
    Ok(StatementAnswer(description:, types:, result:)) ->
      secrets.replace_columns(secrets, description, types, result.rows)
      |> result.map(fn(rows) {
        Ok(StatementAnswer(
          description:,
          types:,
          result: CommandResult(..result, rows:),
        ))
      })
    Ok(CopyToAnswer(
      description:,
      types:,
      rows: CopyRows(source: RecordedRows(rows:, ending:), watchers:),
    )) ->
      secrets.replace_columns(secrets, description, types, rows)
      |> result.map(fn(rows) {
        Ok(CopyToAnswer(
          description:,
          types:,
          rows: CopyRows(source: RecordedRows(rows:, ending:), watchers:),
        ))
      })
    Ok(CopyToAnswer(..))
    | Ok(SqlAnswer(..))
    | Ok(CopyFromAnswer(..))
    | Error(_) -> Ok(outcome)
  }
}

fn recorded_request(
  request: Request,
  outcome: Outcome,
  types: List(TypeDescription),
) -> Option(RecordedRequest) {
  case request.kind, outcome {
    Statement, Ok(StatementAnswer(description:, result:, ..)) ->
      Some(RecordedStatement(
        sql: request.sql,
        parameters: written_parameters(request.parameters),
        types:,
        outcome: Ok(StatementReply(description:, result:)),
      ))
    Sql, Ok(SqlAnswer(results:)) ->
      Some(RecordedSql(sql: request.sql, outcome: Ok(results)))
    CopyFrom(rows:, ..), Ok(CopyFromAnswer(count:)) ->
      Some(RecordedCopyFrom(
        sql: request.sql,
        rows: written_rows(rows),
        types:,
        outcome: Ok(count),
      ))
    CopyTo,
      Ok(CopyToAnswer(
        description:,
        rows: CopyRows(source: RecordedRows(rows:, ending:), ..),
        ..,
      ))
    ->
      recorded_ending(ending)
      |> option.map(fn(recorded_end) {
        RecordedCopyTo(
          sql: request.sql,
          types:,
          outcome: Ok(RecordedStream(description:, rows:, ending: recorded_end)),
        )
      })
    // An answer of another kind than the request: it is not one that
    // PostgreSQL gave, so it is not saved.
    Statement, Ok(_) | Sql, Ok(_) | CopyFrom(..), Ok(_) | CopyTo, Ok(_) -> None
    Statement, Error(reason)
    | Sql, Error(reason)
    | CopyFrom(..), Error(reason)
    | CopyTo, Error(reason)
    ->
      recording.recorded_failure(reason)
      |> option.map(failed_request(request, _, types))
  }
}

fn failed_request(
  request: Request,
  failure: RecordedFailure,
  types: List(TypeDescription),
) -> RecordedRequest {
  case request.kind {
    Statement ->
      RecordedStatement(
        sql: request.sql,
        parameters: written_parameters(request.parameters),
        types:,
        outcome: Error(failure),
      )
    Sql -> RecordedSql(sql: request.sql, outcome: Error(failure))
    CopyFrom(rows:, ..) ->
      RecordedCopyFrom(
        sql: request.sql,
        rows: written_rows(rows),
        types:,
        outcome: Error(failure),
      )
    CopyTo -> RecordedCopyTo(sql: request.sql, types:, outcome: Error(failure))
  }
}

fn recorded_ending(
  ending: Result(Nil, Reason),
) -> Option(Result(Nil, RecordedFailure)) {
  case ending {
    Ok(Nil) -> Some(Ok(Nil))
    Error(reason) -> recording.recorded_failure(reason) |> option.map(Error)
  }
}

// The parameters as written, when each one was written. A secret
// parameter is kept as its codec, with no cell.
fn written_parameters(values: List(Value)) -> Option(WrittenParameters) {
  values
  |> list.try_map(fn(value) {
    case query.written(value) {
      Some(query.WrittenCell(type_description:, cell:)) ->
        Ok(#(type_description, recording.WrittenCell(cell:)))
      Some(query.WrittenSecret(type_description:)) ->
        Ok(#(type_description, SecretCell(codec: query.codec_name(value))))
      None -> Error(Nil)
    }
  })
  |> result.map(fn(written: List(#(TypeDescription, WrittenParameter))) {
    let #(types, parameters) = list.unzip(written)
    WrittenParameters(types:, parameters:)
  })
  |> option.from_result
}

// The rows as written, when each field of each row was written. A field
// of a `copy_from` row is never secret: `codec.field` makes it.
fn written_rows(rows: RowFeed) -> Option(WrittenRows) {
  feed_rows(rows, [])
  |> list.try_map(fn(values) {
    list.try_map(values, fn(value) {
      case query.written(value) {
        Some(query.WrittenCell(type_description:, cell:)) ->
          Ok(#(type_description, cell))
        Some(query.WrittenSecret(..)) | None -> Error(Nil)
      }
    })
  })
  |> result.map(fn(written) {
    WrittenRows(
      types: written
        |> list.first
        |> result.map(fn(row) { list.map(row, fn(field) { field.0 }) })
        |> result.unwrap([]),
      rows: list.map(written, list.map(_, fn(field) { field.1 })),
    )
  })
  |> option.from_result
}

// --- Playback -----------------------------------------------------------------------

// Answers a request with the next entry of the recording, when the key of
// the request is the key of the entry. A request that the entry does not
// answer leaves the recording as it was.
fn take(state: State, request: Request, secrets: Secrets) -> #(Outcome, State) {
  let sql = secrets.replace_text(secrets, request.sql)
  case state.waiting {
    [] -> #(Error(RequestNotRecorded(sql:)), state)
    [entry, ..rest] ->
      answered(
        state,
        entry,
        rest,
        answer_of_entry(state, entry, Request(..request, sql:)),
      )
  }
}

fn answered(
  state: State,
  entry: RecordedEntry,
  rest: List(RecordedEntry),
  answer: Result(Outcome, Reason),
) -> #(Outcome, State) {
  case answer {
    Ok(outcome) -> #(outcome, given(state, entry, rest))
    Error(reason) -> #(Error(reason), state)
  }
}

// The saved outcome of the entry, or why the entry does not answer the
// request: its key is another, or its values cannot be written with the
// recorded types, as a live run could not write them.
fn answer_of_entry(
  state: State,
  entry: RecordedEntry,
  request: Request,
) -> Result(Outcome, Reason) {
  let recorded_sql = recorded_sql(entry.request)
  let not_matched = RequestNotMatched(recorded_sql:, sql: request.sql)
  use written <- result.try(
    written_like(request, entry.request)
    |> result.map_error(fn(reason) {
      case request.sql == recorded_sql {
        True -> reason
        False -> not_matched
      }
    }),
  )
  let outcome = recorded_outcome(entry.request)
  let #(final_request, _changed_outcome) =
    intercepted_copy(state.interceptors, written, outcome)
  case state.key(final_request) == entry.key {
    True -> Ok(outcome)
    False -> Error(not_matched)
  }
}

// The state after an entry answered: a failed answer fails the
// transaction, and the first failure is what it failed with. An answer
// that succeeded means no transaction is failed.
fn given(
  state: State,
  entry: RecordedEntry,
  rest: List(RecordedEntry),
) -> State {
  case entry_failure(entry.request) {
    Ok(Nil) -> State(..state, waiting: rest, aborted_by: None)
    Error(failure) ->
      State(
        ..state,
        waiting: rest,
        aborted_by: option.or(state.aborted_by, Some(failure.server_error)),
      )
  }
}

fn entry_failure(request: RecordedRequest) -> Result(Nil, RecordedFailure) {
  case request {
    RecordedStatement(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedSql(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedCopyFrom(outcome:, ..) -> result.replace(outcome, Nil)
    RecordedCopyTo(outcome:, ..) -> result.replace(outcome, Nil)
  }
}

fn recorded_sql(request: RecordedRequest) -> String {
  case request {
    RecordedStatement(sql:, ..)
    | RecordedSql(sql:, ..)
    | RecordedCopyFrom(sql:, ..)
    | RecordedCopyTo(sql:, ..) -> sql
  }
}

// The request with its values written with the recorded types, as the
// live run wrote them.
fn written_like(
  request: Request,
  recorded: RecordedRequest,
) -> Result(Request, Reason) {
  case request.kind {
    CopyFrom(table:, columns:, rows:) ->
      rows_written_like(rows, columns, recorded)
      |> result.map(fn(rows) {
        Request(..request, kind: CopyFrom(table:, columns:, rows:))
      })
    Statement | Sql | CopyTo ->
      parameters_written_like(request.parameters, recorded)
      |> result.map(fn(parameters) { Request(..request, parameters:) })
  }
}

fn parameters_written_like(
  values: List(Value),
  recorded: RecordedRequest,
) -> Result(List(Value), Reason) {
  case recorded {
    RecordedStatement(
      parameters: Some(WrittenParameters(types: parameter_types, ..)),
      types:,
      ..,
    ) ->
      query.write_values(values, parameter_types, lookup_of(types))
      |> result.map(fn(written) {
        list.zip(values, parameter_types)
        |> list.map2(written.values, fn(pair, cell) {
          query.written_as(pair.0, pair.1, cell)
        })
      })
    RecordedStatement(parameters: None, ..)
    | RecordedSql(..)
    | RecordedCopyFrom(..)
    | RecordedCopyTo(..) -> Ok(values)
  }
}

fn rows_written_like(
  rows: RowFeed,
  columns: List(String),
  recorded: RecordedRequest,
) -> Result(RowFeed, Reason) {
  case recorded {
    RecordedCopyFrom(
      rows: Some(WrittenRows(types: column_types, ..)),
      types:,
      ..,
    ) ->
      feed_rows(rows, [])
      |> list.try_map(fn(values) {
        copy.write_row(values, column_types, lookup_of(types), columns)
        |> result.map(fn(fields) {
          list.zip(values, column_types)
          |> list.map2(fields, fn(pair, field) {
            query.written_as(pair.0, pair.1, copy.field_cell(field))
          })
        })
      })
      |> result.map(copy_request.feed(_, fn(values) { values }))
    RecordedCopyFrom(rows: None, ..)
    | RecordedStatement(..)
    | RecordedSql(..)
    | RecordedCopyTo(..) -> Ok(rows)
  }
}

fn lookup_of(
  types: List(TypeDescription),
) -> fn(Int) -> Result(TypeDescription, Nil) {
  let by_id =
    types
    |> list.map(fn(type_description) {
      #(type_description.id, type_description)
    })
    |> dict.from_list
  dict.get(by_id, _)
}

fn recorded_outcome(recorded: RecordedRequest) -> Outcome {
  case recorded {
    RecordedStatement(types:, outcome:, ..) ->
      outcome
      |> result.map(fn(reply) {
        StatementAnswer(
          description: reply.description,
          types:,
          result: reply.result,
        )
      })
      |> result.map_error(recording.failure_reason)
    RecordedSql(outcome:, ..) ->
      outcome
      |> result.map(SqlAnswer)
      |> result.map_error(recording.failure_reason)
    RecordedCopyFrom(outcome:, ..) ->
      outcome
      |> result.map(CopyFromAnswer)
      |> result.map_error(recording.failure_reason)
    RecordedCopyTo(types:, outcome:, ..) ->
      outcome
      |> result.map(fn(stream) {
        CopyToAnswer(
          description: stream.description,
          types:,
          rows: CopyRows(
            source: RecordedRows(
              rows: stream.rows,
              ending: result.map_error(stream.ending, recording.failure_reason),
            ),
            watchers: [],
          ),
        )
      })
      |> result.map_error(recording.failure_reason)
  }
}
