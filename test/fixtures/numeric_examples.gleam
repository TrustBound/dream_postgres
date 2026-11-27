//// Numeric values in PostgreSQL's binary format, and texts that
//// PostgreSQL's numeric_in takes and refuses.

import gleam/list
import gleam/string

/// The sign code of a positive numeric value.
pub const positive_sign = 0x0000

/// The sign code of a negative numeric value.
pub const negative_sign = 0x4000

/// A text, the binary value that numeric_in and numeric_send give for it,
/// and the text that numeric_recv and numeric_out give back.
pub type NumericExample {
  NumericExample(text: String, value: BitArray, canonical: String)
}

/// The binary numeric value: digit count, weight, sign code, display scale,
/// and the base-10000 digits.
///
/// ## Example
///
/// ```gleam
/// numeric_examples.numeric_value(0, positive_sign, 4, [1234, 5600])
/// // -> the bytes of 1234.5600
/// ```
pub fn numeric_value(
  weight: Int,
  sign_code: Int,
  display_scale: Int,
  digits: List(Int),
) -> BitArray {
  list.fold(
    digits,
    <<list.length(digits):16, weight:16, sign_code:16, display_scale:16>>,
    fn(bytes, digit) { <<bytes:bits, digit:16>> },
  )
}

/// The texts with the bytes that PostgreSQL gives for them.
pub fn examples() -> List(NumericExample) {
  [
    NumericExample("0", numeric_value(0, positive_sign, 0, []), "0"),
    NumericExample("1", numeric_value(0, positive_sign, 0, [1]), "1"),
    NumericExample("-1", numeric_value(0, negative_sign, 0, [1]), "-1"),
    NumericExample(
      "1234.5600",
      numeric_value(0, positive_sign, 4, [1234, 5600]),
      "1234.5600",
    ),
    NumericExample("0.0001", numeric_value(-1, positive_sign, 4, [1]), "0.0001"),
    NumericExample(
      "100000000",
      numeric_value(2, positive_sign, 0, [1]),
      "100000000",
    ),
    NumericExample(
      "1e-20",
      numeric_value(-5, positive_sign, 20, [1]),
      "0.00000000000000000001",
    ),
    NumericExample(
      "12345678901234567890.123456789",
      numeric_value(4, positive_sign, 9, [
        1234, 5678, 9012, 3456, 7890, 1234, 5678, 9000,
      ]),
      "12345678901234567890.123456789",
    ),
    NumericExample("NaN", <<0:16, 0:16, 0xC000:16, 0:16>>, "NaN"),
    NumericExample(" nan ", <<0:16, 0:16, 0xC000:16, 0:16>>, "NaN"),
    NumericExample("Infinity", <<0:16, 0:16, 0xD000:16, 0:16>>, "Infinity"),
    NumericExample("+INFINITY", <<0:16, 0:16, 0xD000:16, 0:16>>, "Infinity"),
    NumericExample("inf", <<0:16, 0:16, 0xD000:16, 0:16>>, "Infinity"),
    NumericExample("-Infinity", <<0:16, 0:16, 0xF000:16, 0:16>>, "-Infinity"),
    NumericExample("-InF", <<0:16, 0:16, 0xF000:16, 0:16>>, "-Infinity"),
    NumericExample("1.5E+3", numeric_value(0, positive_sign, 0, [1500]), "1500"),
    NumericExample(
      "15e-1",
      numeric_value(0, positive_sign, 1, [1, 5000]),
      "1.5",
    ),
    NumericExample(
      "1_000_000",
      numeric_value(1, positive_sign, 0, [100]),
      "1000000",
    ),
    NumericExample(
      "1_2.3_4e1_0",
      numeric_value(2, positive_sign, 0, [1234]),
      "123400000000",
    ),
    NumericExample("-0.00", numeric_value(0, positive_sign, 2, []), "0.00"),
    NumericExample("0e-5", numeric_value(0, positive_sign, 5, []), "0.00000"),
    NumericExample(
      " \t+.5\n ",
      numeric_value(-1, positive_sign, 1, [5000]),
      "0.5",
    ),
    NumericExample("5.", numeric_value(0, positive_sign, 0, [5]), "5"),
    NumericExample("1.e2", numeric_value(0, positive_sign, 0, [100]), "100"),
    NumericExample(
      "000123.4500",
      numeric_value(0, positive_sign, 4, [123, 4500]),
      "123.4500",
    ),
    NumericExample("0x1F", numeric_value(0, positive_sign, 0, [31]), "31"),
    NumericExample("-0X_f_F", numeric_value(0, negative_sign, 0, [255]), "-255"),
    NumericExample("0o17", numeric_value(0, positive_sign, 0, [15]), "15"),
    NumericExample("0O1_7", numeric_value(0, positive_sign, 0, [15]), "15"),
    NumericExample("0b101 ", numeric_value(0, positive_sign, 0, [5]), "5"),
    NumericExample("0B1", numeric_value(0, positive_sign, 0, [1]), "1"),
    NumericExample("-0x0", numeric_value(0, positive_sign, 0, []), "0"),
    NumericExample(
      "0xFFFFFFFFFFFFFFFFFFFF",
      numeric_value(6, positive_sign, 0, [1, 2089, 2581, 9614, 6291, 7470, 6175]),
      "1208925819614629174706175",
    ),
    NumericExample(
      "1e-16383",
      numeric_value(-4096, positive_sign, 16_383, [10]),
      "0." <> string.repeat("0", 16_382) <> "1",
    ),
    NumericExample(
      "1e131071",
      numeric_value(32_767, positive_sign, 0, [1000]),
      "1" <> string.repeat("0", 131_071),
    ),
  ]
}

/// Texts that are not numeric values.
pub fn not_numeric_texts() -> List(String) {
  [
    "", " ", ".", "+", "-", "1.2.3", "12a", "1e", "e5", "--1", "+-1", "1e+",
    "1e-", "-nan", "+NaN", "nanx", "infinit", "infinityx", "-infx", "1._5",
    "._5", "1_", "_1", "1__0", "1_.5", "1e_5", "1e5_", "1e5.5", "abc", "1 2",
    "0x", "0x_", "0x1__2", "0x1_", "0b2", "0o8", "0x1G", "0x1.5", "-0b", "١",
    "1\u{00A0}",
  ]
}

/// Texts that are numeric values out of the range of `numeric`.
pub fn out_of_range_texts() -> List(String) {
  [
    "1e131072", "-1e131072", "1e-16384", "0e-16384", "0.1e-16383",
    "1e1073741823", "1e1073741824", "1e99999999999x",
  ]
}
