//// A recording: the requests of a test and the answers that PostgreSQL
//// gave them, as a recorder in record mode saves them, and a recorder in
//// playback mode gives them back.
////
//// A recording is a JSON file. Its text is the same for the same requests
//// and answers: the keys of each object are in alphabetical order, there
//// is no time in it, and each request is on its own line, in the order
//// the answers came. Each request has its key, which playback compares.
//// Each cell is hex, so a value is exactly the bytes that went over the
//// wire. A parameter of `secret_parameter` is
//// `{"secret":{"codec":"<codec>"}}`, with no bytes. With each request are
//// the types that its codecs need, so playback checks the codecs as a
//// live run does.
////
//// ### A recording of one BEGIN <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/begin_recording.json"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```json
//// {
////   "dream_postgres_recording": 1,
////   "entries": [
////     {"key":"script\nBEGIN","script":{"outcome":{"answer":{"results":[{"count":0,"rows":[],"tag":"BEGIN"}]}},"sql":"BEGIN"}}
////   ]
//// }
//// ```

import dream_postgres/error.{
  type Reason, type ServerError, type Severity, AmbiguousColumnName,
  CatalogProcessDown, ChannelTooLong, ColumnCountMismatch, ColumnReadTwice,
  ColumnTypeMismatch, CommitRolledBack, ConnectFailed, ConnectionLost,
  ConnectionProcessDown, CopyNeedsBinaryCodec, CopyNotRunning, CopyNotStarted,
  CopyQueryHasParameters, CopyStatementRefused, DebugSeverity, DecodeFailed,
  EncodeFailed, ErrorSeverity, FatalSeverity, InfoSeverity, InterceptorFailed,
  InvalidConfig, ListenerStartFailed, ListenerStopped, LogSeverity,
  MalformedCopyStream, MixedColumnReaders, NoColumnAtPosition, NoColumnNamed,
  NoConnection, NoDatabaseToVerify, NoticeSeverity, OptionsInNestedTransaction,
  PanicSeverity, ParameterCountMismatch, ParameterTypeMismatch,
  PoolHasNoDatabase, PoolStartFailed, PoolStopped, ProtocolViolation,
  QueryTimeout, ReaderDependsOnValue, RecorderNotStarted, RecorderStopped,
  RecordingInUse, RecordingNotDecoded, RecordingNotFound, RecordingNotRead,
  RecordingNotWritten, RequestNotMatched, RequestNotRecorded, RequestNotWritable,
  RollbackAlsoFailed, ScriptStatementFailed, SecretColumnNotReplaced, Server,
  StatementChangedDuringRun, SubscriberHasNoProcess, TooManyRows,
  UndecodableServerMessage, UnexpectedCommitAnswer, UnexpectedIdleMessage,
  UnexpectedListenAnswer, UnexpectedNull, UnexpectedServerMessage, UnknownType,
  UnlistedSeverity, UnreadableCatalog, ValueOutOfRange, WarningSeverity,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type CommandResult,
  type StatementDescription, type TypeDescription, type TypeKind, Array, Base,
  Binary, ColumnDescription, CommandResult, Composite, Domain, Enum, Multirange,
  Null, ParameterDescription, Pseudo, Range, StatementDescription, Text,
  TypeDescription,
}
import dream_postgres/sql_state
import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The number of the file format. A file of another format is not read.
const format = 1

/// The entries of a recording, in the order their answers came.
pub type Recording {
  Recording(entries: List(RecordedEntry))
}

/// One request of a recording with its key: what `recorder.match_on` made
/// of the request. In playback, the key of each request must be the key
/// of the next entry.
pub type RecordedEntry {
  RecordedEntry(key: String, request: RecordedRequest)
}

/// One request and the answer that PostgreSQL gave it.
pub type RecordedRequest {
  /// A statement of `all`, `one`, `maybe_one` or `affected`. `parameters`
  /// is `None` when the request failed before its parameters were
  /// written: then only the SQL picks it.
  RecordedStatement(
    sql: String,
    parameters: Option(WrittenParameters),
    types: List(TypeDescription),
    outcome: Result(StatementReply, RecordedFailure),
  )
  /// A script, or a command of a transaction.
  RecordedScript(
    sql: String,
    outcome: Result(List(CommandResult), RecordedFailure),
  )
  /// A `copy_from`. `rows` is `None` when the request failed before each
  /// row was written: then only the SQL picks it.
  RecordedCopyFrom(
    sql: String,
    rows: Option(WrittenRows),
    types: List(TypeDescription),
    outcome: Result(Int, RecordedFailure),
  )
  /// A `copy_to`: the SQL is the query inside the COPY.
  RecordedCopyTo(
    sql: String,
    types: List(TypeDescription),
    outcome: Result(RecordedStream, RecordedFailure),
  )
}

