//// Queries: the SQL, an optional name, and the parameters with their
//// codecs. The module `dream_postgres` gives the public functions. Before
//// a query runs, its parameters are checked against the types that the
//// server gave in the prepared statement's description, then written.

import dream_postgres/error.{
  type Reason, EncodeFailed, ParameterCountMismatch, ParameterTypeMismatch,
}
import dream_postgres/internal/cell.{
  type Cell, type Format, type TypeDescription,
}
import dream_postgres/internal/codec_type.{type Codec, type TypeLookup}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A query: the SQL, the parameters, and an optional name for errors and
/// logs.
pub opaque type Query {
  Query(sql: String, name: Option(String), parameters: List(Value))
}

/// A value with its codec, for a parameter of a query or a field of a
/// composite value. The value itself is held only inside the functions
/// that check and write it, so `string.inspect` of a value shows its
/// codec and its sensitivity, never the value.
pub opaque type Value {
  Value(
    codec_name: String,
    format: Format,
    sensitivity: Sensitivity,
    accepts: fn(TypeDescription, TypeLookup) -> Bool,
    encode: fn(TypeDescription, TypeLookup) -> Result(Cell, String),
    /// What the value was written as, for the copy of a request that a
    /// recorder keeps: `None` until `written_as` or `written_secret` sets
    /// it.
    written: Option(Written),
  )
}

/// What a value was written as, with the type of its parameter or column.
pub type Written {
  /// The cell of a value that is not secret.
  WrittenCell(type_description: TypeDescription, cell: Cell)
  /// A secret value: the copy keeps no cell of it.
  WrittenSecret(type_description: TypeDescription)
}

/// Whether a recorder may save a value.
pub type Sensitivity {
  /// The recorder saves the written bytes of the value.
  NotSecret
  /// The recorder saves only that the value is secret, and its codec.
  Secret
}

/// A query of the SQL, with no parameters yet.
pub fn query(sql: String) -> Query {
  Query(sql:, name: None, parameters: [])
}

/// Adds the next parameter: the first call gives `$1`, the next `$2`.
pub fn parameter(query: Query, codec: Codec(a), value: a) -> Query {
  Query(..query, parameters: [value_of(codec, value), ..query.parameters])
}

/// Adds the next parameter as `parameter` does, and marks it secret: a
/// live run sends it as any other parameter, and a recorder never saves
/// its value.
pub fn secret_parameter(query: Query, codec: Codec(a), value: a) -> Query {
  Query(..query, parameters: [
    Value(..value_of(codec, value), sensitivity: Secret),
    ..query.parameters
  ])
}

/// Gives the query a name, which errors and logs show with the SQL.
pub fn named(query: Query, name: String) -> Query {
  Query(..query, name: Some(name))
}

/// The SQL of the query.
pub fn sql(query: Query) -> String {
  query.sql
}

/// The name of the query, if it has one.
pub fn name(query: Query) -> Option(String) {
  query.name
}

/// The parameters of the query, `$1` first.
pub fn values(query: Query) -> List(Value) {
  list.reverse(query.parameters)
}

/// The number of parameters of the query.
pub fn parameter_count(query: Query) -> Int {
  list.length(query.parameters)
}

/// A value with its codec.
pub fn value_of(codec: Codec(a), value: a) -> Value {
  Value(
    codec_name: codec_type.name(codec),
    format: codec_type.format(codec),
    sensitivity: NotSecret,
    accepts: fn(description, lookup) {
      codec_type.accepts(codec, description, lookup)
    },
    encode: fn(description, lookup) {
      codec_type.encode(codec, value, description, lookup)
    },
    written: None,
  )
}

/// The value with the cell it was written as, for the copy of a request
/// that a recorder keeps. A secret value keeps only the type.
pub fn written_as(
  value: Value,
  type_description: TypeDescription,
  cell: Cell,
) -> Value {
  case value.sensitivity {
    NotSecret ->
      Value(..value, written: Some(WrittenCell(type_description:, cell:)))
    Secret -> written_secret(value, type_description)
  }
}

/// The secret value with the type it was written as. The copy keeps no
/// cell of it.
pub fn written_secret(
  value: Value,
  type_description: TypeDescription,
) -> Value {
  Value(..value, written: Some(WrittenSecret(type_description:)))
}

/// What the value was written as, or `None` before it is fixed.
pub fn written(value: Value) -> Option(Written) {
  value.written
}

/// The value with its written cell changed. A secret value, and a value
/// that is not written yet, do not change.
pub fn change_cell(
  value: Value,
  change: fn(TypeDescription, Cell) -> Cell,
) -> Value {
  case value.written {
    Some(WrittenCell(type_description:, cell:)) ->
      written_as(value, type_description, change(type_description, cell))
    Some(WrittenSecret(..)) | None -> value
  }
}

