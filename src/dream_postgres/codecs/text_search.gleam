//// The Gleam values of PostgreSQL's full text search types: `tsvector`
//// and `tsquery`.
////
//// The codecs of `tsvector` and `tsquery`, in PostgreSQL's binary formats
//// (`tsvectorsend` and `tsquerysend` in PostgreSQL's source):
////
//// - `tsvector`: the number of lexemes (32 bits), then each lexeme as its
////   text ended by a 0 byte, the number of positions (16 bits), and each
////   position (16 bits): the weight in the top 2 bits (3 for A, 2 for B, 1
////   for C, 0 for D) and the position in the low 14 bits.
//// - `tsquery`: the number of items (32 bits), then the items in prefix
////   order, each operator before its right operand and then its left
////   operand. A word is 1, its weights (8 for A, 4 for B, 2 for C, 1 for
////   D, 0 for any), 1 for a prefix match or 0, then its text ended by a 0
////   byte. An operator is 2, then 1 for NOT, 2 for AND, 3 for OR or 4 for
////   a phrase, and for a phrase its distance (16 bits).

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  utf8_bytes,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}

/// The weight of a lexeme's position. `D` is the default.
pub type Weight {
  WeightA
  WeightB
  WeightC
  WeightD
}

/// A lexeme of a `tsvector`, with its positions (1 to 16383) and their
/// weights.
pub type Lexeme {
  Lexeme(word: String, positions: List(#(Int, Weight)))
}

/// A `tsvector`: its lexemes, in PostgreSQL's order.
pub type TsVector =
  List(Lexeme)

/// A `tsquery`.
pub type TsQuery {
  /// The query of no terms, which PostgreSQL makes from a text with no
  /// lexemes.
  EmptyQuery
  /// A word, with the weights it must have (none for any weight), and
  /// whether it matches as a prefix (`word:*`).
  Term(word: String, weights: List(Weight), prefix: Bool)
  Not(TsQuery)
  And(TsQuery, TsQuery)
  Or(TsQuery, TsQuery)
  /// `left <distance> right`: `right` follows `left` at `distance`.
  Phrase(distance: Int, left: TsQuery, right: TsQuery)
}

// --- Codecs ---------------------------------------------------------------------

// The limits PostgreSQL's receive functions check.
const max_word_bytes = 2047

const max_positions = 256

const max_position = 16_383

const max_phrase_distance = 16_384

// --- tsvector -------------------------------------------------------------------

/// `tsvector`, as a list of lexemes.
pub const text_search_vector =
  Codec(
    name: "text search vector",
    gleam_type: "TsVector",
    format: cell.BinaryFormat,
    accepts: accepts_text_search_vector,
    encode: encode_text_search_vector,
    decode: decode_text_search_vector,
    placeholder: [],
  )

fn accepts_text_search_vector(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["tsvector"])
}

fn encode_text_search_vector(
  value: TsVector,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  use #(body, _words) <- result.try(list.try_fold(
    value,
    #(<<>>, set.new()),
    encode_lexeme,
  ))
  Ok(Binary(<<{ list.length(value) }:size(32), body:bits>>))
}

fn encode_lexeme(
  encoded: #(BitArray, Set(String)),
  lexeme: Lexeme,
) -> Result(#(BitArray, Set(String)), String) {
  let #(body, words) = encoded
  use word <- result.try(word_bytes(lexeme.word))
  use Nil <- result.try(case set.contains(words, lexeme.word) {
    True -> Error("the lexeme " <> lexeme.word <> " is in the vector twice")
    False -> Ok(Nil)
  })
  use Nil <- result.try(case list.length(lexeme.positions) > max_positions {
    True ->
      Error(
        "the lexeme "
        <> lexeme.word
        <> " has more than "
        <> int.to_string(max_positions)
        <> " positions",
      )
    False -> Ok(Nil)
  })
  use #(positions, _last) <- result.try(
    list.try_fold(lexeme.positions, #(<<>>, 0), fn(packed, position) {
      encode_position(packed, position, lexeme.word)
    }),
  )
  Ok(#(
    <<
      body:bits,
      word:bits,
      0,
      { list.length(lexeme.positions) }:size(16),
      positions:bits,
    >>,
    set.insert(words, lexeme.word),
  ))
}

fn encode_position(
  packed: #(BitArray, Int),
  position: #(Int, Weight),
  word: String,
) -> Result(#(BitArray, Int), String) {
  let #(bytes, last) = packed
  let #(number, weight) = position
  case number < 1 || number > max_position, number <= last {
    True, _ ->
      Error(
        "the position "
        <> int.to_string(number)
        <> " of "
        <> word
        <> " is outside 1 to "
        <> int.to_string(max_position),
      )
    False, True ->
      Error("the positions of " <> word <> " must go up, each once")
    False, False ->
      Ok(#(
        <<bytes:bits, position_weight(weight):size(2), number:size(14)>>,
        number,
      ))
  }
}

