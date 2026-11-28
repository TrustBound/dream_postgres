//// The codec of an array: PostgreSQL's binary array format
//// (`array_send` and `array_recv` in PostgreSQL's source) and the text form
//// `{a,"b c",NULL}`. `dream_postgres/codec.array` gives it to a program.
////
//// This module is internal to dream_postgres.

import dream_postgres/codec/codec_type.{
  type Codec, type DecodeIssue, type TypeLookup, Codec, Malformed, NullValue,
  accepts, decode, encode, utf8_bytes,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, BinaryFormat, Composite,
  Domain, Enum, Multirange, Null, Pseudo, Range, Text, TextFormat,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The codec of an array whose elements have the codec `element`.
pub fn array(element: Codec(a)) -> Codec(List(a)) {
  Codec(
    name: "array of " <> element.name,
    gleam_type: "List(" <> element.gleam_type <> ")",
    format: element.format,
    accepts: fn(description, lookup) {
      array_accepts(element, description, lookup)
    },
    encode: fn(values, description, lookup) {
      use element_type <- result.try(array_element_type(description, lookup))
      case element.format {
        BinaryFormat ->
          encode_binary_array(
            element,
            values,
            description,
            element_type,
            lookup,
          )
        TextFormat -> encode_text_array(element, values, element_type, lookup)
      }
    },
    decode: fn(value, description, lookup) {
      use element_type <- result.try(
        array_element_type(description, lookup)
        |> result.map_error(Malformed),
      )
      case value {
        Null -> Error(NullValue)
        Binary(bytes:) ->
          decode_binary_array(element, bytes, element_type, lookup)
        Text(bytes:) -> decode_text_array(element, bytes, element_type, lookup)
      }
    },
    placeholder: [],
  )
}

fn array_accepts(
  element: Codec(a),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Bool {
  case description.kind {
    Array(element_type_id:) ->
      element_type_accepted(element, element_type_id, lookup)
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Pseudo -> False
  }
}

fn element_type_accepted(
  element: Codec(a),
  element_type_id: Int,
  lookup: TypeLookup,
) -> Bool {
  case lookup(element_type_id) {
    Ok(element_type) -> accepts(element, element_type, lookup)
    Error(Nil) -> False
  }
}

fn array_element_type(
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(TypeDescription, String) {
  case description.kind {
    Array(element_type_id:) ->
      lookup(element_type_id)
      |> result.replace_error(
        "the element type " <> int.to_string(element_type_id) <> " is unknown",
      )
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Pseudo -> Error(description.name <> " is not an array type")
  }
}

// --- The array formats ---------------------------------------------------------

// The binary form of an array: the number of dimensions, a flag for NULL
// elements, the element type's OID, then for each dimension its size and
// lower bound, then each element as a length (-1 for NULL) and its bytes.
fn encode_binary_array(
  element: Codec(a),
  values: List(a),
  array_type: TypeDescription,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use cells <- result.try(
    list.try_map(values, fn(value) {
      encode(element, value, element_type, lookup)
    }),
  )
  let has_null = case list.contains(cells, Null) {
    True -> 1
    False -> 0
  }
  use lower_bound <- result.try(lower_bound(array_type, cells, has_null))
  let header = case cells {
    [] -> <<0:size(32), 0:size(32), element_type.id:size(32)>>
    _ -> <<
      1:size(32),
      has_null:size(32),
      element_type.id:size(32),
      { list.length(cells) }:size(32),
      lower_bound:size(32),
    >>
  }
  Ok(
    Binary(
      list.fold(cells, header, fn(bytes, cell) {
        bit_array.append(bytes, binary_element(cell))
      }),
    ),
  )
}

// An array counts from 1. The vector types int2vector and oidvector count
// from 0, and their receive functions take only one dimension, with no
// NULL element.
fn lower_bound(
  array_type: TypeDescription,
  cells: List(Cell),
  has_null: Int,
) -> Result(Int, String) {
  case is_base_vector(array_type), cells, has_null {
    False, _, _ -> Ok(1)
    True, [], _ ->
      Error(array_type.name <> " cannot be empty in the binary format")
    True, _, 1 -> Error(array_type.name <> " cannot hold a NULL element")
    True, _, _ -> Ok(0)
  }
}

fn is_base_vector(array_type: TypeDescription) -> Bool {
  array_type.schema == "pg_catalog"
  && { array_type.name == "int2vector" || array_type.name == "oidvector" }
}

fn binary_element(cell: Cell) -> BitArray {
  case cell {
    Null -> <<-1:size(32)>>
    Binary(bytes:) | Text(bytes:) -> <<
      { bit_array.byte_size(bytes) }:size(32),
      bytes:bits,
    >>
  }
}

fn decode_binary_array(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(a), DecodeIssue) {
  case bytes {
    <<0:size(32), _flags:size(32), _element_type_id:size(32)>> -> Ok([])
    <<
      1:size(32),
      _flags:size(32),
      _element_type_id:size(32),
      count:size(32),
      _lower_bound:signed-size(32),
      elements:bits,
    >> ->
      decode_binary_elements(element, elements, count, element_type, lookup, [])
    <<dimensions:size(32), _:bits>> ->
      Error(Malformed(
        "the array has "
        <> int.to_string(dimensions)
        <> " dimensions, and a List holds one",
      ))
    _ -> Error(Malformed("the array's header is cut short"))
  }
}

fn decode_binary_elements(
  element: Codec(a),
  bytes: BitArray,
  remaining: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
  decoded: List(a),
) -> Result(List(a), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(decoded))
    0, _ -> Error(Malformed("the array has bytes after its last element"))
    _, <<-1:signed-size(32), rest:bits>> ->
      decode_binary_element(
        element,
        Null,
        rest,
        remaining,
        element_type,
        lookup,
        decoded,
      )
    _, <<length:size(32), item:bytes-size(length), rest:bits>> ->
      decode_binary_element(
        element,
        Binary(item),
        rest,
        remaining,
        element_type,
        lookup,
        decoded,
      )
    _, _ -> Error(Malformed("the array's elements are cut short"))
  }
}

fn decode_binary_element(
  element: Codec(a),
  cell: Cell,
  rest: BitArray,
  remaining: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
  decoded: List(a),
) -> Result(List(a), DecodeIssue) {
  use value <- result.try(decode(element, cell, element_type, lookup))
  decode_binary_elements(element, rest, remaining - 1, element_type, lookup, [
    value,
    ..decoded
  ])
}

// The text form of an array: `{a,"b c",NULL}`. Each element is quoted, with
// each backslash and quote escaped, so no element needs other checks.
fn encode_text_array(
  element: Codec(a),
  values: List(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use cells <- result.try(
    list.try_map(values, fn(value) {
      encode(element, value, element_type, lookup)
    }),
  )
  let items = list.map(cells, text_array_item)
  Ok(
    Text(<<
      "{":utf8,
      { bit_array.concat(list.intersperse(items, <<",":utf8>>)) }:bits,
      "}":utf8,
    >>),
  )
}

fn text_array_item(cell: Cell) -> BitArray {
  case cell {
    Null -> <<"NULL":utf8>>
    Binary(bytes:) | Text(bytes:) -> <<
      "\"":utf8,
      { escape_bytes(bytes, <<>>) }:bits,
      "\"":utf8,
    >>
  }
}

fn escape_bytes(bytes: BitArray, escaped: BitArray) -> BitArray {
  case bytes {
    <<"\\":utf8, rest:bits>> ->
      escape_bytes(rest, <<escaped:bits, "\\\\":utf8>>)
    <<"\"":utf8, rest:bits>> ->
      escape_bytes(rest, <<escaped:bits, "\\\"":utf8>>)
    <<byte, rest:bits>> -> escape_bytes(rest, <<escaped:bits, byte>>)
    // The end of the bytes.
    _ -> escaped
  }
}

fn decode_text_array(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(a), DecodeIssue) {
  use text <- result.try(utf8_bytes(bytes))
  use items <- result.try(parse_text_array(text))
  list.try_map(items, fn(item) {
    let cell = case item {
      None -> Null
      Some(item_text) -> Text(bit_array.from_string(item_text))
    }
    decode(element, cell, element_type, lookup)
  })
}

// Reads a one-dimensional array literal into its elements: `None` for an
// unquoted NULL, and the text of every other element.
fn parse_text_array(text: String) -> Result(List(Option(String)), DecodeIssue) {
  case text {
    "{}" -> Ok([])
    "{" <> body -> parse_array_body(body)
    _ -> Error(Malformed("the array text does not start with a brace"))
  }
}

fn parse_array_body(body: String) -> Result(List(Option(String)), DecodeIssue) {
  case string.ends_with(body, "}") {
    True -> parse_items(string.to_graphemes(string.drop_end(body, 1)), [])
    False -> Error(Malformed("the array text has no closing brace"))
  }
}

fn parse_items(
  characters: List(String),
  items: List(Option(String)),
) -> Result(List(Option(String)), DecodeIssue) {
  case characters {
    ["{", ..] ->
      Error(Malformed(
        "the array has more than one dimension, and a List holds one",
      ))
    ["\"", ..rest] -> {
      use #(item, after) <- result.try(parse_quoted(rest, ""))
      finish_item(after, [Some(item), ..items])
    }
    _ -> {
      let #(item, after) = parse_unquoted(characters, "")
      finish_item(after, [unquoted_item(item), ..items])
    }
  }
}

fn unquoted_item(item: String) -> Option(String) {
  case string.trim(item) {
    "NULL" -> None
    other -> Some(other)
  }
}

fn finish_item(
  after: List(String),
  items: List(Option(String)),
) -> Result(List(Option(String)), DecodeIssue) {
  case after {
    [] -> Ok(list.reverse(items))
    [",", ..rest] -> parse_items(rest, items)
    _ ->
      Error(Malformed("the array text has a character after a quoted element"))
  }
}

fn parse_quoted(
  characters: List(String),
  item: String,
) -> Result(#(String, List(String)), DecodeIssue) {
  case characters {
    ["\\", escaped, ..rest] -> parse_quoted(rest, item <> escaped)
    ["\"", ..rest] -> Ok(#(item, rest))
    [character, ..rest] -> parse_quoted(rest, item <> character)
    [] -> Error(Malformed("the array text has a quote that does not close"))
  }
}

fn parse_unquoted(
  characters: List(String),
  item: String,
) -> #(String, List(String)) {
  case characters {
    [",", ..] | [] -> #(item, characters)
    ["\\", escaped, ..rest] -> parse_unquoted(rest, item <> escaped)
    [character, ..rest] -> parse_unquoted(rest, item <> character)
  }
}
