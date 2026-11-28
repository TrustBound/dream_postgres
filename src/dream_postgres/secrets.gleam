//// The secrets of a config: text to replace in SQL, and columns whose
//// values to replace. Declare them once on the config with
//// `config.secrets`. They apply to each copy of a request that
//// leaves the process: the recording of a recorder, the SQL of a
//// `PostgresError`, and the text of the trace span of each statement. The
//// database and the app always get the real values.
////
//// ### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_postgres/codec.{text}
//// import dream_postgres/config.{type Config, intercept, secrets}
//// import dream_postgres/secrets
//// import snippets/request_tagging.{tag_with_app_name}
////
//// /// The config of the app, shared by the app and its tests. `server` holds
//// /// the settings of the server of each run.
//// pub fn app_config(server: Config) -> Config {
////   server
////   |> intercept(tag_with_app_name)
////   |> secrets(
////     secrets.new()
////     |> secrets.text("sk_live_", with: "sk_test_")
////     |> secrets.column("token", text, with: "token-redacted"),
////   )
//// }
//// ```

import dream_postgres/codec.{type Codec}
import dream_postgres/codecs/codec_type.{type TypeLookup}
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
///
/// ### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{text}
/// import dream_postgres/config.{type Config, intercept, secrets}
/// import dream_postgres/secrets
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The config of the app, shared by the app and its tests. `server` holds
/// /// the settings of the server of each run.
/// pub fn app_config(server: Config) -> Config {
///   server
///   |> intercept(tag_with_app_name)
///   |> secrets(
///     secrets.new()
///     |> secrets.text("sk_live_", with: "sk_test_")
///     |> secrets.column("token", text, with: "token-redacted"),
///   )
/// }
/// ```
pub fn new() -> Secrets {
  Secrets(texts: [], columns: [])
}

/// Replaces each `secret` in the SQL of each copy with `replacement`. The
/// texts are replaced in the order they were added.
///
/// ### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{text}
/// import dream_postgres/config.{type Config, intercept, secrets}
/// import dream_postgres/secrets
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The config of the app, shared by the app and its tests. `server` holds
/// /// the settings of the server of each run.
/// pub fn app_config(server: Config) -> Config {
///   server
///   |> intercept(tag_with_app_name)
///   |> secrets(
///     secrets.new()
///     |> secrets.text("sk_live_", with: "sk_test_")
///     |> secrets.column("token", text, with: "token-redacted"),
///   )
/// }
/// ```
pub fn text(
  secrets: Secrets,
  secret: String,
  with replacement: String,
) -> Secrets {
  Secrets(
    ..secrets,
    texts: list.append(secrets.texts, [SecretText(secret:, replacement:)]),
  )
}

/// Replaces the value of each column called `name` in the rows that a
/// recorder saves with `replacement`, written with `codec`. A NULL stays
/// NULL. The rows of a `run_sql` call are not read, so they do not change.
///
/// ### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{text}
/// import dream_postgres/config.{type Config, intercept, secrets}
/// import dream_postgres/secrets
/// import snippets/request_tagging.{tag_with_app_name}
///
/// /// The config of the app, shared by the app and its tests. `server` holds
/// /// the settings of the server of each run.
/// pub fn app_config(server: Config) -> Config {
///   server
///   |> intercept(tag_with_app_name)
///   |> secrets(
///     secrets.new()
///     |> secrets.text("sk_live_", with: "sk_test_")
///     |> secrets.column("token", text, with: "token-redacted"),
///   )
/// }
/// ```
pub fn column(
  secrets: Secrets,
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
  Secrets(..secrets, columns: list.append(secrets.columns, [secret_column]))
}

/// The text with each secret text replaced.
@internal
pub fn replace_text(secrets: Secrets, text: String) -> String {
  list.fold(secrets.texts, text, fn(replaced, secret_text) {
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
  secrets: Secrets,
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
      column_replacements(secrets, answer_column, position, lookup)
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
  secrets: Secrets,
  answer_column: ColumnDescription,
  position: Int,
  lookup: TypeLookup,
) -> Result(List(#(Int, Cell)), Reason) {
  secrets.columns
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