fn position_weight(weight: Weight) -> Int {
  case weight {
    WeightA -> 3
    WeightB -> 2
    WeightC -> 1
    WeightD -> 0
  }
}

fn decode_text_search_vector(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(TsVector, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<count:size(32), rest:bits>> -> decode_lexemes(rest, count, [])
    _ -> Error(codec_type.wrong_size(description, bytes))
  }
}

fn read_positions(
  word: String,
  bytes: BitArray,
) -> Result(#(List(#(Int, Weight)), BitArray), DecodeIssue) {
  case bytes {
    <<count:size(16), rest:bits>> -> decode_positions(rest, count, [])
    _ -> Error(Malformed("the lexeme " <> word <> " is cut short"))
  }
}

fn decode_lexemes(
  bytes: BitArray,
  remaining: Int,
  lexemes: List(Lexeme),
) -> Result(TsVector, DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(lexemes))
    0, _ -> Error(Malformed("the vector has bytes after its last lexeme"))
    _, _ -> {
      use #(word, rest) <- result.try(read_word(bytes, <<>>))
      use #(positions, rest) <- result.try(read_positions(word, rest))
      decode_lexemes(rest, remaining - 1, [Lexeme(word, positions), ..lexemes])
    }
  }
}

fn decode_positions(
  bytes: BitArray,
  remaining: Int,
  positions: List(#(Int, Weight)),
) -> Result(#(List(#(Int, Weight)), BitArray), DecodeIssue) {
  case remaining, bytes {
    0, _ -> Ok(#(list.reverse(positions), bytes))
    _, <<weight:size(2), number:size(14), rest:bits>> ->
      decode_positions(rest, remaining - 1, [
        #(number, weight_of_position(weight)),
        ..positions
      ])
    _, _ -> Error(Malformed("the positions are cut short"))
  }
}

fn weight_of_position(bits: Int) -> Weight {
  case bits {
    3 -> WeightA
    2 -> WeightB
    1 -> WeightC
    _ -> WeightD
  }
}

// --- tsquery --------------------------------------------------------------------

/// `tsquery`, as a `TsQuery`.
pub const text_search_query =
  Codec(
    name: "text search query",
    gleam_type: "TsQuery",
    format: cell.BinaryFormat,
    accepts: accepts_text_search_query,
    encode: encode_text_search_query,
    decode: decode_text_search_query,
    placeholder: EmptyQuery,
  )

fn accepts_text_search_query(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["tsquery"])
}

fn encode_text_search_query(
  value: TsQuery,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case value {
    EmptyQuery -> Ok(Binary(<<0:size(32)>>))
    _ -> encode_query_items(value)
  }
}

fn encode_query_items(value: TsQuery) -> Result(Cell, String) {
  use #(items, count) <- result.try(encode_items(value))
  Ok(Binary(<<count:size(32), items:bits>>))
}

// The items of the query in prefix order, and how many there are.
fn encode_items(query: TsQuery) -> Result(#(BitArray, Int), String) {
  case query {
    EmptyQuery ->
      Error("an empty query can only be the whole query, not a part of one")
    Term(word:, weights:, prefix:) -> encode_term(word, weights, prefix)
    Not(operand) -> {
      use #(items, count) <- result.try(encode_items(operand))
      Ok(#(<<2, 1, items:bits>>, count + 1))
    }
    And(left, right) -> encode_operator(<<2, 2>>, left, right)
    Or(left, right) -> encode_operator(<<2, 3>>, left, right)
    Phrase(distance:, left:, right:) -> encode_phrase(distance, left, right)
  }
}

fn encode_term(
  word: String,
  weights: List(Weight),
  prefix: Bool,
) -> Result(#(BitArray, Int), String) {
  use bytes <- result.try(word_bytes(word))
  let weight_bits =
    list.fold(weights, 0, fn(bits, weight) {
      int.bitwise_or(bits, query_weight(weight))
    })
  Ok(#(<<1, weight_bits, prefix_flag(prefix), bytes:bits, 0>>, 1))
}

fn prefix_flag(prefix: Bool) -> Int {
  case prefix {
    True -> 1
    False -> 0
  }
}

fn encode_phrase(
  distance: Int,
  left: TsQuery,
  right: TsQuery,
) -> Result(#(BitArray, Int), String) {
  case distance < 0 || distance > max_phrase_distance {
    True ->
      Error(
        "the phrase distance "
        <> int.to_string(distance)
        <> " is outside 0 to "
        <> int.to_string(max_phrase_distance),
      )
    False -> encode_operator(<<2, 4, distance:size(16)>>, left, right)
  }
}

fn encode_operator(
  operator: BitArray,
  left: TsQuery,
  right: TsQuery,
) -> Result(#(BitArray, Int), String) {
  use #(right_items, right_count) <- result.try(encode_items(right))
  use #(left_items, left_count) <- result.try(encode_items(left))
  Ok(#(
    <<operator:bits, right_items:bits, left_items:bits>>,
    1 + right_count + left_count,
  ))
}

fn query_weight(weight: Weight) -> Int {
  case weight {
    WeightA -> 8
    WeightB -> 4
    WeightC -> 2
    WeightD -> 1
  }
}

fn decode_whole_query(items: BitArray) -> Result(TsQuery, DecodeIssue) {
  use #(query, rest) <- result.try(decode_item(items))
  case rest {
    <<>> -> Ok(query)
    _ -> Error(Malformed("the query has bytes after its last item"))
  }
}

fn decode_text_search_query(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(TsQuery, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<0:size(32)>> -> Ok(EmptyQuery)
    <<_count:size(32), items:bits>> -> decode_whole_query(items)
    _ -> Error(codec_type.wrong_size(description, bytes))
  }
}

fn decode_item(bytes: BitArray) -> Result(#(TsQuery, BitArray), DecodeIssue) {
  case bytes {
    <<1, weight_bits, prefix_flag, rest:bits>> -> {
      use #(word, rest) <- result.try(read_word(rest, <<>>))
      Ok(#(
        Term(
          word:,
          weights: query_weights(weight_bits),
          prefix: prefix_flag != 0,
        ),
        rest,
      ))
    }
    <<2, 1, rest:bits>> -> {
      use #(operand, rest) <- result.try(decode_item(rest))
      Ok(#(Not(operand), rest))
    }
    <<2, 2, rest:bits>> -> decode_operands(rest, And)
    <<2, 3, rest:bits>> -> decode_operands(rest, Or)
    <<2, 4, distance:size(16), rest:bits>> ->
      decode_operands(rest, fn(left, right) { Phrase(distance:, left:, right:) })
    _ -> Error(Malformed("the query has an item of an unknown kind"))
  }
}

fn decode_operands(
  bytes: BitArray,
  make: fn(TsQuery, TsQuery) -> TsQuery,
) -> Result(#(TsQuery, BitArray), DecodeIssue) {
  use #(right, rest) <- result.try(decode_item(bytes))
  use #(left, rest) <- result.try(decode_item(rest))
  Ok(#(make(left, right), rest))
}

fn query_weights(bits: Int) -> List(Weight) {
  [#(8, WeightA), #(4, WeightB), #(2, WeightC), #(1, WeightD)]
  |> list.filter_map(fn(flag) {
    case int.bitwise_and(bits, flag.0) {
      0 -> Error(Nil)
      _ -> Ok(flag.1)
    }
  })
}

// --- Words ------------------------------------------------------------------------

// The bytes of a word, which PostgreSQL ends with a 0 byte: so the word
// cannot hold one, cannot be empty, and has at most 2047 bytes.
fn word_bytes(word: String) -> Result(BitArray, String) {
  let bytes = bit_array.from_string(word)
  case bit_array.byte_size(bytes), has_zero_byte(bytes) {
    0, _ -> Error("a lexeme or a query word cannot be empty")
    size, _ if size > max_word_bytes ->
      Error(
        "the word "
        <> word
        <> " is longer than "
        <> int.to_string(max_word_bytes)
        <> " bytes",
      )
    _, True -> Error("a lexeme or a query word cannot hold a 0 byte")
    _, False -> Ok(bytes)
  }
}

fn has_zero_byte(bytes: BitArray) -> Bool {
  case bytes {
    <<0, _:bits>> -> True
    <<_, rest:bits>> -> has_zero_byte(rest)
    _ -> False
  }
}

// Reads the bytes up to the next 0 byte, as UTF-8 text.
fn read_word(
  bytes: BitArray,
  word: BitArray,
) -> Result(#(String, BitArray), DecodeIssue) {
  case bytes {
    <<0, rest:bits>> -> {
      use text <- result.try(utf8_bytes(word))
      Ok(#(text, rest))
    }
    <<byte, rest:bits>> -> read_word(rest, <<word:bits, byte>>)
    _ -> Error(Malformed("a word has no 0 byte at its end"))
  }
}
