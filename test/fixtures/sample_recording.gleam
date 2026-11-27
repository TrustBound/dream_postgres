//// A recording with every form that a recording file holds: each kind of
//// request, each outcome, each cell, a secret parameter, each type kind
//// and each severity.

import dream_postgres/error.{
  type ServerError, DebugSeverity, ErrorSeverity, FatalSeverity, InfoSeverity,
  LogSeverity, NoticeSeverity, PanicSeverity, ServerError, UnlistedSeverity,
  WarningSeverity,
}
import dream_postgres/internal/cell.{
  Array, Base, Binary, ColumnDescription, CommandResult, Composite, Domain, Enum,
  Multirange, Null, ParameterDescription, Pseudo, Range, StatementDescription,
  Text, TypeDescription,
}
import dream_postgres/recording.{
  type Recording, RecordedCopyFrom, RecordedCopyTo, RecordedEntry,
  RecordedServerError, RecordedSql, RecordedSqlFailure, RecordedStatement,
  RecordedStream, Recording, SecretCell, StatementReply, WrittenCell,
  WrittenParameters, WrittenRows,
}
import dream_postgres/sql_state
import fixtures/server_error
import gleam/int
import gleam/list
import gleam/option.{None, Some}

/// The recording with every form.
///
/// ## Example
///
/// ```gleam
/// sample_recording.every_form()
/// |> recording.to_file_text
/// ```
pub fn every_form() -> Recording {
  let types = [
    TypeDescription(id: 23, schema: "pg_catalog", name: "int4", kind: Base),
    TypeDescription(
      id: 2249,
      schema: "pg_catalog",
      name: "record",
      kind: Pseudo,
    ),
    TypeDescription(
      id: 90_001,
      schema: "public",
      name: "mood",
      kind: Enum(labels: ["sad", "ok"]),
    ),
    TypeDescription(
      id: 90_002,
      schema: "public",
      name: "point_pair",
      kind: Composite(fields: [#("left", 23), #("right", 23)]),
    ),
    TypeDescription(
      id: 90_003,
      schema: "public",
      name: "positive",
      kind: Domain(base_type_id: 23),
    ),
    TypeDescription(
      id: 3904,
      schema: "pg_catalog",
      name: "int4range",
      kind: Range(element_type_id: 23),
    ),
    TypeDescription(
      id: 4451,
      schema: "pg_catalog",
      name: "int4multirange",
      kind: Multirange(range_type_id: 3904),
    ),
    TypeDescription(
      id: 1007,
      schema: "pg_catalog",
      name: "_int4",
      kind: Array(element_type_id: 23),
    ),
  ]
  let description =
    StatementDescription(
      parameters: [ParameterDescription(type_id: 23)],
      columns: [
        ColumnDescription(
          name: "id",
          type_id: 23,
          type_modifier: -1,
          table_id: 16_384,
          column_number: 1,
        ),
      ],
    )
  let cells = [Binary(bytes: <<0, 0, 0, 1>>), Text(bytes: <<"ok":utf8>>), Null]
  Recording(
    entries: list.index_map(
      list.flatten([
        [
          RecordedStatement(
            sql: "SELECT $1",
            parameters: Some(
              WrittenParameters(types: [], parameters: [
                SecretCell(codec: "text"),
                ..list.map(cells, WrittenCell)
              ]),
            ),
            types:,
            outcome: Ok(StatementReply(
              description:,
              result: CommandResult(rows: [cells], tag: "SELECT 1", count: 1),
            )),
          ),
          RecordedStatement(
            sql: "SELECT nope",
            parameters: None,
            types: [],
            outcome: Error(RecordedServerError(server_error: every_field())),
          ),
          RecordedSql(
            sql: "SELECT 1; SELECT 1 / 0",
            outcome: Error(RecordedSqlFailure(
              server_error: every_field(),
              statements_run: 1,
            )),
          ),
          RecordedSql(
            sql: "BEGIN",
            outcome: Ok([CommandResult(rows: [], tag: "BEGIN", count: 0)]),
          ),
          RecordedCopyFrom(
            sql: "COPY \"users\" (\"id\") FROM STDIN (FORMAT binary)",
            rows: Some(WrittenRows(types:, rows: [cells, cells])),
            types:,
            outcome: Ok(2),
          ),
          RecordedCopyFrom(
            sql: "COPY \"missing\" (\"id\") FROM STDIN (FORMAT binary)",
            rows: None,
            types: [],
            outcome: Error(RecordedServerError(server_error: every_field())),
          ),
          RecordedCopyTo(
            sql: "SELECT 1",
            types:,
            outcome: Ok(RecordedStream(
              description:,
              rows: [cells],
              ending: Ok(Nil),
            )),
          ),
          RecordedCopyTo(
            sql: "SELECT 1 / 0",
            types:,
            outcome: Ok(RecordedStream(
              description:,
              rows: [],
              ending: Error(RecordedServerError(server_error: every_field())),
            )),
          ),
          RecordedCopyTo(
            sql: "SELECT nope",
            types: [],
            outcome: Error(RecordedServerError(server_error: every_field())),
          ),
        ],
        list.map(
          [
            ErrorSeverity,
            FatalSeverity,
            PanicSeverity,
            WarningSeverity,
            NoticeSeverity,
            DebugSeverity,
            InfoSeverity,
            LogSeverity,
            UnlistedSeverity("LOUD"),
          ],
          fn(severity) {
            RecordedSql(
              sql: "SELECT 1",
              outcome: Error(RecordedServerError(
                server_error: ServerError(
                  ..server_error.with_sql_state(sql_state.UniqueViolation, None),
                  severity:,
                ),
              )),
            )
          },
        ),
      ]),
      fn(request, number) {
        RecordedEntry(key: "request " <> int.to_string(number + 1), request:)
      },
    ),
  )
}

// A server error with each optional field set.
fn every_field() -> ServerError {
  ServerError(
    ..server_error.with_sql_state(sql_state.DivisionByZero, None),
    detail: Some("detail"),
    hint: Some("hint"),
    position: Some(8),
    internal_position: Some(2),
    internal_query: Some("SELECT 1"),
    context: Some("context"),
    schema: Some("public"),
    table: Some("users"),
    column: Some("id"),
    data_type: Some("int4"),
    constraint: Some("users_pkey"),
    file: Some("int.c"),
    line: Some(841),
    routine: Some("int4div"),
    other_fields: [#(90, "extra")],
  )
}