/// The parameters of a statement as they were written: the type of each
/// parameter, and its cell or its secret mark.
pub type WrittenParameters {
  WrittenParameters(
    types: List(TypeDescription),
    parameters: List(WrittenParameter),
  )
}

/// One parameter of a statement as it was written.
pub type WrittenParameter {
  /// The cell of the parameter: exactly the bytes that went over the
  /// wire.
  WrittenCell(cell: Cell)
  /// A parameter of `dream_postgres.secret_parameter`. The file keeps the
  /// name of its codec and no bytes, and playback takes any value with
  /// that codec at that position.
  SecretCell(codec: String)
}

/// The rows of a `copy_from` as they were written: the type of each
/// column, and the cells of each row.
pub type WrittenRows {
  WrittenRows(types: List(TypeDescription), rows: List(List(Cell)))
}

/// The answer to a statement: its description and its result.
pub type StatementReply {
  StatementReply(description: StatementDescription, result: CommandResult)
}

/// The answer to a `copy_to`: the description of the query, its rows, and
/// how the stream of them ended.
pub type RecordedStream {
  RecordedStream(
    description: StatementDescription,
    rows: List(List(Cell)),
    ending: Result(Nil, RecordedFailure),
  )
}

/// A failure that PostgreSQL gave: the only failures a recording holds. A
/// failure of the client, such as a codec that does not take the type of
/// its column, comes again from the recorded types.
pub type RecordedFailure {
  /// `error.Server`.
  RecordedServerError(server_error: ServerError)
  /// `error.ScriptStatementFailed`.
  RecordedScriptFailure(server_error: ServerError, statements_run: Int)
}

/// The recorded failure of a reason, or `None` when PostgreSQL did not
/// give the reason.
///
/// ### Record a server error and replay it <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/replay_server_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/error.{type Reason, type ServerError, Server}
/// import dream_postgres/recording.{failure_reason, recorded_failure}
/// import gleam/option.{type Option}
///
/// /// A server error goes into a recording as a `RecordedServerError`, and
/// /// comes back as the same reason: `Some(Server(server_error))`.
/// pub fn replay_server_error(server_error: ServerError) -> Option(Reason) {
///   Server(server_error)
///   |> recorded_failure
///   |> option.map(failure_reason)
/// }
/// ```
pub fn recorded_failure(reason: Reason) -> Option(RecordedFailure) {
  case reason {
    Server(server_error) -> Some(RecordedServerError(server_error:))
    ScriptStatementFailed(statements_run:, server_error:) ->
      Some(RecordedScriptFailure(statements_run:, server_error:))
    ConnectFailed(..)
    | ConnectionLost(..)
    | NoConnection
    | QueryTimeout(..)
    | ProtocolViolation(..)
    | ParameterCountMismatch(..)
    | ParameterTypeMismatch(..)
    | ColumnCountMismatch(..)
    | ColumnTypeMismatch(..)
    | NoColumnAtPosition(..)
    | NoColumnNamed(..)
    | AmbiguousColumnName(..)
    | ColumnReadTwice(..)
    | MixedColumnReaders
    | ReaderDependsOnValue(..)
    | StatementChangedDuringRun
    | EncodeFailed(..)
    | UnexpectedNull(..)
    | ValueOutOfRange(..)
    | DecodeFailed(..)
    | TooManyRows(..)
    | CommitRolledBack(..)
    | InterceptorFailed(..)
    | RequestNotRecorded(..)
    | RequestNotMatched(..)
    | RecordingNotWritten(..)
    | RecordingNotFound(..)
    | RecordingNotRead(..)
    | RecordingNotDecoded(..)
    | RecordingInUse(..)
    | RecorderNotStarted(..)
    | RecorderStopped
    | PoolHasNoDatabase
    | SecretColumnNotReplaced(..)
    | CopyStatementRefused(..)
    | CopyNotStarted(..)
    | CopyNotRunning
    | RequestNotWritable(..)
    | ConnectionProcessDown
    | UnknownType(..)
    | UnreadableCatalog(..)
    | CatalogProcessDown
    | UndecodableServerMessage(..)
    | UnexpectedServerMessage(..)
    | UnexpectedIdleMessage(..)
    | InvalidConfig(..)
    | PoolStartFailed(..)
    | PoolStopped
    | NoDatabaseToVerify
    | OptionsInNestedTransaction
    | UnexpectedCommitAnswer(..)
    | RollbackAlsoFailed(..)
    | CopyNeedsBinaryCodec(..)
    | CopyQueryHasParameters(..)
    | MalformedCopyStream(..)
    | ChannelTooLong(..)
    | SubscriberHasNoProcess
    | UnexpectedListenAnswer
    | ListenerStopped
    | ListenerStartFailed(..) -> None
  }
}

