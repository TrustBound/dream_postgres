//// The codecs of ranges and multiranges of any element type.
////
//// A range of an element with a binary codec uses PostgreSQL's binary
//// format: a flags byte (1 empty, 2 lower bound inclusive, 4 upper bound
//// inclusive, 8 no lower bound, 16 no upper bound), then each bound that
//// exists as a length (32 bits) and the element's bytes. A multirange is
//// the number of ranges (32 bits), then each range as a length and its
//// bytes.
////
//// A range of an element with a text codec, such as a custom codec, uses
//// the text format: `empty`, or `[lower,upper)` with each bound quoted, and
//// a multirange is `{[1,3),[5,7)}`.

import dream_postgres/codecs/codec_type.{
  type Codec, type DecodeIssue, type TypeLookup, Codec, Malformed, NullValue,
  accepts, decode, encode, utf8_bytes,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, BinaryFormat, Composite,
  Domain, Enum, Multirange, Null, Pseudo, Range as RangeKind, Text, TextFormat,
}
import dream_postgres/range.{
  type Bound, type Range, EmptyRange, Exclusive, Inclusive, Range, Unbounded,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const empty_flag = 1

const lower_inclusive_flag = 2

const upper_inclusive_flag = 4

const no_lower_flag = 8

const no_upper_flag = 16

/// A codec of a range of the element codec's type.
pub fn range(element: Codec(a)) -> Codec(Range(a)) {
  Codec(
    name: "range of " <> element.name,
    gleam_type: "Range(" <> element.gleam_type <> ")",
    format: element.format,
    accepts: fn(description, lookup) {
      range_element_type(description, lookup)
      |> result.map(accepts(element, _, lookup))
      |> result.unwrap(False)
    },
    encode: fn(value, description, lookup) {
      use element_type <- result.try(range_element_type(description, lookup))
      case element.format {
        BinaryFormat ->
          encode_binary_range(element, value, element_type, lookup)
          |> result.map(Binary)
        TextFormat ->
          encode_text_range(element, value, element_type, lookup)
          |> result.map(Text)
      }
    },
    decode: fn(value, description, lookup) {
      use element_type <- result.try(
        range_element_type(description, lookup) |> result.map_error(Malformed),
      )
      case value {
        Null -> Error(NullValue)
        Binary(bytes:) ->
          decode_binary_range(element, bytes, element_type, lookup)
        Text(bytes:) -> {
          use text <- result.try(utf8_bytes(bytes))
          decode_text_range(element, text, element_type, lookup)
        }
      }
    },
    placeholder: EmptyRange,
  )
}

fn decode_binary_multirange(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(Range(a)), DecodeIssue) {
  case bytes {
    <<count:size(32), rest:bits>> ->
      decode_binary_ranges(element, rest, count, element_type, lookup, [])
    _ -> Error(Malformed("the multirange's header is cut short"))
  }
}

fn encode_binary_multirange(
  element: Codec(a),
  values: List(Range(a)),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use ranges <- result.try(
    list.try_map(values, encode_binary_range(element, _, element_type, lookup)),
  )
  let body =
    list.fold(ranges, <<>>, fn(bytes, one) {
      <<bytes:bits, { bit_array.byte_size(one) }:size(32), one:bits>>
    })
  Ok(Binary(<<{ list.length(ranges) }:size(32), body:bits>>))
}

fn encode_text_multirange(
  element: Codec(a),
  values: List(Range(a)),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use ranges <- result.try(
    list.try_map(values, encode_text_range(element, _, element_type, lookup)),
  )
  Ok(
    Text(<<
      "{":utf8,
      { bit_array.concat(list.intersperse(ranges, <<",":utf8>>)) }:bits,
      "}":utf8,
    >>),
  )
}

/// A codec of a multirange of the element codec's type, as a list of
/// ranges.
pub fn multirange(element: Codec(a)) -> Codec(List(Range(a))) {
  Codec(
    name: "multirange of " <> element.name,
    gleam_type: "List(Range(" <> element.gleam_type <> "))",
    format: element.format,
    accepts: fn(description, lookup) {
      multirange_element_type(description, lookup)
      |> result.map(accepts(element, _, lookup))
      |> result.unwrap(False)
    },
    encode: fn(values, description, lookup) {
      use element_type <- result.try(multirange_element_type(
        description,
        lookup,
      ))
      case element.format {
        BinaryFormat ->
          encode_binary_multirange(element, values, element_type, lookup)
        TextFormat ->
          encode_text_multirange(element, values, element_type, lookup)
      }
    },
    decode: fn(value, description, lookup) {
      use element_type <- result.try(
        multirange_element_type(description, lookup)
        |> result.map_error(Malformed),
      )
      case value {
        Null -> Error(NullValue)
        Binary(bytes:) ->
          decode_binary_multirange(element, bytes, element_type, lookup)
        Text(bytes:) -> {
          use text <- result.try(utf8_bytes(bytes))
          decode_text_multirange(element, text, element_type, lookup)
        }
      }
    },
    placeholder: [],
  )
}

// --- Types -------------------------------------------------------------------

fn range_element_type(
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(TypeDescription, String) {
  case description.kind {
    RangeKind(element_type_id:) -> find_type(element_type_id, lookup)
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | Multirange(..)
    | Array(..)
    | Pseudo -> Error(description.name <> " is not a range type")
  }
}

fn multirange_element_type(
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(TypeDescription, String) {
  case description.kind {
    Multirange(range_type_id:) -> {
      use range_type <- result.try(find_type(range_type_id, lookup))
      range_element_type(range_type, lookup)
    }
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | RangeKind(..)
    | Array(..)
    | Pseudo -> Error(description.name <> " is not a multirange type")
  }
}

fn find_type(id: Int, lookup: TypeLookup) -> Result(TypeDescription, String) {
  lookup(id)
  |> result.replace_error("the type " <> int.to_string(id) <> " is unknown")
}

// --- Binary ------------------------------------------------------------------

fn encode_binary_range(
  element: Codec(a),
  value: Range(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(BitArray, String) {
  case value {
    EmptyRange -> Ok(<<empty_flag>>)
    Range(lower:, upper:) -> {
      use #(lower_flags, lower_bytes) <- result.try(binary_bound(
        element,
        lower,
        element_type,
        lookup,
        lower_inclusive_flag,
        no_lower_flag,
      ))
      use #(upper_flags, upper_bytes) <- result.try(binary_bound(
        element,
        upper,
        element_type,
        lookup,
        upper_inclusive_flag,
        no_upper_flag,
      ))
      Ok(<<
        { int.bitwise_or(lower_flags, upper_flags) },
        lower_bytes:bits,
        upper_bytes:bits,
      >>)
    }
  }
}

fn binary_bound(
  element: Codec(a),
  bound: Bound(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
  inclusive_flag: Int,
  infinite_flag: Int,
) -> Result(#(Int, BitArray), String) {
  case bound {
    Unbounded -> Ok(#(infinite_flag, <<>>))
    Inclusive(value) -> {
      use bytes <- result.try(bound_bytes(element, value, element_type, lookup))
      Ok(#(inclusive_flag, bytes))
    }
    Exclusive(value) -> {
      use bytes <- result.try(bound_bytes(element, value, element_type, lookup))
      Ok(#(0, bytes))
    }
  }
}

fn bound_bytes(
  element: Codec(a),
  value: a,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(BitArray, String) {
  use found <- result.try(encode(element, value, element_type, lookup))
  case found {
    Binary(bytes:) | Text(bytes:) ->
      Ok(<<{ bit_array.byte_size(bytes) }:size(32), bytes:bits>>)
    Null -> Error("a range bound cannot be NULL")
  }
}

fn decode_binary_range(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  case bytes {
    <<flags, rest:bits>> ->
      decode_flagged_range(element, flags, rest, element_type, lookup)
    _ -> Error(Malformed("the range is empty bytes"))
  }
}

fn decode_flagged_range(
  element: Codec(a),
  flags: Int,
  rest: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  case int.bitwise_and(flags, empty_flag) != 0 {
    True -> Ok(EmptyRange)
    False -> read_range_bounds(element, flags, rest, element_type, lookup)
  }
}

fn read_range_bounds(
  element: Codec(a),
  flags: Int,
  rest: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  use #(lower, rest) <- result.try(read_bound(
    element,
    rest,
    flags,
    lower_inclusive_flag,
    no_lower_flag,
    element_type,
    lookup,
  ))
  use #(upper, rest) <- result.try(read_bound(
    element,
    rest,
    flags,
    upper_inclusive_flag,
    no_upper_flag,
    element_type,
    lookup,
  ))
  range_without_leftover(lower, upper, rest)
}

fn range_without_leftover(
  lower: Bound(a),
  upper: Bound(a),
  rest: BitArray,
) -> Result(Range(a), DecodeIssue) {
  case rest {
    <<>> -> Ok(Range(lower:, upper:))
    _ -> Error(Malformed("the range has bytes after its bounds"))
  }
}

fn bound_of(value: a, inclusive: Bool) -> Bound(a) {
  case inclusive {
    True -> Inclusive(value)
    False -> Exclusive(value)
  }
}

fn read_bound(
  element: Codec(a),
  bytes: BitArray,
  flags: Int,
  inclusive_flag: Int,
  infinite_flag: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(#(Bound(a), BitArray), DecodeIssue) {
  case int.bitwise_and(flags, infinite_flag) != 0, bytes {
    True, _ -> Ok(#(Unbounded, bytes))
    False, <<length:size(32), value:bytes-size(length), rest:bits>> -> {
      use found <- result.try(decode(
        element,
        Binary(value),
        element_type,
        lookup,
      ))
      Ok(#(bound_of(found, int.bitwise_and(flags, inclusive_flag) != 0), rest))
    }
    False, _ -> Error(Malformed("a range bound is cut short"))
  }
}

fn decode_binary_ranges(
  element: Codec(a),
  bytes: BitArray,
  remaining: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
  ranges: List(Range(a)),
) -> Result(List(Range(a)), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(ranges))
    0, _ -> Error(Malformed("the multirange has bytes after its last range"))
    _, <<length:size(32), one:bytes-size(length), rest:bits>> -> {
      use found <- result.try(decode_binary_range(
        element,
        one,
        element_type,
        lookup,
      ))
      decode_binary_ranges(element, rest, remaining - 1, element_type, lookup, [
        found,
        ..ranges
      ])
    }
    _, _ -> Error(Malformed("the multirange's ranges are cut short"))
  }
}

// --- Text ----------------------------------------------------------------------

fn encode_text_range(
  element: Codec(a),
  value: Range(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(BitArray, String) {
  case value {
    EmptyRange -> Ok(<<"empty":utf8>>)
    Range(lower:, upper:) -> {
      use #(open, lower_text) <- result.try(text_bound(
        element,
        lower,
        element_type,
        lookup,
        "[",
        "(",
      ))
      use #(close, upper_text) <- result.try(text_bound(
        element,
        upper,
        element_type,
        lookup,
        "]",
        ")",
      ))
      Ok(<<
        open:utf8,
        lower_text:bits,
        ",":utf8,
        upper_text:bits,
        close:utf8,
      >>)
    }
  }
}

fn text_bound(
  element: Codec(a),
  bound: Bound(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
  inclusive_mark: String,
  exclusive_mark: String,
) -> Result(#(String, BitArray), String) {
  case bound {
    Unbounded -> Ok(#(exclusive_mark, <<>>))
    Inclusive(value) -> {
      use text <- result.try(quoted_bound(element, value, element_type, lookup))
      Ok(#(inclusive_mark, text))
    }
    Exclusive(value) -> {
      use text <- result.try(quoted_bound(element, value, element_type, lookup))
      Ok(#(exclusive_mark, text))
    }
  }
}

// A bound is quoted, with each backslash and quote escaped.
fn quoted_bound(
  element: Codec(a),
  value: a,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(BitArray, String) {
  use found <- result.try(encode(element, value, element_type, lookup))
  case found {
    Binary(bytes:) | Text(bytes:) ->
      Ok(<<"\"":utf8, { escape_bytes(bytes, <<>>) }:bits, "\"":utf8>>)
    Null -> Error("a range bound cannot be NULL")
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

fn decode_text_range(
  element: Codec(a),
  text: String,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  case string.lowercase(string.trim(text)) {
    "empty" -> Ok(EmptyRange)
    _ -> {
      use #(found, rest) <- result.try(
        parse_range(string.to_graphemes(string.trim(text))),
      )
      text_range_without_leftover(element, found, rest, element_type, lookup)
    }
  }
}

fn text_range_without_leftover(
  element: Codec(a),
  found: ParsedRange,
  rest: List(String),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  case rest {
    [] -> text_range_value(element, found, element_type, lookup)
    _ -> Error(Malformed("the range text has characters after its end"))
  }
}

fn text_range_value(
  element: Codec(a),
  found: ParsedRange,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Range(a), DecodeIssue) {
  let ParsedRange(lower_inclusive:, lower:, upper:, upper_inclusive:) = found
  use lower <- result.try(text_bound_value(
    element,
    lower,
    lower_inclusive,
    element_type,
    lookup,
  ))
  use upper <- result.try(text_bound_value(
    element,
    upper,
    upper_inclusive,
    element_type,
    lookup,
  ))
  Ok(Range(lower:, upper:))
}

fn text_bound_value(
  element: Codec(a),
  text: Result(String, Nil),
  inclusive: Bool,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Bound(a), DecodeIssue) {
  case text {
    Error(Nil) -> Ok(Unbounded)
    Ok(value_text) -> {
      use value <- result.try(decode(
        element,
        Text(bit_array.from_string(value_text)),
        element_type,
        lookup,
      ))
      Ok(bound_of(value, inclusive))
    }
  }
}

// A range literal, read: each bound's text, or Error(Nil) for no bound.
type ParsedRange {
  ParsedRange(
    lower_inclusive: Bool,
    lower: Result(String, Nil),
    upper: Result(String, Nil),
    upper_inclusive: Bool,
  )
}

fn parse_range(
  characters: List(String),
) -> Result(#(ParsedRange, List(String)), DecodeIssue) {
  use #(lower_inclusive, rest) <- result.try(case characters {
    ["[", ..rest] -> Ok(#(True, rest))
    ["(", ..rest] -> Ok(#(False, rest))
    _ -> Error(Malformed("the range text does not start with [ or ("))
  })
  use #(lower, rest) <- result.try(parse_bound(rest))
  use rest <- result.try(case rest {
    [",", ..rest] -> Ok(rest)
    _ -> Error(Malformed("the range text has no comma between its bounds"))
  })
  use #(upper, rest) <- result.try(parse_bound(rest))
  use #(upper_inclusive, rest) <- result.try(case rest {
    ["]", ..rest] -> Ok(#(True, rest))
    [")", ..rest] -> Ok(#(False, rest))
    _ -> Error(Malformed("the range text does not end with ] or )"))
  })
  Ok(#(ParsedRange(lower_inclusive:, lower:, upper:, upper_inclusive:), rest))
}

// A bound: nothing (no bound), a quoted text, or an unquoted text up to the
// next comma or closing mark.
fn parse_bound(
  characters: List(String),
) -> Result(#(Result(String, Nil), List(String)), DecodeIssue) {
  case characters {
    ["\"", ..rest] -> {
      use #(text, rest) <- result.try(parse_quoted(rest, ""))
      Ok(#(Ok(text), rest))
    }
    ["," as next, ..rest] | ["]" as next, ..rest] | [")" as next, ..rest] ->
      Ok(#(Error(Nil), [next, ..rest]))
    _ -> {
      let #(text, rest) = parse_unquoted(characters, "")
      Ok(#(Ok(text), rest))
    }
  }
}

fn parse_quoted(
  characters: List(String),
  text: String,
) -> Result(#(String, List(String)), DecodeIssue) {
  case characters {
    ["\\", escaped, ..rest] -> parse_quoted(rest, text <> escaped)
    ["\"", "\"", ..rest] -> parse_quoted(rest, text <> "\"")
    ["\"", ..rest] -> Ok(#(text, rest))
    [character, ..rest] -> parse_quoted(rest, text <> character)
    [] -> Error(Malformed("the range text has a quote that does not close"))
  }
}

fn parse_unquoted(
  characters: List(String),
  text: String,
) -> #(String, List(String)) {
  case characters {
    [",", ..] | ["]", ..] | [")", ..] | [] -> #(text, characters)
    ["\\", escaped, ..rest] -> parse_unquoted(rest, text <> escaped)
    [character, ..rest] -> parse_unquoted(rest, text <> character)
  }
}

fn decode_text_multirange(
  element: Codec(a),
  text: String,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(Range(a)), DecodeIssue) {
  case string.to_graphemes(string.trim(text)) {
    ["{", "}"] -> Ok([])
    ["{", ..rest] -> parse_ranges(element, rest, element_type, lookup, [])
    _ -> Error(Malformed("the multirange text does not start with a brace"))
  }
}

fn parse_ranges(
  element: Codec(a),
  characters: List(String),
  element_type: TypeDescription,
  lookup: TypeLookup,
  ranges: List(Range(a)),
) -> Result(List(Range(a)), DecodeIssue) {
  use #(found, rest) <- result.try(parse_one_range(characters))
  use value <- result.try(case found {
    Error(Nil) -> Ok(EmptyRange)
    Ok(parsed) -> text_range_value(element, parsed, element_type, lookup)
  })
  case rest {
    [",", ..rest] ->
      parse_ranges(element, rest, element_type, lookup, [value, ..ranges])
    ["}"] -> Ok(list.reverse([value, ..ranges]))
    _ -> Error(Malformed("the multirange text has a character after a range"))
  }
}

// One range of a multirange: Error(Nil) for `empty`.
fn parse_one_range(
  characters: List(String),
) -> Result(#(Result(ParsedRange, Nil), List(String)), DecodeIssue) {
  case characters {
    ["e", "m", "p", "t", "y", ..rest] -> Ok(#(Error(Nil), rest))
    _ -> {
      use #(parsed, rest) <- result.try(parse_range(characters))
      Ok(#(Ok(parsed), rest))
    }
  }
}
