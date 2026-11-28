//// The codec of a composite type, in PostgreSQL's binary format
//// (`record_send` and `record_recv` in PostgreSQL's source): the number
//// of fields (32 bits), then for each field its type OID (32 bits), its
//// length (32 bits, -1 for NULL) and its bytes. Every field is in binary,
//// so each field's codec must use the binary format.
////
//// The codec reads a value with a row reader, the same as a row of a
//// query, and writes it as a list of fields in the type's order.

import dream_postgres/codecs.{type Codec}
import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, ColumnDescription,
  Composite, Domain, Enum, Multirange, Null, Pseudo, Range, Text,
}
import dream_postgres/error
import dream_postgres/query/definition.{type Value, value_of}
import dream_postgres/row.{type Row}
import dream_postgres/row/reader.{type DescribedColumn, DescribedColumn}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

/// A codec of the composite type `type_name`.
/// A field of a composite value, with its codec, for the `write` function
/// of `composite`.
pub type Field =
  Value

/// A field of a composite value: its codec and its value. The fields go in
/// the order of the type's fields.
pub fn field(codec: Codec(a), value: a) -> Field {
  value_of(codec, value)
}

/// A codec of a composite type. It reads a value with a row reader, the
/// same as a row of a query, and writes it as a list of fields in the
/// type's order. Each field's codec must use the binary format, as every
/// codec of this module does except `custom`.
///
/// ### A codec of a composite type <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/address_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codecs.{type Codec, nullable, text}
/// import dream_postgres/codecs/composite.{type Field, composite, field}
/// import dream_postgres/row.{column, row}
/// import gleam/option.{type Option, None}
///
/// /// The values of the PostgreSQL composite type
/// /// `CREATE TYPE address AS (street text, city text)`.
/// pub type Address {
///   Address(street: String, city: Option(String))
/// }
///
/// /// Reads an address with a row reader, and writes it as its fields in the
/// /// order of the type.
/// pub fn address_codec() -> Codec(Address) {
///   composite(
///     "address",
///     read: {
///       use street <- column(text)
///       use city <- column(nullable(text))
///       row(Address(street:, city:))
///     },
///     write: address_fields,
///     placeholder: Address(street: "", city: None),
///   )
/// }
///
/// fn address_fields(address: Address) -> List(Field) {
///   [field(text, address.street), field(nullable(text), address.city)]
/// }
/// ```
pub fn composite(
  type_name type_name: String,
  read reader: Row(a),
  write to_fields: fn(a) -> List(Field),
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
      reader.check(reader, fields, lookup) |> result.replace_error(Nil)
    })
    |> result.map(reader.reads_only_binary)
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
    definition.write_values(fields, types, lookup)
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
  reader.check(reader, described, lookup)
  |> result.try(reader.read(_, cells, lookup))
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