/// The reason of a recorded failure, as PostgreSQL gave it.
///
/// ### Record a server error and replay it <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/replay_server_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/error.{type Reason, type ServerError, Server}
/// import dream_postgres/recording.{failure_reason, recorded_failure}
/// import gleam/option.{type Option}
///
/// /// A server error goes into a recording as a `RecordedServerError`, and
/// /// comes back as the same reason: `Some(Server(server_error))`.
/// pub fn replay_server_error(server_error: ServerError) -> Option(Reason) {
///   Server(server_error)
///   |> recorded_failure
///   |> option.map(failure_reason)
/// }
/// ```
pub fn failure_reason(failure: RecordedFailure) -> Reason {
  case failure {
    RecordedServerError(server_error:) -> Server(server_error)
    RecordedScriptFailure(statements_run:, server_error:) ->
      ScriptStatementFailed(statements_run:, server_error:)
  }
}

// --- Writing ------------------------------------------------------------------------

/// The text of the recording file.
///
/// ### The text of an empty recording <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/empty_recording_text.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recording.{Recording, to_file_text}
///
/// /// The text of a recording with no request:
/// /// "{\n  \"dream_postgres_recording\": 1,\n  \"entries\": []\n}\n"
/// pub fn empty_recording_text() -> String {
///   to_file_text(Recording(entries: []))
/// }
/// ```
pub fn to_file_text(recording: Recording) -> String {
  let entries = case recording.entries {
    [] -> "[]"
    entries ->
      "[\n    "
      <> entries
      |> list.map(fn(entry) { json.to_string(entry_json(entry)) })
      |> string.join(",\n    ")
      <> "\n  ]"
  }
  "{\n  \"dream_postgres_recording\": "
  <> json.to_string(json.int(format))
  <> ",\n  \"entries\": "
  <> entries
  <> "\n}\n"
}

// An object with its keys in alphabetical order, so the same value always
// gives the same text.
fn sorted_object(entries: List(#(String, Json))) -> Json {
  entries
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> json.object
}

fn entry_json(entry: RecordedEntry) -> Json {
  sorted_object([
    #("key", json.string(entry.key)),
    request_member(entry.request),
  ])
}

fn request_member(request: RecordedRequest) -> #(String, Json) {
  case request {
    RecordedStatement(sql:, parameters:, types:, outcome:) -> #(
      "statement",
      sorted_object([
        #("sql", json.string(sql)),
        #("parameters", json.nullable(parameters, written_parameters_json)),
        #("types", json.array(types, type_json)),
        #("outcome", outcome_json(outcome, statement_reply_json)),
      ]),
    )
    RecordedScript(sql:, outcome:) -> #(
      "script",
      sorted_object([
        #("sql", json.string(sql)),
        #(
          "outcome",
          outcome_json(outcome, fn(results) {
            sorted_object([#("results", json.array(results, result_json))])
          }),
        ),
      ]),
    )
    RecordedCopyFrom(sql:, rows:, types:, outcome:) -> #(
      "copy_from",
      sorted_object([
        #("sql", json.string(sql)),
        #("rows", json.nullable(rows, written_rows_json)),
        #("types", json.array(types, type_json)),
        #(
          "outcome",
          outcome_json(outcome, fn(count) {
            sorted_object([#("count", json.int(count))])
          }),
        ),
      ]),
    )
    RecordedCopyTo(sql:, types:, outcome:) -> #(
      "copy_to",
      sorted_object([
        #("sql", json.string(sql)),
        #("types", json.array(types, type_json)),
        #("outcome", outcome_json(outcome, stream_json)),
      ]),
    )
  }
}

