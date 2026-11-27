//// The numeric codec against the exact bytes of PostgreSQL's binary
//// format: the bytes that numeric_in and numeric_send give for a text, and
//// the text that numeric_recv and numeric_out give for the bytes.

import dream_postgres/codec
import dream_postgres/internal/cell.{Binary, BinaryFormat, Null}
import dream_postgres/internal/codec_type.{Malformed, NullValue}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/numeric_examples.{negative_sign, numeric_value, positive_sign}
import fixtures/type_catalog
import gleam/list
import gleam/string
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("numeric codec", [
    group("codec", [
      it("takes numeric", fn() {
        // Arrange
        let subject = codec.numeric

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.numeric())
        |> be_true()
        |> or_fail_with("Expected the numeric codec to take numeric")
      }),
      it("refuses int4", fn() {
        // Arrange
        let subject = codec.numeric

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4())
        |> be_false()
        |> or_fail_with("Expected the numeric codec to refuse int4")
      }),
      it("uses the binary format", fn() {
        // Arrange
        let subject = codec.numeric

        // Act
        let format = codec_type.format(subject)

        // Assert
        format
        |> should
        |> be_equal(BinaryFormat)
        |> or_fail_with("Expected the numeric codec to use the binary format")
      }),
      it("has the placeholder 0", fn() {
        // Arrange
        let subject = codec.numeric

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_equal("0")
        |> or_fail_with("Expected the placeholder 0")
      }),
    ]),
    group(
      "writing",
      list.map(numeric_examples.examples(), fn(example) {
        it("writes " <> string.inspect(example.text), fn() {
          // Arrange
          let text = example.text

          // Act and assert
          text
          |> should
          |> encode_as(codec.numeric, type_catalog.numeric())
          |> be_ok()
          |> be_equal(Binary(example.value))
          |> or_fail_with(
            "Expected the bytes that numeric_send gives for "
            <> string.inspect(example.text),
          )
        })
      }),
    ),
    group(
      "reading",
      list.append(
        list.map(numeric_examples.examples(), fn(example) {
          it("reads " <> string.inspect(example.canonical), fn() {
            // Arrange
            let cell = Binary(example.value)

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal(example.canonical)
            |> or_fail_with(
              "Expected the text that numeric_out gives: "
              <> string.inspect(example.canonical),
            )
          })
        }),
        [
          it("cuts off the digits past the display scale", fn() {
            // Arrange
            let cell = Binary(numeric_value(-1, positive_sign, 2, [1234]))

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("0.12")
            |> or_fail_with("Expected 0.1234 cut to the display scale 2")
          }),
          it("writes no sign for a negative value cut to zero", fn() {
            // Arrange
            let cell = Binary(numeric_value(0, negative_sign, 1, [0, 1]))

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("0.0")
            |> or_fail_with("Expected -0.0001 cut to 0.0 with no sign")
          }),
          it("keeps the sign of a negative value cut to a nonzero value", fn() {
            // Arrange
            let cell = Binary(numeric_value(0, negative_sign, 2, [1, 5000]))

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("-1.50")
            |> or_fail_with("Expected -1.5 with the display scale 2")
          }),
          it("reads a value far below the display scale as zero", fn() {
            // Arrange
            let cell = Binary(numeric_value(-3, positive_sign, 2, [5]))

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("0.00")
            |> or_fail_with("Expected a value far below 0.01 to read as 0.00")
          }),
          it("reads a leading zero digit", fn() {
            // Arrange
            let cell = Binary(numeric_value(1, positive_sign, 0, [0, 5]))

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("5")
            |> or_fail_with("Expected a leading zero digit to read as 5")
          }),
          it("reads NaN with digits", fn() {
            // Arrange
            let cell = Binary(<<1:16, 3:16, 0xC000:16, 2:16, 7:16>>)

            // Act and assert
            cell
            |> should
            |> decode_as(codec.numeric, type_catalog.numeric())
            |> be_ok()
            |> be_equal("NaN")
            |> or_fail_with("Expected NaN, with its digits not read")
          }),
        ],
      ),
    ),
    group(
      "refusing texts",
      list.flatten([
        list.map(numeric_examples.not_numeric_texts(), fn(text) {
          it("refuses " <> string.inspect(text), fn() {
            // Arrange
            let value = text

            // Act and assert
            value
            |> should
            |> encode_as(codec.numeric, type_catalog.numeric())
            |> be_error()
            |> be_equal(string.inspect(text) <> " is not a numeric value")
            |> or_fail_with(
              "Expected " <> string.inspect(text) <> " to be no numeric value",
            )
          })
        }),
        list.map(numeric_examples.out_of_range_texts(), fn(text) {
          it("refuses " <> string.inspect(text) <> " as out of range", fn() {
            // Arrange
            let value = text

            // Act and assert
            value
            |> should
            |> encode_as(codec.numeric, type_catalog.numeric())
            |> be_error()
            |> be_equal(string.inspect(text) <> " is out of range for numeric")
            |> or_fail_with(
              "Expected " <> string.inspect(text) <> " to be out of range",
            )
          })
        }),
        [
          it(
            "refuses a hexadecimal integer of more than 131072 decimal digits",
            fn() {
              // Arrange
              let huge_hexadecimal = "0x" <> string.repeat("F", 109_000)

              // Act and assert
              huge_hexadecimal
              |> should
              |> encode_as(codec.numeric, type_catalog.numeric())
              |> be_error()
              |> be_equal(
                string.inspect(huge_hexadecimal)
                <> " is out of range for numeric",
              )
              |> or_fail_with(
                "Expected a hexadecimal integer of 109000 digits to be out of range",
              )
            },
          ),
        ],
      ]),
    ),
    group("refusing bytes", [
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NullValue for NULL")
      }),
      it("refuses a header cut short", fn() {
        // Arrange
        let cell = Binary(<<0:16, 0:16, 0:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("a numeric value is cut short"))
        |> or_fail_with("Expected a header of six bytes to be cut short")
      }),
      it("refuses digits cut short", fn() {
        // Arrange
        let cell = Binary(<<2:16, 0:16, 0:16, 0:16, 1:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("a numeric value is cut short"))
        |> or_fail_with("Expected one digit of two to be cut short")
      }),
      it("refuses bytes after the digits", fn() {
        // Arrange
        let cell = Binary(<<1:16, 0:16, 0:16, 0:16, 1:16, 0>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("a numeric value has bytes after its digits"))
        |> or_fail_with("Expected a byte after the digits to be refused")
      }),
      it("refuses an unknown sign", fn() {
        // Arrange
        let cell = Binary(<<0:16, 0:16, 0x1234:16, 0:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("0x1234 is not a numeric sign"))
        |> or_fail_with("Expected the sign 0x1234 to be refused")
      }),
      it("refuses a display scale above 16383", fn() {
        // Arrange
        let cell = Binary(<<0:16, 0:16, 0:16, 0x4000:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("the display scale 16384 is too large"))
        |> or_fail_with("Expected the display scale 16384 to be refused")
      }),
      it("refuses a digit of 10000", fn() {
        // Arrange
        let cell = Binary(<<1:16, 0:16, 0:16, 0:16, 10_000:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("the numeric digit 10000 is not below 10000"))
        |> or_fail_with("Expected the digit 10000 to be refused")
      }),
      it("refuses a negative digit", fn() {
        // Arrange
        let cell = Binary(<<1:16, 0:16, 0:16, 0:16, 0xFFFF:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.numeric, type_catalog.numeric())
        |> be_error()
        |> be_equal(Malformed("the numeric digit 65535 is not below 10000"))
        |> or_fail_with("Expected the digit 65535 to be refused")
      }),
    ]),
  ])
}
