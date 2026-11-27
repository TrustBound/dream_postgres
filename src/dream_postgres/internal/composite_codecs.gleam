//// The codec of a composite type, in PostgreSQL's binary format
//// (`record_send` and `record_recv` in PostgreSQL's source): the number
//// of fields (32 bits), then for each field its type OID (32 bits), its
//// length (32 bits, -1 for NULL) and its bytes. Every field is in binary,
//// so each field's codec must use the binary format.
////
//// The codec reads a value with a row reader, the same as a row of a
//// query, and writes it as a list of fields in the type's order.

import dream_postgres/error
import dream_postgres/internal/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, ColumnDescription,
  Composite, Domain, Enum, Multirange, Null, Pseudo, Range, Text,
}
import dream_postgres/internal/codec_type.{
  type Codec, type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes,
}
import dream_postgres/internal/query.{type Value}
import dream_postgres/internal/row_reader.{
  type DescribedColumn, type Row, DescribedColumn,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

/// A codec of the composite type `type_name`.
pub fn composite(
  type_name type_name: String,
  read reader: Row(a),
  write to_fields: fn(a) -> List(Value),
  placeholder placeholder: a,
) -> Codec(a) {
  Codec(
    name: type_name,
    gleam_type: type_name,
    format: cell.BinaryFormat,
    accepts: fn(description, lookup) {
      accepts(type_name, reader, description, lookup)
    },
    encode: fn(value, description, lookup) {
      encode(to_fields(value), description, lookup)
      |> result.map_error(fn(reason) { type_name <> ": " <> reason })
    },
    decode: fn(value, description, lookup) {
      decode(reader, value, description, lookup)
      |> result.map_error(fn(issue) { name_issue(type_name, issue) })
    },
    placeholder:,
  )
}

// A part of a composite value is read like a column of a row, so the
// messages of the row readers name its fields as columns. The type name in
// front says which composite value they belong to.
fn name_issue(type_name: String, issue: DecodeIssue) -> DecodeIssue {
  case issue {
    Malformed(reason:) -> Malformed(type_name <> ": " <> reason)
    codec_type.NullValue | codec_type.OutOfRange(..) -> issue
  }
}

// The fields of a composite type, each with the description of its type.
fn described_fields(
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(DescribedColumn), String) {
  case description.kind {
    Composite(fields:) ->
      list.try_map(fields, fn(field) { describe_field(field, lookup) })
    Base
    | Enum(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Array(..)
    | Pseudo -> Error(description.name <> " is not a composite type")
  }
}

fn describe_field(
  field: #(String, Int),
  lookup: TypeLookup,
) -> Result(DescribedColumn, String) {
  let #(name, type_id) = field
  lookup(type_id)
  |> result.map(fn(type_description) {
    DescribedColumn(
      column: ColumnDescription(
        name:,
        type_id:,
        type_modifier: -1,
        table_id: 0,
        column_number: 0,
      ),
      type_description:,
    )
  })
  |> result.replace_error(
    "the type "
    <> int.to_string(type_id)
    <> " of the field "
    <> name
    <> " is not known",
  )
}

fn accepts(
  type_name: String,
  reader: Row(a),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Bool {
  description.name == type_name
  && {
    described_fields(description, lookup)
    |> result.replace_error(Nil)
    |> result.try(fn(fields) {
      row_reader.check(reader, fields, lookup) |> result.replace_error(Nil)
    })
    |> result.map(row_reader.reads_only_binary)
    |> result.unwrap(False)
  }
}

fn encode(
  fields: List(Value),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use described <- result.try(described_fields(description, lookup))
  let types = list.map(described, fn(field) { field.type_description })
  use written <- result.try(
    query.write_values(fields, types, lookup)
    |> result.map_error(error.reason_message),
  )
  use body <- result.try(
    list.zip(described, written.values)
    |> list.try_fold(<<>>, encode_field),
  )
  Ok(Binary(<<{ list.length(described) }:size(32), body:bits>>))
}

fn encode_field(
  body: BitArray,
  field: #(DescribedColumn, Cell),
) -> Result(BitArray, String) {
  let #(described, value) = field
  let type_id = described.column.type_id
  case value {
    Binary(bytes:) ->
      Ok(<<
        body:bits,
        type_id:size(32),
        { bit_array.byte_size(bytes) }:size(32),
        bytes:bits,
      >>)
    Null -> Ok(<<body:bits, type_id:size(32), -1:size(32)>>)
    Text(..) ->
      Error(
        "the field "
        <> described.column.name
        <> " has a codec in the text format, and a composite field needs one in the binary format",
      )
  }
}

fn decode(
  reader: Row(a),
  value: Cell,
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(a, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use described <- result.try(
    described_fields(description, lookup) |> result.map_error(Malformed),
  )
  use cells <- result.try(case bytes {
    <<count:size(32), rest:bits>> -> decode_fields(rest, count, [])
    _ -> Error(Malformed("the composite value is cut short"))
  })
  row_reader.check(reader, described, lookup)
  |> result.try(row_reader.read(_, cells, lookup))
  |> result.map_error(fn(reason) { Malformed(error.reason_message(reason)) })
}

fn decode_fields(
  bytes: BitArray,
  remaining: Int,
  cells: List(Cell),
) -> Result(List(Cell), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(cells))
    0, _ ->
      Error(Malformed("the composite value has bytes after its last field"))
    _, <<_type_id:size(32), -1:signed-size(32), rest:bits>> ->
      decode_fields(rest, remaining - 1, [Null, ..cells])
    _,
      <<
        _type_id:size(32),
        length:size(32),
        field:bytes-size(length),
        rest:bits,
      >>
    -> decode_fields(rest, remaining - 1, [Binary(field), ..cells])
    _, _ -> Error(Malformed("the fields of the composite value are cut short"))
  }
}