fn outcome_json(
  outcome: Result(answer, RecordedFailure),
  answer_json: fn(answer) -> Json,
) -> Json {
  case outcome {
    Ok(answer) -> sorted_object([#("answer", answer_json(answer))])
    Error(failure) -> sorted_object([#("failure", failure_json(failure))])
  }
}

fn written_parameters_json(written: WrittenParameters) -> Json {
  sorted_object([
    #("types", json.array(written.types, type_json)),
    #("cells", json.array(written.parameters, written_parameter_json)),
  ])
}

fn written_parameter_json(parameter: WrittenParameter) -> Json {
  case parameter {
    WrittenCell(cell:) -> cell_json(cell)
    SecretCell(codec:) ->
      sorted_object([
        #("secret", sorted_object([#("codec", json.string(codec))])),
      ])
  }
}

fn written_rows_json(written: WrittenRows) -> Json {
  sorted_object([
    #("types", json.array(written.types, type_json)),
    #("rows", json.array(written.rows, row_json)),
  ])
}

fn statement_reply_json(reply: StatementReply) -> Json {
  sorted_object([
    #("description", description_json(reply.description)),
    #("result", result_json(reply.result)),
  ])
}

fn stream_json(stream: RecordedStream) -> Json {
  sorted_object([
    #("description", description_json(stream.description)),
    #("rows", json.array(stream.rows, row_json)),
    #("failure", case stream.ending {
      Ok(Nil) -> json.null()
      Error(failure) -> failure_json(failure)
    }),
  ])
}

fn failure_json(failure: RecordedFailure) -> Json {
  case failure {
    RecordedServerError(server_error:) ->
      sorted_object([#("server_error", server_error_json(server_error))])
    RecordedScriptFailure(statements_run:, server_error:) ->
      sorted_object([
        #(
          "script_statement_failed",
          sorted_object([
            #("statements_run", json.int(statements_run)),
            #("server_error", server_error_json(server_error)),
          ]),
        ),
      ])
  }
}

fn server_error_json(server_error: ServerError) -> Json {
  let text = fn(value) { json.nullable(value, json.string) }
  let number = fn(value) { json.nullable(value, json.int) }
  sorted_object([
    #("severity", json.string(severity_name(server_error.severity))),
    #("code", json.string(sql_state.to_string(server_error.sql_state))),
    #("message", json.string(server_error.message)),
    #("detail", text(server_error.detail)),
    #("hint", text(server_error.hint)),
    #("position", number(server_error.position)),
    #("internal_position", number(server_error.internal_position)),
    #("internal_query", text(server_error.internal_query)),
    #("context", text(server_error.context)),
    #("schema", text(server_error.schema)),
    #("table", text(server_error.table)),
    #("column", text(server_error.column)),
    #("data_type", text(server_error.data_type)),
    #("constraint", text(server_error.constraint)),
    #("file", text(server_error.file)),
    #("line", number(server_error.line)),
    #("routine", text(server_error.routine)),
    #("localized_severity", json.string(server_error.localized_severity)),
    #(
      "other_fields",
      json.array(server_error.other_fields, fn(field) {
        sorted_object([
          #("code", json.int(field.0)),
          #("value", json.string(field.1)),
        ])
      }),
    ),
  ])
}

// The severity as PostgreSQL sends it, which `error` reads back.
fn severity_name(severity: Severity) -> String {
  case severity {
    ErrorSeverity -> "ERROR"
    FatalSeverity -> "FATAL"
    PanicSeverity -> "PANIC"
    WarningSeverity -> "WARNING"
    NoticeSeverity -> "NOTICE"
    DebugSeverity -> "DEBUG"
    InfoSeverity -> "INFO"
    LogSeverity -> "LOG"
    UnlistedSeverity(name:) -> name
  }
}

fn description_json(description: StatementDescription) -> Json {
  sorted_object([
    #(
      "parameter_type_ids",
      json.array(description.parameters, fn(parameter) {
        json.int(parameter.type_id)
      }),
    ),
    #("columns", json.array(description.columns, column_json)),
  ])
}

fn column_json(column: ColumnDescription) -> Json {
  sorted_object([
    #("name", json.string(column.name)),
    #("type_id", json.int(column.type_id)),
    #("type_modifier", json.int(column.type_modifier)),
    #("table_id", json.int(column.table_id)),
    #("column_number", json.int(column.column_number)),
  ])
}

fn result_json(command_result: CommandResult) -> Json {
  sorted_object([
    #("rows", json.array(command_result.rows, row_json)),
    #("tag", json.string(command_result.tag)),
    #("count", json.int(command_result.count)),
  ])
}

fn row_json(cells: List(Cell)) -> Json {
  json.array(cells, cell_json)
}

fn cell_json(value: Cell) -> Json {
  case value {
    Binary(bytes:) -> sorted_object([#("binary", hex_json(bytes))])
    Text(bytes:) -> sorted_object([#("text", hex_json(bytes))])
    Null -> json.null()
  }
}

fn hex_json(bytes: BitArray) -> Json {
  json.string(string.lowercase(bit_array.base16_encode(bytes)))
}

fn type_json(type_description: TypeDescription) -> Json {
  sorted_object([
    #("id", json.int(type_description.id)),
    #("schema", json.string(type_description.schema)),
    #("name", json.string(type_description.name)),
    #("kind", kind_json(type_description.kind)),
  ])
}

fn kind_json(kind: TypeKind) -> Json {
  let id_of = fn(name, type_id) { sorted_object([#(name, json.int(type_id))]) }
  case kind {
    Base -> sorted_object([#("base", sorted_object([]))])
    Pseudo -> sorted_object([#("pseudo", sorted_object([]))])
    Enum(labels:) ->
      sorted_object([
        #("enum", sorted_object([#("labels", json.array(labels, json.string))])),
      ])
    Composite(fields:) ->
      sorted_object([
        #(
          "composite",
          sorted_object([
            #(
              "fields",
              json.array(fields, fn(field) {
                sorted_object([
                  #("name", json.string(field.0)),
                  #("type_id", json.int(field.1)),
                ])
              }),
            ),
          ]),
        ),
      ])
    Domain(base_type_id:) ->
      sorted_object([#("domain", id_of("base_type_id", base_type_id))])
    Range(element_type_id:) ->
      sorted_object([#("range", id_of("element_type_id", element_type_id))])
    Multirange(range_type_id:) ->
      sorted_object([#("multirange", id_of("range_type_id", range_type_id))])
    Array(element_type_id:) ->
      sorted_object([#("array", id_of("element_type_id", element_type_id))])
  }
}

// --- Reading ------------------------------------------------------------------------

/// The recording of the bytes of a recording file.
///
/// ### Read a recording file <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/read_recording.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/recording.{type Recording, from_file_bytes}
/// import gleam/json
///
/// /// Reads the bytes of a recording file.
/// pub fn read_recording(bytes: BitArray) -> Result(Recording, json.DecodeError) {
///   from_file_bytes(bytes)
/// }
/// ```
pub fn from_file_bytes(bytes: BitArray) -> Result(Recording, json.DecodeError) {
  json.parse_bits(bytes, recording_decoder())
}

fn recording_decoder() -> Decoder(Recording) {
  use version <- decode.field("dream_postgres_recording", decode.int)
  case version == format {
    True -> {
      use entries <- decode.field("entries", decode.list(entry_decoder()))
      decode.success(Recording(entries:))
    }
    False -> decode.failure(Recording(entries: []), "recording format 1")
  }
}

fn entry_decoder() -> Decoder(RecordedEntry) {
  use key <- decode.field("key", decode.string)
  use request <- decode.then(request_decoder())
  decode.success(RecordedEntry(key:, request:))
}

fn request_decoder() -> Decoder(RecordedRequest) {
  decode.one_of(decode.at(["statement"], statement_decoder()), [
    decode.at(["script"], script_decoder()),
    decode.at(["copy_from"], copy_from_decoder()),
    decode.at(["copy_to"], copy_to_decoder()),
  ])
}

fn statement_decoder() -> Decoder(RecordedRequest) {
  use sql <- decode.field("sql", decode.string)
  use parameters <- decode.field(
    "parameters",
    decode.optional({
      use types <- decode.field("types", decode.list(type_decoder()))
      use parameters <- decode.field(
        "cells",
        decode.list(written_parameter_decoder()),
      )
      decode.success(WrittenParameters(types:, parameters:))
    }),
  )
  use types <- decode.field("types", decode.list(type_decoder()))
  use outcome <- decode.field(
    "outcome",
    outcome_decoder({
      use description <- decode.field("description", description_decoder())
      use result <- decode.field("result", result_decoder())
      decode.success(StatementReply(description:, result:))
    }),
  )
  decode.success(RecordedStatement(sql:, parameters:, types:, outcome:))
}

fn script_decoder() -> Decoder(RecordedRequest) {
  use sql <- decode.field("sql", decode.string)
  use outcome <- decode.field(
    "outcome",
    outcome_decoder(decode.field(
      "results",
      decode.list(result_decoder()),
      decode.success,
    )),
  )
  decode.success(RecordedScript(sql:, outcome:))
}

fn copy_from_decoder() -> Decoder(RecordedRequest) {
  use sql <- decode.field("sql", decode.string)
  use rows <- decode.field(
    "rows",
    decode.optional({
      use types <- decode.field("types", decode.list(type_decoder()))
      use rows <- decode.field("rows", decode.list(row_decoder()))
      decode.success(WrittenRows(types:, rows:))
    }),
  )
  use types <- decode.field("types", decode.list(type_decoder()))
  use outcome <- decode.field(
    "outcome",
    outcome_decoder(decode.field("count", decode.int, decode.success)),
  )
  decode.success(RecordedCopyFrom(sql:, rows:, types:, outcome:))
}

fn copy_to_decoder() -> Decoder(RecordedRequest) {
  use sql <- decode.field("sql", decode.string)
  use types <- decode.field("types", decode.list(type_decoder()))
  use outcome <- decode.field(
    "outcome",
    outcome_decoder({
      use description <- decode.field("description", description_decoder())
      use rows <- decode.field("rows", decode.list(row_decoder()))
      use failure <- decode.field("failure", decode.optional(failure_decoder()))
      decode.success(
        RecordedStream(description:, rows:, ending: case failure {
          Some(recorded) -> Error(recorded)
          None -> Ok(Nil)
        }),
      )
    }),
  )
  decode.success(RecordedCopyTo(sql:, types:, outcome:))
}

fn outcome_decoder(
  answer_decoder: Decoder(answer),
) -> Decoder(Result(answer, RecordedFailure)) {
  decode.one_of(
    decode.field("answer", answer_decoder, fn(answer) {
      decode.success(Ok(answer))
    }),
    [
      decode.field("failure", failure_decoder(), fn(failure) {
        decode.success(Error(failure))
      }),
    ],
  )
}

fn failure_decoder() -> Decoder(RecordedFailure) {
  decode.one_of(
    decode.field("server_error", server_error_decoder(), fn(server_error) {
      decode.success(RecordedServerError(server_error:))
    }),
    [
      decode.field(
        "script_statement_failed",
        {
          use statements_run <- decode.field("statements_run", decode.int)
          use server_error <- decode.field(
            "server_error",
            server_error_decoder(),
          )
          decode.success(RecordedScriptFailure(statements_run:, server_error:))
        },
        decode.success,
      ),
    ],
  )
}

fn server_error_decoder() -> Decoder(ServerError) {
  let text = decode.optional(decode.string)
  let number = decode.optional(decode.int)
  use severity <- decode.field("severity", decode.string)
  use code <- decode.field("code", decode.string)
  use message <- decode.field("message", decode.string)
  use detail <- decode.field("detail", text)
  use hint <- decode.field("hint", text)
  use position <- decode.field("position", number)
  use internal_position <- decode.field("internal_position", number)
  use internal_query <- decode.field("internal_query", text)
  use context <- decode.field("context", text)
  use schema <- decode.field("schema", text)
  use table <- decode.field("table", text)
  use column <- decode.field("column", text)
  use data_type <- decode.field("data_type", text)
  use constraint <- decode.field("constraint", text)
  use file <- decode.field("file", text)
  use line <- decode.field("line", number)
  use routine <- decode.field("routine", text)
  use localized_severity <- decode.field("localized_severity", decode.string)
  use other_fields <- decode.field(
    "other_fields",
    decode.list({
      use code <- decode.field("code", decode.int)
      use value <- decode.field("value", decode.string)
      decode.success(#(code, value))
    }),
  )
  decode.success(
    error.server_error_from_report(cell.ServerReport(
      severity:,
      localized_severity:,
      code:,
      message:,
      detail:,
      hint:,
      position:,
      internal_position:,
      internal_query:,
      context:,
      schema:,
      table:,
      column:,
      data_type:,
      constraint:,
      file:,
      line:,
      routine:,
      other_fields:,
    )),
  )
}

fn description_decoder() -> Decoder(StatementDescription) {
  use parameter_type_ids <- decode.field(
    "parameter_type_ids",
    decode.list(decode.int),
  )
  use columns <- decode.field("columns", decode.list(column_decoder()))
  decode.success(StatementDescription(
    parameters: list.map(parameter_type_ids, ParameterDescription),
    columns:,
  ))
}

fn column_decoder() -> Decoder(ColumnDescription) {
  use name <- decode.field("name", decode.string)
  use type_id <- decode.field("type_id", decode.int)
  use type_modifier <- decode.field("type_modifier", decode.int)
  use table_id <- decode.field("table_id", decode.int)
  use column_number <- decode.field("column_number", decode.int)
  decode.success(ColumnDescription(
    name:,
    type_id:,
    type_modifier:,
    table_id:,
    column_number:,
  ))
}

fn result_decoder() -> Decoder(CommandResult) {
  use rows <- decode.field("rows", decode.list(row_decoder()))
  use tag <- decode.field("tag", decode.string)
  use count <- decode.field("count", decode.int)
  decode.success(CommandResult(rows:, tag:, count:))
}

fn row_decoder() -> Decoder(List(Cell)) {
  decode.list(cell_decoder())
}

fn written_parameter_decoder() -> Decoder(WrittenParameter) {
  decode.one_of(
    decode.at(["secret", "codec"], decode.string)
      |> decode.map(fn(codec) { SecretCell(codec:) }),
    [cell_decoder() |> decode.map(fn(cell) { WrittenCell(cell:) })],
  )
}

fn cell_decoder() -> Decoder(Cell) {
  decode.optional(
    decode.one_of(
      decode.field("binary", hex_decoder(), fn(bytes) {
        decode.success(Binary(bytes:))
      }),
      [
        decode.field("text", hex_decoder(), fn(bytes) {
          decode.success(Text(bytes:))
        }),
      ],
    ),
  )
  |> decode.map(option.unwrap(_, Null))
}

fn hex_decoder() -> Decoder(BitArray) {
  use text <- decode.then(decode.string)
  case bit_array.base16_decode(text) {
    Ok(bytes) -> decode.success(bytes)
    Error(Nil) -> decode.failure(<<>>, "hex bytes")
  }
}

fn type_decoder() -> Decoder(TypeDescription) {
  use id <- decode.field("id", decode.int)
  use schema <- decode.field("schema", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", kind_decoder())
  decode.success(TypeDescription(id:, schema:, name:, kind:))
}

fn kind_decoder() -> Decoder(TypeKind) {
  let type_id_kind = fn(name, field, make: fn(Int) -> TypeKind) {
    decode.field(
      name,
      decode.field(field, decode.int, decode.success),
      fn(type_id) { decode.success(make(type_id)) },
    )
  }
  decode.one_of(decode.field("base", decode.success(Base), decode.success), [
    decode.field("pseudo", decode.success(Pseudo), decode.success),
    decode.field(
      "enum",
      decode.field("labels", decode.list(decode.string), decode.success),
      fn(labels) { decode.success(Enum(labels:)) },
    ),
    decode.field(
      "composite",
      decode.field(
        "fields",
        decode.list({
          use name <- decode.field("name", decode.string)
          use type_id <- decode.field("type_id", decode.int)
          decode.success(#(name, type_id))
        }),
        decode.success,
      ),
      fn(fields) { decode.success(Composite(fields:)) },
    ),
    type_id_kind("domain", "base_type_id", fn(type_id) {
      Domain(base_type_id: type_id)
    }),
    type_id_kind("range", "element_type_id", fn(type_id) {
      Range(element_type_id: type_id)
    }),
    type_id_kind("multirange", "range_type_id", fn(type_id) {
      Multirange(range_type_id: type_id)
    }),
    type_id_kind("array", "element_type_id", fn(type_id) {
      Array(element_type_id: type_id)
    }),
  ])
}
