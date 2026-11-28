//// The secrets of a config: text to replace in SQL, and columns whose
//// values to replace. A program declares them with `config.secret_text` and
//// `config.secret_column`. They apply to each copy of a request that leaves
//// the process: the recording of a recorder, the SQL of a `PostgresError`,
//// and the text of the trace span of each statement.
////
//// This module is internal to dream_postgres.

import dream_postgres/codec.{type Codec}
import dream_postgres/codec/codec_type.{type TypeLookup}
import dream_postgres/driver/cell.{
  type Cell, type ColumnDescription, type StatementDescription,
  type TypeDescription, Binary, Null, Text,
}
import dream_postgres/error.{type Reason, SecretColumnNotReplaced}
import gleam/dict
import gleam/list
import gleam/result
import gleam/string

/// The secrets of a config.
pub opaque type Secrets {
  Secrets(texts: List(SecretText), columns: List(SecretColumn))
}

type SecretText {
  SecretText(secret: String, replacement: String)
}

type SecretColumn {
  SecretColumn(
    name: String,
    codec_name: String,
    accepts: fn(TypeDescription, TypeLookup) -> Bool,
    write: fn(TypeDescription, TypeLookup) -> Result(Cell, String),
  )
}

/// No secrets.
pub fn secrets() -> Secrets {
  Secrets(texts: [], columns: [])
}

/// Replaces each `secret` in the SQL of each copy with `replacement`. The
/// texts are replaced in the order they were added.
pub fn text(
  declared: Secrets,
  secret: String,
  with replacement: String,
) -> Secrets {
  Secrets(
    ..declared,
    texts: list.append(declared.texts, [SecretText(secret:, replacement:)]),
  )
}

/// Replaces the value of each column called `name` in the rows that a
/// recorder saves with `replacement`, written with `codec`. A NULL stays
/// NULL. The rows of a `run_sql` call are not read, so they do not change.
pub fn column(
  declared: Secrets,
  name: String,
  codec: Codec(a),
  with replacement: a,
) -> Secrets {
  let secret_column =
    SecretColumn(
      name:,
      codec_name: codec_type.name(codec),
      accepts: fn(description, lookup) {
        codec_type.accepts(codec, description, lookup)
      },
      write: fn(description, lookup) {
        codec_type.encode(codec, replacement, description, lookup)
      },
    )
  Secrets(..declared, columns: list.append(declared.columns, [secret_column]))
}

/// The text with each secret text replaced.
@internal
pub fn replace_text(declared: Secrets, sql: String) -> String {
  list.fold(declared.texts, sql, fn(replaced, secret_text) {
    string.replace(
      replaced,
      each: secret_text.secret,
      with: secret_text.replacement,
    )
  })
}

/// The rows of an answer with the value of each secret column replaced.
/// `types` holds the type of each column of the description.
@internal
pub fn replace_columns(
  declared: Secrets,
  description: StatementDescription,
  types: List(TypeDescription),
  rows: List(List(Cell)),
) -> Result(List(List(Cell)), Reason) {
  let by_id =
    types
    |> list.map(fn(type_description) {
      #(type_description.id, type_description)
    })
    |> dict.from_list
  let lookup = dict.get(by_id, _)
  use replacements <- result.map(
    description.columns
    |> list.index_map(fn(answer_column, position) {
      column_replacements(declared, answer_column, position, lookup)
    })
    |> result.all,
  )
  let by_position = dict.from_list(list.flatten(replacements))
  list.map(rows, fn(row) {
    list.index_map(row, fn(row_cell, position) {
      replaced_cell(row_cell, dict.get(by_position, position))
    })
  })
}

// The replacement cell of each secret column that has the name of the
// column of the answer at `position`.
fn column_replacements(
  declared: Secrets,
  answer_column: ColumnDescription,
  position: Int,
  lookup: TypeLookup,
) -> Result(List(#(Int, Cell)), Reason) {
  declared.columns
  |> list.filter(fn(secret_column) { secret_column.name == answer_column.name })
  |> list.try_map(fn(secret_column) {
    lookup(answer_column.type_id)
    |> result.replace_error(SecretColumnNotReplaced(
      column: secret_column.name,
      reason: "the answer has no type for the column",
    ))
    |> result.try(replacement_cell(secret_column, _, lookup))
    |> result.map(fn(cell) { #(position, cell) })
  })
}

fn replacement_cell(
  secret_column: SecretColumn,
  type_description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, Reason) {
  case secret_column.accepts(type_description, lookup) {
    True ->
      secret_column.write(type_description, lookup)
      |> result.map_error(SecretColumnNotReplaced(
        column: secret_column.name,
        reason: _,
      ))
    False ->
      Error(SecretColumnNotReplaced(
        column: secret_column.name,
        reason: "the codec "
          <> secret_column.codec_name
          <> " does not take the type "
          <> type_description.name,
      ))
  }
}

// A NULL has no value to hide, so it stays NULL.
fn replaced_cell(row_cell: Cell, replacement: Result(Cell, Nil)) -> Cell {
  case row_cell, replacement {
    Binary(..), Ok(cell) | Text(..), Ok(cell) -> cell
    Null, Ok(_) -> Null
    Binary(..), Error(Nil) | Text(..), Error(Nil) | Null, Error(Nil) -> row_cell
  }
}
