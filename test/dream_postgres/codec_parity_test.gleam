//// The value cases of the pgo fork that the other codec tests do not hold,
//// against the exact bytes of PostgreSQL's binary formats. CODEC_PARITY.md
//// maps each value case of the fork to its test.

import dream_postgres/codecs.{type Codec}
import dream_postgres/codecs/array
import dream_postgres/codecs/codec_type.{OutOfRange}
import dream_postgres/codecs/composite
import dream_postgres/codecs/geometry.{type Point}
import dream_postgres/codecs/numeric
import dream_postgres/codecs/range.{Inclusive, Unbounded}
import dream_postgres/driver/cell.{Binary}
import dream_postgres/row/reader.{column, row}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/float_bytes.{
  float8_values, negative_infinity, not_a_number, positive_infinity,
}
import fixtures/type_catalog
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("codec parity with the pgo fork", [
    group("geometric values that are not finite", [
      it("gives OutOfRange for a point at Infinity", fn() {
        // Arrange
        let cell = Binary(<<float8_values([1.0]):bits, positive_infinity:bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_error()
        |> be_equal(OutOfRange("Infinity"))
        |> or_fail_with("Expected a point with y at Infinity to be refused")
      }),
      it("gives OutOfRange for a point at -Infinity", fn() {
        // Arrange
        let cell = Binary(<<negative_infinity:bits, float8_values([1.0]):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_error()
        |> be_equal(OutOfRange("-Infinity"))
        |> or_fail_with("Expected a point with x at -Infinity to be refused")
      }),
      it("gives OutOfRange for a line with a NaN part", fn() {
        // Arrange
        let cell =
          Binary(<<float8_values([1.0, -1.0]):bits, not_a_number:bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.line, type_catalog.base_with_id(628, "line"))
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a line with a NaN constant to be refused")
      }),
      it("gives OutOfRange for a line segment with a NaN coordinate", fn() {
        // Arrange
        let cell =
          Binary(<<float8_values([0.0, 0.0, 1.0]):bits, not_a_number:bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          geometry.line_segment,
          type_catalog.base_with_id(601, "lseg"),
        )
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a line segment with a NaN y to be refused")
      }),
      it("gives OutOfRange for a box with a NaN coordinate", fn() {
        // Arrange
        let cell =
          Binary(<<not_a_number:bits, float8_values([3.0, 0.0, 1.0]):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.box, type_catalog.base_with_id(603, "box"))
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a box with a NaN x to be refused")
      }),
      it("gives OutOfRange for a path with a NaN coordinate", fn() {
        // Arrange
        let cell =
          Binary(<<
            1,
            2:size(32),
            float8_values([0.0, 0.0, 1.0]):bits,
            not_a_number:bits,
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.path, type_catalog.base_with_id(602, "path"))
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a path with a NaN y to be refused")
      }),
      it("gives OutOfRange for a polygon with a vertex at Infinity", fn() {
        // Arrange
        let cell =
          Binary(<<
            2:size(32),
            float8_values([0.0, 0.0]):bits,
            positive_infinity:bits,
            float8_values([1.0]):bits,
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          geometry.polygon,
          type_catalog.base_with_id(604, "polygon"),
        )
        |> be_error()
        |> be_equal(OutOfRange("Infinity"))
        |> or_fail_with("Expected a polygon with x at Infinity to be refused")
      }),
      it("gives OutOfRange for a circle of radius Infinity", fn() {
        // Arrange
        let cell =
          Binary(<<float8_values([0.0, 0.0]):bits, positive_infinity:bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.circle, type_catalog.base_with_id(718, "circle"))
        |> be_error()
        |> be_equal(OutOfRange("Infinity"))
        |> or_fail_with("Expected a circle of radius Infinity to be refused")
      }),
      it("gives OutOfRange for a point array with a NaN coordinate", fn() {
        // Arrange
        let points: Codec(List(Point)) = array.array(geometry.point)
        let cell =
          Binary(<<
            1:size(32),
            0:size(32),
            600:size(32),
            1:size(32),
            1:size(32),
            16:size(32),
            not_a_number:bits,
            float8_values([0.0]):bits,
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(points, type_catalog.point_array())
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a point array with a NaN x to be refused")
      }),
    ]),
    group("numeric values", [
      it("reads a negative zero with no digits as 0", fn() {
        // Arrange
        let cell = Binary(<<0:16, 0:16, 0x4000:16, 0:16>>)

        // Act and assert
        cell
        |> should
        |> decode_as(numeric.numeric, type_catalog.numeric())
        |> be_ok()
        |> be_equal("0")
        |> or_fail_with("Expected a negative zero to read as 0")
      }),
      it("refuses a numrange bound that is not a numeric value", fn() {
        // Arrange
        let bounds = range.Range(Inclusive("abc"), Unbounded)

        // Act and assert
        bounds
        |> should
        |> encode_as(range.range(numeric.numeric), type_catalog.numeric_range())
        |> be_error()
        |> be_equal("\"abc\" is not a numeric value")
        |> or_fail_with("Expected the bound abc to be refused")
      }),
    ]),
    group("types with no built-in codec", [
      it("int does not take aclitem", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(1033, "aclitem"))
        |> be_false()
        |> or_fail_with("Expected int to refuse aclitem")
      }),
      it("text does not take pg_node_tree", fn() {
        // Arrange
        let subject = codecs.text

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(194, "pg_node_tree"))
        |> be_false()
        |> or_fail_with("Expected text to refuse pg_node_tree")
      }),
      it("a custom codec takes pg_node_tree", fn() {
        // Arrange
        let subject =
          codecs.custom(
            type_name: "pg_node_tree",
            to_text: fn(text) { text },
            from_text: Ok,
            placeholder: "",
          )

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(194, "pg_node_tree"))
        |> be_true()
        |> or_fail_with("Expected a custom pg_node_tree codec to take it")
      }),
      it("an array does not take anyarray", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.pseudo(2277, "anyarray"))
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse anyarray")
      }),
      it("a composite does not take the anonymous record", fn() {
        // Arrange
        let subject =
          composite.composite(
            "record",
            read: {
              use first <- column(codecs.int)
              row(first)
            },
            write: fn(first) { [composite.field(codecs.int, first)] },
            placeholder: 0,
          )

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.pseudo(2249, "record"))
        |> be_false()
        |> or_fail_with("Expected a composite codec to refuse record")
      }),
    ]),
  ])
}