/// What a watched value did while it was checked and written.
pub type WriteEvent {
  /// The value was checked against the type of its parameter or column.
  TypeChecked(type_description: TypeDescription)
  /// The codec looked up a part type, such as the element type of an
  /// array.
  TypeLookedUp(type_description: TypeDescription)
  /// The value was written to the cell.
  Written(cell: Cell)
  /// A secret value was written. The cell is not given, so a watcher
  /// cannot keep it.
  SecretWritten(codec_name: String)
}

/// The value, with a watcher that gets each check, type lookup and write
/// of it. The value checks and writes as before. The write of a secret
/// value gives `SecretWritten`, with no cell.
pub fn watch(value: Value, watcher: fn(WriteEvent) -> Nil) -> Value {
  let watched_lookup = fn(lookup: TypeLookup) {
    fn(type_id) {
      lookup(type_id)
      |> result.map(fn(type_description) {
        watcher(TypeLookedUp(type_description))
        type_description
      })
    }
  }
  Value(
    ..value,
    accepts: fn(description, lookup) {
      watcher(TypeChecked(description))
      value.accepts(description, watched_lookup(lookup))
    },
    encode: fn(description, lookup) {
      value.encode(description, watched_lookup(lookup))
      |> result.map(fn(cell) {
        watcher(write_event(value, cell))
        cell
      })
    },
  )
}

fn write_event(value: Value, cell: Cell) -> WriteEvent {
  case value.sensitivity {
    NotSecret -> Written(cell:)
    Secret -> SecretWritten(codec_name: value.codec_name)
  }
}

/// The name of the codec of a value.
pub fn codec_name(value: Value) -> String {
  value.codec_name
}

/// The parameters of a query, written for the Bind message.
pub type WrittenParameters {
  WrittenParameters(formats: List(Format), values: List(Cell))
}

/// Checks each parameter's codec against the type the server gave it, in
/// order, then writes each value.
pub fn write_parameters(
  query: Query,
  types: List(TypeDescription),
  lookup: TypeLookup,
) -> Result(WrittenParameters, Reason) {
  write_values(values(query), types, lookup)
}

/// Checks values against their types, in order: the count, and that each
/// codec takes the type of its parameter. Nothing is written, so the
/// values themselves do not matter, only their codecs.
pub fn check_values(
  values: List(Value),
  types: List(TypeDescription),
  lookup: TypeLookup,
) -> Result(Nil, Reason) {
  let expected = list.length(types)
  let got = list.length(values)
  use Nil <- result.try(case expected == got {
    True -> Ok(Nil)
    False -> Error(ParameterCountMismatch(expected:, got:))
  })
  list.try_each(numbered_values(values, types), check_type(_, lookup))
}

/// Checks and writes values against their types, in order. A composite
/// codec writes its fields with it too.
pub fn write_values(
  values: List(Value),
  types: List(TypeDescription),
  lookup: TypeLookup,
) -> Result(WrittenParameters, Reason) {
  use Nil <- result.try(check_values(values, types, lookup))
  use cells <- result.try(
    list.try_map(numbered_values(values, types), write_value(_, lookup)),
  )
  let formats =
    list.zip(values, cells)
    |> list.map(fn(pair) { cell_format(pair.1, { pair.0 }.format) })
  Ok(WrittenParameters(formats:, values: cells))
}

// Each value with its type and its position, which counts from 1 like `$1`.
fn numbered_values(
  values: List(Value),
  types: List(TypeDescription),
) -> List(#(Int, Value, TypeDescription)) {
  list.zip(values, types)
  |> list.index_map(fn(pair, index) { #(index + 1, pair.0, pair.1) })
}

// The format of a written value is the format of its bytes. A NULL has no
// bytes, and takes the codec's format.
fn cell_format(value: Cell, codec_format: Format) -> Format {
  case value {
    cell.Binary(..) -> cell.BinaryFormat
    cell.Text(..) -> cell.TextFormat
    cell.Null -> codec_format
  }
}

fn check_type(
  numbered: #(Int, Value, TypeDescription),
  lookup: TypeLookup,
) -> Result(Nil, Reason) {
  let #(position, value, description) = numbered
  case value.accepts(description, lookup) {
    True -> Ok(Nil)
    False ->
      Error(ParameterTypeMismatch(
        position:,
        database_type: description.name,
        codec: value.codec_name,
      ))
  }
}

fn write_value(
  numbered: #(Int, Value, TypeDescription),
  lookup: TypeLookup,
) -> Result(Cell, Reason) {
  let #(position, value, description) = numbered
  value.encode(description, lookup)
  |> result.map_error(fn(reason) { EncodeFailed(position:, reason:) })
}
