//// The `numeric` codec, in PostgreSQL's binary format. The Gleam value is
//// the exact text of the number, so no digit is lost and no float rounding
//// happens.
////
//// The binary format is four 16-bit fields, then the digits:
////
//// - the number of digits;
//// - the weight, signed: the power of 10000 of the first digit;
//// - the sign: 0x0000 positive, 0x4000 negative, 0xC000 NaN, 0xD000
////   Infinity, 0xF000 -Infinity;
//// - the display scale: the number of decimal digits after the point;
//// - the digits, each from 0 to 9999, in base 10000.
////
//// Reading gives the text that PostgreSQL's `numeric_out` gives. Writing
//// takes the texts that PostgreSQL's `numeric_in` takes, and gives the
//// bytes that its `numeric_send` gives for that value.

import dream_postgres/internal/cell.{type Cell, type TypeDescription, Binary}
import dream_postgres/internal/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// `numeric`, as its exact text, in the binary format.
pub const numeric =
  Codec(
    name: "numeric",
    gleam_type: "String",
    format: cell.BinaryFormat,
    accepts: accepts_numeric,
    encode: encode_numeric,
    decode: decode_numeric,
    placeholder: "0",
  )

// The largest display scale, NUMERIC_DSCALE_MAX in PostgreSQL.
const largest_display_scale = 0x3FFF

// The weight is a signed 16-bit field.
const largest_weight = 32_767

const smallest_weight = -32_768

// numeric_in refuses an exponent above PG_INT32_MAX / 2.
const largest_exponent = 1_073_741_823

const positive_code = 0x0000

const negative_code = 0x4000

const not_a_number_code = 0xC000

const positive_infinity_code = 0xD000

const negative_infinity_code = 0xF000

type Sign {
  Positive
  Negative
  NotANumber
  PositiveInfinity
  NegativeInfinity
}

// Why a text is not written.
type Refusal {
  NotNumericText
  OutsideNumericRange
}

// The decimal digits of a number, before its exponent.
type DecimalDigits {
  DecimalDigits(
    digits: BitArray,
    whole_count: Int,
    fraction_count: Int,
    has_point: Bool,
  )
}

fn accepts_numeric(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["numeric"])
}

// --- Reading --------------------------------------------------------------------

fn decode_numeric(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(String, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<
      digit_count:16,
      weight:16-signed,
      sign_code:16,
      display_scale:16,
      digit_bytes:bytes,
    >> ->
      decode_parts(digit_count, weight, sign_code, display_scale, digit_bytes)
    _ -> Error(Malformed("a numeric value is cut short"))
  }
}

fn decode_parts(
  digit_count: Int,
  weight: Int,
  sign_code: Int,
  display_scale: Int,
  digit_bytes: BitArray,
) -> Result(String, DecodeIssue) {
  use sign <- result.try(sign_from_code(sign_code))
  use Nil <- result.try(check_display_scale(display_scale))
  use digits <- result.try(read_digits(digit_bytes, digit_count, []))
  Ok(numeric_text(sign, weight, display_scale, digits))
}

fn sign_from_code(sign_code: Int) -> Result(Sign, DecodeIssue) {
  case sign_code {
    0x0000 -> Ok(Positive)
    0x4000 -> Ok(Negative)
    0xC000 -> Ok(NotANumber)
    0xD000 -> Ok(PositiveInfinity)
    0xF000 -> Ok(NegativeInfinity)
    _ ->
      Error(Malformed(
        "0x" <> int.to_base16(sign_code) <> " is not a numeric sign",
      ))
  }
}

fn check_display_scale(display_scale: Int) -> Result(Nil, DecodeIssue) {
  case display_scale > largest_display_scale {
    True ->
      Error(Malformed(
        "the display scale " <> int.to_string(display_scale) <> " is too large",
      ))
    False -> Ok(Nil)
  }
}

fn read_digits(
  bytes: BitArray,
  remaining: Int,
  reversed_digits: List(Int),
) -> Result(List(Int), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(reversed_digits))
    0, _ -> Error(Malformed("a numeric value has bytes after its digits"))
    _, <<digit:16, rest:bytes>> if digit < 10_000 ->
      read_digits(rest, remaining - 1, [digit, ..reversed_digits])
    _, <<digit:16, _:bytes>> ->
      Error(Malformed(
        "the numeric digit " <> int.to_string(digit) <> " is not below 10000",
      ))
    _, _ -> Error(Malformed("a numeric value is cut short"))
  }
}

fn numeric_text(
  sign: Sign,
  weight: Int,
  display_scale: Int,
  digits: List(Int),
) -> String {
  case sign {
    NotANumber -> "NaN"
    PositiveInfinity -> "Infinity"
    NegativeInfinity -> "-Infinity"
    Positive -> finite_text(False, weight, display_scale, digits)
    Negative -> finite_text(True, weight, display_scale, digits)
  }
}

// Writes the digits as decimal text, with exactly `display_scale` digits
// after the point. Digits past the display scale are cut off, as
// numeric_recv does.
fn finite_text(
  negative: Bool,
  weight: Int,
  display_scale: Int,
  digits: List(Int),
) -> String {
  let decimal =
    digits
    |> list.map(fn(digit) { string.pad_start(int.to_string(digit), 4, "0") })
    |> string.concat
  let point = 4 * { weight + 1 }
  let whole_digits =
    string.slice(decimal, 0, int.max(point, 0))
    <> string.repeat("0", point - string.length(decimal))
  let whole = without_leading_zeros(whole_digits)
  let fraction_digits =
    string.repeat("0", int.min(-point, display_scale))
    <> string.drop_start(decimal, int.max(point, 0))
    <> string.repeat("0", display_scale)
  let fraction = string.slice(fraction_digits, 0, display_scale)
  sign_text(negative && !is_zero(whole <> fraction))
  <> whole
  <> fraction_text(fraction)
}

fn without_leading_zeros(digits: String) -> String {
  case digits {
    "0" <> rest -> without_leading_zeros(rest)
    "" -> "0"
    _ -> digits
  }
}

fn is_zero(digits: String) -> Bool {
  string.replace(digits, "0", "") == ""
}

fn sign_text(negative: Bool) -> String {
  case negative {
    True -> "-"
    False -> ""
  }
}

fn fraction_text(fraction: String) -> String {
  case fraction {
    "" -> ""
    _ -> "." <> fraction
  }
}

// --- Writing --------------------------------------------------------------------

fn encode_numeric(
  value: String,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case parse_numeric_text(bit_array.from_string(value)) {
    Ok(bytes) -> Ok(Binary(bytes))
    Error(NotNumericText) ->
      Error(string.inspect(value) <> " is not a numeric value")
    Error(OutsideNumericRange) ->
      Error(string.inspect(value) <> " is out of range for numeric")
  }
}

// Follows numeric_in: spaces, a sign, then a number or a special value,
// then spaces.
fn parse_numeric_text(bytes: BitArray) -> Result(BitArray, Refusal) {
  let text = skip_spaces(bytes)
  let #(negative, unsigned) = take_sign(text)
  case unsigned {
    <<character, _:bytes>> if character >= 48 && character <= 57 ->
      parse_number(negative, unsigned)
    <<".":utf8, _:bytes>> -> parse_number(negative, unsigned)
    _ -> parse_special(text, negative, unsigned)
  }
}

// The C isspace characters: space, tab, line feed, vertical tab, form feed
// and carriage return.
fn skip_spaces(bytes: BitArray) -> BitArray {
  case bytes {
    <<character, rest:bytes>> if character == 32 -> skip_spaces(rest)
    <<character, rest:bytes>> if character >= 9 && character <= 13 ->
      skip_spaces(rest)
    _ -> bytes
  }
}

fn take_sign(bytes: BitArray) -> #(Bool, BitArray) {
  case bytes {
    <<"+":utf8, rest:bytes>> -> #(False, rest)
    <<"-":utf8, rest:bytes>> -> #(True, rest)
    _ -> #(False, bytes)
  }
}

fn expect_only_spaces(bytes: BitArray) -> Result(Nil, Refusal) {
  case skip_spaces(bytes) {
    <<>> -> Ok(Nil)
    _ -> Error(NotNumericText)
  }
}

fn require_digit(bytes: BitArray) -> Result(Nil, Refusal) {
  case bytes {
    <<character, _:bytes>> if character >= 48 && character <= 57 -> Ok(Nil)
    _ -> Error(NotNumericText)
  }
}

// NaN takes no sign. The infinities take one.
fn parse_special(
  text: BitArray,
  negative: Bool,
  unsigned: BitArray,
) -> Result(BitArray, Refusal) {
  use #(sign_code, rest) <- result.try(special_value(text, negative, unsigned))
  use Nil <- result.try(expect_only_spaces(rest))
  Ok(<<0:16, 0:16, sign_code:16, 0:16>>)
}

fn special_value(
  text: BitArray,
  negative: Bool,
  unsigned: BitArray,
) -> Result(#(Int, BitArray), Refusal) {
  let infinity_code = case negative {
    True -> negative_infinity_code
    False -> positive_infinity_code
  }
  case
    strip_word(text, <<"nan":utf8>>),
    strip_word(unsigned, <<"infinity":utf8>>),
    strip_word(unsigned, <<"inf":utf8>>)
  {
    Ok(rest), _, _ -> Ok(#(not_a_number_code, rest))
    _, Ok(rest), _ -> Ok(#(infinity_code, rest))
    _, _, Ok(rest) -> Ok(#(infinity_code, rest))
    _, _, _ -> Error(NotNumericText)
  }
}

// Removes a lowercase ASCII word from the front of the bytes, in any case.
fn strip_word(bytes: BitArray, word: BitArray) -> Result(BitArray, Nil) {
  case word, bytes {
    <<>>, _ -> Ok(bytes)
    <<expected, word_rest:bytes>>, <<actual, rest:bytes>>
      if expected == actual || expected == actual + 32
    -> strip_word(rest, word_rest)
    _, _ -> Error(Nil)
  }
}

fn parse_number(
  negative: Bool,
  unsigned: BitArray,
) -> Result(BitArray, Refusal) {
  case unsigned {
    <<"0x":utf8, rest:bytes>> | <<"0X":utf8, rest:bytes>> ->
      parse_integer(negative, rest, 16)
    <<"0o":utf8, rest:bytes>> | <<"0O":utf8, rest:bytes>> ->
      parse_integer(negative, rest, 8)
    <<"0b":utf8, rest:bytes>> | <<"0B":utf8, rest:bytes>> ->
      parse_integer(negative, rest, 2)
    _ -> parse_decimal(negative, unsigned)
  }
}

// --- Hexadecimal, octal and binary integers -----------------------------------

fn parse_integer(
  negative: Bool,
  bytes: BitArray,
  base: Int,
) -> Result(BitArray, Refusal) {
  use #(digits, rest) <- result.try(read_based_digits(bytes, base, <<>>))
  use digit_text <- result.try(
    bit_array.to_string(digits) |> result.replace_error(NotNumericText),
  )
  use value <- result.try(
    int.base_parse(digit_text, base) |> result.replace_error(NotNumericText),
  )
  let decimal = int.to_string(value)
  use number <- result.try(finite_bytes(
    negative,
    bit_array.from_string(decimal),
    string.length(decimal) - 1,
    0,
  ))
  use Nil <- result.try(expect_only_spaces(rest))
  Ok(number)
}

// An underscore may come before any digit, the first one too.
fn read_based_digits(
  bytes: BitArray,
  base: Int,
  digits: BitArray,
) -> Result(#(BitArray, BitArray), Refusal) {
  case bytes, based_digit(bytes, base) {
    <<character, rest:bytes>>, True ->
      read_based_digits(rest, base, <<digits:bits, character>>)
    <<"_":utf8, rest:bytes>>, _ -> require_based_digit(rest, base, digits)
    _, _ -> Ok(#(digits, bytes))
  }
}

fn require_based_digit(
  bytes: BitArray,
  base: Int,
  digits: BitArray,
) -> Result(#(BitArray, BitArray), Refusal) {
  case based_digit(bytes, base) {
    True -> read_based_digits(bytes, base, digits)
    False -> Error(NotNumericText)
  }
}

fn based_digit(bytes: BitArray, base: Int) -> Bool {
  case bytes {
    <<character, _:bytes>> -> digit_value(character) < base
    _ -> False
  }
}

fn digit_value(character: Int) -> Int {
  case character {
    _ if character >= 48 && character <= 57 -> character - 48
    _ if character >= 97 && character <= 102 -> character - 87
    _ if character >= 65 && character <= 70 -> character - 55
    _ -> 16
  }
}

// --- Decimal numbers ------------------------------------------------------------

fn parse_decimal(negative: Bool, bytes: BitArray) -> Result(BitArray, Refusal) {
  let #(start, after_point) = case bytes {
    <<".":utf8, rest:bytes>> -> #(DecimalDigits(<<>>, 0, 0, True), rest)
    _ -> #(DecimalDigits(<<>>, 0, 0, False), bytes)
  }
  use Nil <- result.try(require_digit(after_point))
  use #(mantissa, rest) <- result.try(read_decimal_digits(after_point, start))
  use #(exponent, rest) <- result.try(read_exponent(rest))
  use Nil <- result.try(expect_only_spaces(rest))
  finite_bytes(
    negative,
    mantissa.digits,
    mantissa.whole_count - 1 + exponent,
    int.max(mantissa.fraction_count - exponent, 0),
  )
}

// A point may not be followed by an underscore, and an underscore must be
// followed by a digit.
fn read_decimal_digits(
  bytes: BitArray,
  state: DecimalDigits,
) -> Result(#(DecimalDigits, BitArray), Refusal) {
  case bytes {
    <<character, rest:bytes>> if character >= 48 && character <= 57 ->
      read_decimal_digits(rest, add_digit(state, character))
    <<".":utf8, _:bytes>> if state.has_point -> Error(NotNumericText)
    <<".":utf8, "_":utf8, _:bytes>> -> Error(NotNumericText)
    <<".":utf8, rest:bytes>> ->
      read_decimal_digits(rest, DecimalDigits(..state, has_point: True))
    <<"_":utf8, rest:bytes>> -> {
      use Nil <- result.try(require_digit(rest))
      read_decimal_digits(rest, state)
    }
    _ -> Ok(#(state, bytes))
  }
}

fn add_digit(state: DecimalDigits, character: Int) -> DecimalDigits {
  let digits = <<state.digits:bits, character>>
  case state.has_point {
    True ->
      DecimalDigits(..state, digits:, fraction_count: state.fraction_count + 1)
    False -> DecimalDigits(..state, digits:, whole_count: state.whole_count + 1)
  }
}

fn read_exponent(bytes: BitArray) -> Result(#(Int, BitArray), Refusal) {
  case bytes {
    <<"e":utf8, rest:bytes>> | <<"E":utf8, rest:bytes>> ->
      read_signed_exponent(rest)
    _ -> Ok(#(0, bytes))
  }
}

fn read_signed_exponent(bytes: BitArray) -> Result(#(Int, BitArray), Refusal) {
  let #(negative, unsigned) = take_sign(bytes)
  use Nil <- result.try(require_digit(unsigned))
  use #(size, rest) <- result.try(read_exponent_digits(unsigned, 0))
  case negative {
    True -> Ok(#(-size, rest))
    False -> Ok(#(size, rest))
  }
}

fn read_exponent_digits(
  bytes: BitArray,
  size: Int,
) -> Result(#(Int, BitArray), Refusal) {
  case bytes {
    <<character, rest:bytes>> if character >= 48 && character <= 57 ->
      check_exponent(size * 10 + character - 48, rest)
    <<"_":utf8, rest:bytes>> -> {
      use Nil <- result.try(require_digit(rest))
      read_exponent_digits(rest, size)
    }
    _ -> Ok(#(size, bytes))
  }
}

fn check_exponent(
  size: Int,
  rest: BitArray,
) -> Result(#(Int, BitArray), Refusal) {
  case size > largest_exponent {
    True -> Error(OutsideNumericRange)
    False -> read_exponent_digits(rest, size)
  }
}

// --- The binary value -----------------------------------------------------------

// Groups the decimal digits in base 10000, as set_var_from_str does, and
// strips the zero digits at both ends. `decimal_weight` is the power of 10
// of the first decimal digit.
fn finite_bytes(
  negative: Bool,
  decimal_digits: BitArray,
  decimal_weight: Int,
  display_scale: Int,
) -> Result(BitArray, Refusal) {
  let first_weight = case decimal_weight >= 0 {
    True -> decimal_weight / 4
    False -> 0 - { { -decimal_weight - 1 } / 4 + 1 }
  }
  let offset = { first_weight + 1 } * 4 - { decimal_weight + 1 }
  let padding = { 4 - { offset + bit_array.byte_size(decimal_digits) } % 4 } % 4
  let padded = <<
    zeros(offset):bits,
    decimal_digits:bits,
    zeros(padding):bits,
  >>
  let #(leading_stripped, weight) =
    without_leading_zero_digits(group_digits(padded, []), first_weight)
  let digits =
    leading_stripped
    |> list.reverse
    |> list.drop_while(fn(digit) { digit == 0 })
    |> list.reverse
  numeric_bytes(negative, digits, weight, display_scale)
}

fn zeros(count: Int) -> BitArray {
  bit_array.from_string(string.repeat("0", count))
}

fn group_digits(bytes: BitArray, reversed_digits: List(Int)) -> List(Int) {
  case bytes {
    <<first, second, third, fourth, rest:bytes>> -> {
      let digit =
        { first - 48 }
        * 1000
        + { second - 48 }
        * 100
        + { third - 48 }
        * 10
        + { fourth - 48 }
      group_digits(rest, [digit, ..reversed_digits])
    }
    _ -> list.reverse(reversed_digits)
  }
}

fn without_leading_zero_digits(
  digits: List(Int),
  weight: Int,
) -> #(List(Int), Int) {
  case digits {
    [0, ..rest] -> without_leading_zero_digits(rest, weight - 1)
    _ -> #(digits, weight)
  }
}

// A zero is positive, with weight 0. numeric_in refuses a weight or a
// display scale that its stored format cannot hold.
fn numeric_bytes(
  negative: Bool,
  digits: List(Int),
  weight: Int,
  display_scale: Int,
) -> Result(BitArray, Refusal) {
  let #(sign_code, weight) = case digits, negative {
    [], _ -> #(positive_code, 0)
    _, True -> #(negative_code, weight)
    _, False -> #(positive_code, weight)
  }
  let fits =
    weight <= largest_weight
    && weight >= smallest_weight
    && display_scale <= largest_display_scale
  case fits {
    True ->
      Ok(
        list.fold(
          digits,
          <<
            list.length(digits):16,
            weight:16,
            sign_code:16,
            display_scale:16,
          >>,
          fn(bytes, digit) { <<bytes:bits, digit:16>> },
        ),
      )
    False -> Error(OutsideNumericRange)
  }
}
