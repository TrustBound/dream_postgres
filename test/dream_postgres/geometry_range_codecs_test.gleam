//// The geometric, range and multirange codecs against the exact bytes and
//// texts of PostgreSQL's formats.

import dream_postgres/codecs
import dream_postgres/codecs/codec_type.{Malformed, NullValue, OutOfRange}
import dream_postgres/codecs/geometry.{
  Box, Circle, Line, LineSegment, Path, Point, Polygon,
}
import dream_postgres/codecs/range.{EmptyRange, Exclusive, Inclusive, Unbounded}
import dream_postgres/driver/cell.{Binary, Null, Text}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/float_bytes
import fixtures/path_codec
import fixtures/range_bytes
import fixtures/type_catalog
import gleam/option.{None}
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("geometry and range codecs", [
    group("geometric types", [
      it("takes point", fn() {
        // Arrange
        let subject = geometry.point

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.point())
        |> be_true()
        |> or_fail_with("Expected point to take the type point")
      }),
      it("takes line", fn() {
        // Arrange
        let subject = geometry.line

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("line"))
        |> be_true()
        |> or_fail_with("Expected line to take the type line")
      }),
      it("takes lseg", fn() {
        // Arrange
        let subject = geometry.line_segment

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("lseg"))
        |> be_true()
        |> or_fail_with("Expected line_segment to take the type lseg")
      }),
      it("takes box", fn() {
        // Arrange
        let subject = geometry.box

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("box"))
        |> be_true()
        |> or_fail_with("Expected box to take the type box")
      }),
      it("takes path", fn() {
        // Arrange
        let subject = geometry.path

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("path"))
        |> be_true()
        |> or_fail_with("Expected path to take the type path")
      }),
      it("takes polygon", fn() {
        // Arrange
        let subject = geometry.polygon

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("polygon"))
        |> be_true()
        |> or_fail_with("Expected polygon to take the type polygon")
      }),
      it("takes circle", fn() {
        // Arrange
        let subject = geometry.circle

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("circle"))
        |> be_true()
        |> or_fail_with("Expected circle to take the type circle")
      }),
      it("writes a point", fn() {
        // Arrange
        let value = Point(1.0, 2.0)

        // Act and assert
        value
        |> should
        |> encode_as(geometry.point, type_catalog.point())
        |> be_ok()
        |> be_equal(Binary(float_bytes.float8_values([1.0, 2.0])))
        |> or_fail_with("Expected the point as the float8 values 1 and 2")
      }),
      it("reads a point", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([1.0, 2.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_ok()
        |> be_equal(Point(1.0, 2.0))
        |> or_fail_with("Expected the point (1,2)")
      }),
      it("gives OutOfRange for a NaN coordinate", fn() {
        // Arrange
        let cell = Binary(<<1.0:float-size(64), 0x7FF8000000000000:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected a NaN coordinate to be out of range")
      }),
      it("refuses a point that is cut short", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([1.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_error()
        |> be_equal(Malformed("a float8 is cut short"))
        |> or_fail_with("Expected a point of one float8 to be malformed")
      }),
      it("refuses bytes after a point", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([1.0, 2.0, 3.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.point, type_catalog.point())
        |> be_error()
        |> be_equal(Malformed("the value has bytes after its end"))
        |> or_fail_with(
          "Expected a point of three float8 values to be malformed",
        )
      }),
      it("writes a line", fn() {
        // Arrange
        let value = Line(1.0, -1.0, 0.0)

        // Act and assert
        value
        |> should
        |> encode_as(geometry.line, type_catalog.base("line"))
        |> be_ok()
        |> be_equal(Binary(float_bytes.float8_values([1.0, -1.0, 0.0])))
        |> or_fail_with("Expected the line as its a, b and c")
      }),
      it("refuses a line with a and b both 0", fn() {
        // Arrange
        let value = Line(0.0, 0.0, 1.0)

        // Act and assert
        value
        |> should
        |> encode_as(geometry.line, type_catalog.base("line"))
        |> be_error()
        |> be_equal("a line with a and b both 0 is not a line")
        |> or_fail_with("Expected a line with a and b both 0 to be refused")
      }),
      it("reads a line", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([1.0, -1.0, 0.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.line, type_catalog.base("line"))
        |> be_ok()
        |> be_equal(Line(1.0, -1.0, 0.0))
        |> or_fail_with("Expected the line {1,-1,0}")
      }),
      it("writes a line segment", fn() {
        // Arrange
        let value = LineSegment(Point(0.0, 0.0), Point(1.0, 1.0))

        // Act and assert
        value
        |> should
        |> encode_as(geometry.line_segment, type_catalog.base("lseg"))
        |> be_ok()
        |> be_equal(Binary(float_bytes.float8_values([0.0, 0.0, 1.0, 1.0])))
        |> or_fail_with("Expected the line segment as its two points")
      }),
      it("reads a line segment", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([0.0, 0.0, 1.0, 1.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.line_segment, type_catalog.base("lseg"))
        |> be_ok()
        |> be_equal(LineSegment(Point(0.0, 0.0), Point(1.0, 1.0)))
        |> or_fail_with("Expected the line segment from (0,0) to (1,1)")
      }),
      it("writes a box with its upper right corner first", fn() {
        // Arrange
        let value = Box(Point(2.0, 2.0), Point(0.0, 0.0))

        // Act and assert
        value
        |> should
        |> encode_as(geometry.box, type_catalog.base("box"))
        |> be_ok()
        |> be_equal(Binary(float_bytes.float8_values([2.0, 2.0, 0.0, 0.0])))
        |> or_fail_with("Expected the box with the corner (2,2) first")
      }),
      it("reads a box", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([2.0, 2.0, 0.0, 0.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.box, type_catalog.base("box"))
        |> be_ok()
        |> be_equal(Box(Point(2.0, 2.0), Point(0.0, 0.0)))
        |> or_fail_with("Expected the box from (2,2) to (0,0)")
      }),
      it("writes an open path", fn() {
        // Arrange
        let value = Path(True, [Point(0.0, 0.0), Point(1.0, 1.0)])

        // Act and assert
        value
        |> should
        |> encode_as(geometry.path, type_catalog.base("path"))
        |> be_ok()
        |> be_equal(
          Binary(<<
            0,
            2:size(32),
            float_bytes.float8_values([0.0, 0.0, 1.0, 1.0]):bits,
          >>),
        )
        |> or_fail_with(
          "Expected the open flag 0, the count 2 and the two points",
        )
      }),
      it("refuses a path with no point", fn() {
        // Arrange
        let value = Path(False, [])

        // Act and assert
        value
        |> should
        |> encode_as(geometry.path, type_catalog.base("path"))
        |> be_error()
        |> be_equal("a path needs at least one point")
        |> or_fail_with("Expected a path with no point to be refused")
      }),
      it("reads a closed path", fn() {
        // Arrange
        let cell =
          Binary(<<1, 1:size(32), float_bytes.float8_values([3.0, 4.0]):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.path, type_catalog.base("path"))
        |> be_ok()
        |> be_equal(Path(False, [Point(3.0, 4.0)]))
        |> or_fail_with("Expected the closed path of the point (3,4)")
      }),
      it("refuses a path whose header is cut short", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.path, type_catalog.base("path"))
        |> be_error()
        |> be_equal(Malformed("the path's header is cut short"))
        |> or_fail_with("Expected a path of one byte to be malformed")
      }),
      it("refuses a path whose points are cut short", fn() {
        // Arrange
        let cell =
          Binary(<<1, 2:size(32), float_bytes.float8_values([3.0, 4.0]):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.path, type_catalog.base("path"))
        |> be_error()
        |> be_equal(Malformed("a float8 is cut short"))
        |> or_fail_with(
          "Expected a path of two points with one point of bytes to be malformed",
        )
      }),
      it("writes a polygon", fn() {
        // Arrange
        let value = Polygon([Point(0.0, 0.0)])

        // Act and assert
        value
        |> should
        |> encode_as(geometry.polygon, type_catalog.base("polygon"))
        |> be_ok()
        |> be_equal(
          Binary(<<1:size(32), float_bytes.float8_values([0.0, 0.0]):bits>>),
        )
        |> or_fail_with("Expected the count 1 and the vertex (0,0)")
      }),
      it("refuses a polygon with no vertex", fn() {
        // Arrange
        let value = Polygon([])

        // Act and assert
        value
        |> should
        |> encode_as(geometry.polygon, type_catalog.base("polygon"))
        |> be_error()
        |> be_equal("a polygon needs at least one vertex")
        |> or_fail_with("Expected a polygon with no vertex to be refused")
      }),
      it("reads a polygon", fn() {
        // Arrange
        let cell =
          Binary(<<1:size(32), float_bytes.float8_values([5.0, 6.0]):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.polygon, type_catalog.base("polygon"))
        |> be_ok()
        |> be_equal(Polygon([Point(5.0, 6.0)]))
        |> or_fail_with("Expected the polygon of the vertex (5,6)")
      }),
      it("refuses a polygon whose header is cut short", fn() {
        // Arrange
        let cell = Binary(<<1, 2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.polygon, type_catalog.base("polygon"))
        |> be_error()
        |> be_equal(Malformed("the polygon's header is cut short"))
        |> or_fail_with("Expected a polygon of two bytes to be malformed")
      }),
      it("writes a circle", fn() {
        // Arrange
        let value = Circle(Point(1.0, 1.0), 2.0)

        // Act and assert
        value
        |> should
        |> encode_as(geometry.circle, type_catalog.base("circle"))
        |> be_ok()
        |> be_equal(Binary(float_bytes.float8_values([1.0, 1.0, 2.0])))
        |> or_fail_with("Expected the circle as its center and radius")
      }),
      it("refuses a negative radius", fn() {
        // Arrange
        let value = Circle(Point(1.0, 1.0), -2.0)

        // Act and assert
        value
        |> should
        |> encode_as(geometry.circle, type_catalog.base("circle"))
        |> be_error()
        |> be_equal("a circle cannot have a negative radius")
        |> or_fail_with("Expected the radius -2 to be refused")
      }),
      it("reads a circle", fn() {
        // Arrange
        let cell = Binary(float_bytes.float8_values([1.0, 1.0, 2.0]))

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.circle, type_catalog.base("circle"))
        |> be_ok()
        |> be_equal(Circle(Point(1.0, 1.0), 2.0))
        |> or_fail_with("Expected the circle of center (1,1) and radius 2")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(geometry.circle, type_catalog.base("circle"))
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a circle")
      }),
    ]),
    group("binary ranges", [
      it("takes int4range", fn() {
        // Arrange
        let subject = range.range(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_range())
        |> be_true()
        |> or_fail_with("Expected a range of int to take int4range")
      }),
      it("refuses a range of an unknown element", fn() {
        // Arrange
        let subject = range.range(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.lost_range())
        |> be_false()
        |> or_fail_with(
          "Expected a range of int to refuse a range of an unknown element",
        )
      }),
      it("refuses a type that is not a range", fn() {
        // Arrange
        let subject = range.range(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4())
        |> be_false()
        |> or_fail_with("Expected a range of int to refuse int4")
      }),
      it("writes [1,5)", fn() {
        // Arrange
        let value = range.Range(Inclusive(1), Exclusive(5))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(
          Binary(<<
            2,
            range_bytes.int4_bound(1):bits,
            range_bytes.int4_bound(5):bits,
          >>),
        )
        |> or_fail_with("Expected the flags 2 and the bounds 1 and 5")
      }),
      it("writes (1,5]", fn() {
        // Arrange
        let value = range.Range(Exclusive(1), Inclusive(5))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(
          Binary(<<
            4,
            range_bytes.int4_bound(1):bits,
            range_bytes.int4_bound(5):bits,
          >>),
        )
        |> or_fail_with("Expected the flags 4 and the bounds 1 and 5")
      }),
      it("writes [1,) with no upper bound", fn() {
        // Arrange
        let value = range.Range(Inclusive(1), Unbounded)

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(Binary(<<18, range_bytes.int4_bound(1):bits>>))
        |> or_fail_with("Expected the flags 18 and only the lower bound 1")
      }),
      it("writes (,5) with no lower bound", fn() {
        // Arrange
        let value = range.Range(Unbounded, Exclusive(5))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(Binary(<<8, range_bytes.int4_bound(5):bits>>))
        |> or_fail_with("Expected the flags 8 and only the upper bound 5")
      }),
      it("writes empty", fn() {
        // Arrange
        let value = EmptyRange

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(Binary(<<1>>))
        |> or_fail_with("Expected the empty range as the flags 1")
      }),
      it("refuses a bound out of range", fn() {
        // Arrange
        let value = range.Range(Inclusive(1), Exclusive(9_999_999_999))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal("9999999999 is out of range for int4")
        |> or_fail_with(
          "Expected the bound 9999999999 to be out of range for int4",
        )
      }),
      it("refuses a NULL bound", fn() {
        // Arrange
        let value = range.Range(Inclusive(None), Unbounded)

        // Act and assert
        value
        |> should
        |> encode_as(
          range.range(codecs.nullable(codecs.int)),
          type_catalog.int4_range(),
        )
        |> be_error()
        |> be_equal("a range bound cannot be NULL")
        |> or_fail_with("Expected a NULL bound to be refused")
      }),
      it("refuses a parameter type that is not a range", fn() {
        // Arrange
        let value = EmptyRange

        // Act and assert
        value
        |> should
        |> encode_as(range.range(codecs.int), type_catalog.int4())
        |> be_error()
        |> be_equal("int4 is not a range type")
        |> or_fail_with("Expected a range of int to refuse to write int4")
      }),
      it("reads [1,5)", fn() {
        // Arrange
        let cell =
          Binary(<<
            2,
            range_bytes.int4_bound(1):bits,
            range_bytes.int4_bound(5):bits,
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(range.Range(Inclusive(1), Exclusive(5)))
        |> or_fail_with("Expected the range [1,5)")
      }),
      it("reads (,5]", fn() {
        // Arrange
        let cell = Binary(<<12, range_bytes.int4_bound(5):bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(range.Range(Unbounded, Inclusive(5)))
        |> or_fail_with("Expected the range (,5]")
      }),
      it("reads empty", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_ok()
        |> be_equal(EmptyRange)
        |> or_fail_with("Expected the empty range")
      }),
      it("refuses no bytes", fn() {
        // Arrange
        let cell = Binary(<<>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal(Malformed("the range is empty bytes"))
        |> or_fail_with("Expected a range of no bytes to be malformed")
      }),
      it("refuses a bound that is cut short", fn() {
        // Arrange
        let cell = Binary(<<2, 4:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal(Malformed("a range bound is cut short"))
        |> or_fail_with("Expected a bound with no value bytes to be malformed")
      }),
      it("refuses bytes after the bounds", fn() {
        // Arrange
        let cell = Binary(<<24, 9>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal(Malformed("the range has bytes after its bounds"))
        |> or_fail_with(
          "Expected a byte after a range of no bounds to be malformed",
        )
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a range")
      }),
      it("refuses a column type that is not a range", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(codecs.int), type_catalog.int4())
        |> be_error()
        |> be_equal(Malformed("int4 is not a range type"))
        |> or_fail_with("Expected a range of int to refuse to read int4")
      }),
    ]),
    group("binary multiranges", [
      it("takes int4multirange", fn() {
        // Arrange
        let subject = range.multirange(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_multirange())
        |> be_true()
        |> or_fail_with("Expected a multirange of int to take int4multirange")
      }),
      it("refuses a multirange of an unknown range", fn() {
        // Arrange
        let subject = range.multirange(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.lost_multirange())
        |> be_false()
        |> or_fail_with(
          "Expected a multirange of int to refuse a multirange of an unknown range",
        )
      }),
      it("refuses a type that is not a multirange", fn() {
        // Arrange
        let subject = range.multirange(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_range())
        |> be_false()
        |> or_fail_with("Expected a multirange of int to refuse int4range")
      }),
      it("writes two ranges", fn() {
        // Arrange
        let value = [
          range.Range(Inclusive(1), Exclusive(3)),
          range.Range(Inclusive(5), Exclusive(7)),
        ]

        // Act and assert
        value
        |> should
        |> encode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_ok()
        |> be_equal(Binary(range_bytes.two_int4_ranges()))
        |> or_fail_with(
          "Expected the count 2 and the two ranges, each with its length",
        )
      }),
      it("refuses a range out of range", fn() {
        // Arrange
        let value = [range.Range(Inclusive(9_999_999_999), Unbounded)]

        // Act and assert
        value
        |> should
        |> encode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal("9999999999 is out of range for int4")
        |> or_fail_with(
          "Expected the bound 9999999999 to be out of range for int4",
        )
      }),
      it("refuses a parameter type that is not a multirange", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(range.multirange(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal("int4range is not a multirange type")
        |> or_fail_with(
          "Expected a multirange of int to refuse to write int4range",
        )
      }),
      it("reads two ranges", fn() {
        // Arrange
        let cell = Binary(range_bytes.two_int4_ranges())

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_ok()
        |> be_equal([
          range.Range(Inclusive(1), Exclusive(3)),
          range.Range(Inclusive(5), Exclusive(7)),
        ])
        |> or_fail_with("Expected the ranges [1,3) and [5,7)")
      }),
      it("reads no ranges", fn() {
        // Arrange
        let cell = Binary(<<0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_ok()
        |> be_equal([])
        |> or_fail_with("Expected a multirange of no ranges")
      }),
      it("refuses a range that does not decode", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the range is empty bytes"))
        |> or_fail_with("Expected a range of no bytes to be malformed")
      }),
      it("refuses bytes after the last range", fn() {
        // Arrange
        let cell = Binary(<<0:size(32), 9>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the multirange has bytes after its last range"))
        |> or_fail_with("Expected a byte after the last range to be malformed")
      }),
      it("refuses ranges that are cut short", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 9:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the multirange's ranges are cut short"))
        |> or_fail_with(
          "Expected a range of length 9 with no bytes to be malformed",
        )
      }),
      it("refuses a header that is cut short", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the multirange's header is cut short"))
        |> or_fail_with("Expected a count of one byte to be malformed")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(codecs.int),
          type_catalog.int4_multirange(),
        )
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a multirange")
      }),
      it("refuses a column type that is not a multirange", fn() {
        // Arrange
        let cell = Binary(<<0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.multirange(codecs.int), type_catalog.int4_range())
        |> be_error()
        |> be_equal(Malformed("int4range is not a multirange type"))
        |> or_fail_with(
          "Expected a multirange of int to refuse to read int4range",
        )
      }),
      it("refuses a multirange whose range type is not a range", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(
          range.multirange(codecs.int),
          type_catalog.multirange_of_int4(),
        )
        |> be_error()
        |> be_equal("int4 is not a range type")
        |> or_fail_with(
          "Expected a multirange whose range type is int4 to be refused",
        )
      }),
    ]),
    group("text ranges", [
      it("takes a range of a custom type", fn() {
        // Arrange
        let subject = range.range(path_codec.path())

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.path_range())
        |> be_true()
        |> or_fail_with("Expected a range of the path codec to take pathrange")
      }),
      it("writes quoted bounds with escapes", fn() {
        // Arrange
        let value = range.Range(Inclusive("a\"b"), Exclusive("c\\d"))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(Text(<<"[\"a\\\"b\",\"c\\\\d\")":utf8>>))
        |> or_fail_with(
          "Expected each bound in quotes, with its quote and backslash escaped",
        )
      }),
      it("writes unbounded sides", fn() {
        // Arrange
        let value = range.Range(Unbounded, Inclusive("z"))

        // Act and assert
        value
        |> should
        |> encode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(Text(<<"(,\"z\"]":utf8>>))
        |> or_fail_with("Expected no lower bound and the quoted upper bound z")
      }),
      it("writes empty", fn() {
        // Arrange
        let value = EmptyRange

        // Act and assert
        value
        |> should
        |> encode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(Text(<<"empty":utf8>>))
        |> or_fail_with("Expected the text empty")
      }),
      it("refuses a NULL bound", fn() {
        // Arrange
        let value = range.Range(Inclusive(None), Unbounded)

        // Act and assert
        value
        |> should
        |> encode_as(
          range.range(codecs.nullable(path_codec.path())),
          type_catalog.path_range(),
        )
        |> be_error()
        |> be_equal("a range bound cannot be NULL")
        |> or_fail_with("Expected a NULL bound to be refused")
      }),
      it("reads empty", fn() {
        // Arrange
        let cell = Text(<<"empty":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(EmptyRange)
        |> or_fail_with("Expected the text empty to be the empty range")
      }),
      it("reads EMPTY", fn() {
        // Arrange
        let cell = Text(<<" EMPTY ":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(EmptyRange)
        |> or_fail_with(
          "Expected the text EMPTY with spaces to be the empty range",
        )
      }),
      it("reads unquoted bounds", fn() {
        // Arrange
        let cell = Text(<<"[a,b)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(range.Range(Inclusive("a"), Exclusive("b")))
        |> or_fail_with("Expected the range [a,b)")
      }),
      it("reads quoted bounds with escapes", fn() {
        // Arrange
        let cell = Text(<<"(\"a\\\"b\",\"c\"\"d\"]":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(range.Range(Exclusive("a\"b"), Inclusive("c\"d")))
        |> or_fail_with("Expected both escaped quotes to be read as quotes")
      }),
      it("reads unbounded sides", fn() {
        // Arrange
        let cell = Text(<<"(,b]":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(range.Range(Unbounded, Inclusive("b")))
        |> or_fail_with("Expected no lower bound and the upper bound b")
      }),
      it("reads no upper bound", fn() {
        // Arrange
        let cell = Text(<<"[a,)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(range.Range(Inclusive("a"), Unbounded))
        |> or_fail_with("Expected the lower bound a and no upper bound")
      }),
      it("reads an escape outside quotes", fn() {
        // Arrange
        let cell = Text(<<"[a\\,b,c)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_ok()
        |> be_equal(range.Range(Inclusive("a,b"), Exclusive("c")))
        |> or_fail_with(
          "Expected the escaped comma to be a part of the bound a,b",
        )
      }),
      it("gives a bound's own error", fn() {
        // Arrange
        let cell = Text(<<"[bad,c)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("not an ltree"))
        |> or_fail_with(
          "Expected the lower bound bad to give the error of the path codec",
        )
      }),
      it("gives an upper bound's own error", fn() {
        // Arrange
        let cell = Text(<<"[a,bad)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("not an ltree"))
        |> or_fail_with(
          "Expected the upper bound bad to give the error of the path codec",
        )
      }),
      it("refuses a text that does not start with a bracket", fn() {
        // Arrange
        let cell = Text(<<"a,b)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the range text does not start with [ or ("))
        |> or_fail_with(
          "Expected a range text with no opening bracket to be malformed",
        )
      }),
      it("refuses a text with no comma", fn() {
        // Arrange
        let cell = Text(<<"[\"a\"b)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the range text has no comma between its bounds"))
        |> or_fail_with("Expected a range text with no comma to be malformed")
      }),
      it("refuses a text with no closing mark", fn() {
        // Arrange
        let cell = Text(<<"[a,\"b\"":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the range text does not end with ] or )"))
        |> or_fail_with(
          "Expected a range text with no closing bracket to be malformed",
        )
      }),
      it("refuses characters after the end", fn() {
        // Arrange
        let cell = Text(<<"[a,b)x":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the range text has characters after its end"))
        |> or_fail_with("Expected a character after the range to be malformed")
      }),
      it("refuses a quote that does not close", fn() {
        // Arrange
        let cell = Text(<<"[\"a":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the range text has a quote that does not close"))
        |> or_fail_with("Expected a quote that does not close to be malformed")
      }),
      it("refuses text that is not UTF-8", fn() {
        // Arrange
        let cell = Text(<<255>>)

        // Act and assert
        cell
        |> should
        |> decode_as(range.range(path_codec.path()), type_catalog.path_range())
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the byte 255 to be refused as not UTF-8")
      }),
    ]),
    group("text multiranges", [
      it("takes a multirange of a custom type", fn() {
        // Arrange
        let subject = range.multirange(path_codec.path())

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.path_multirange())
        |> be_true()
        |> or_fail_with(
          "Expected a multirange of the path codec to take pathmultirange",
        )
      }),
      it("writes two ranges", fn() {
        // Arrange
        let value = [range.Range(Inclusive("a"), Exclusive("b")), EmptyRange]

        // Act and assert
        value
        |> should
        |> encode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_ok()
        |> be_equal(Text(<<"{[\"a\",\"b\"),empty}":utf8>>))
        |> or_fail_with(
          "Expected the two ranges in braces, separated by a comma",
        )
      }),
      it("refuses a NULL bound", fn() {
        // Arrange
        let value = [range.Range(Inclusive(None), Unbounded)]

        // Act and assert
        value
        |> should
        |> encode_as(
          range.multirange(codecs.nullable(path_codec.path())),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal("a range bound cannot be NULL")
        |> or_fail_with("Expected a NULL bound to be refused")
      }),
      it("reads no ranges", fn() {
        // Arrange
        let cell = Text(<<"{}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_ok()
        |> be_equal([])
        |> or_fail_with("Expected the text {} to be no ranges")
      }),
      it("reads two ranges", fn() {
        // Arrange
        let cell = Text(<<"{[a,b),(c,d]}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_ok()
        |> be_equal([
          range.Range(Inclusive("a"), Exclusive("b")),
          range.Range(Exclusive("c"), Inclusive("d")),
        ])
        |> or_fail_with("Expected the ranges [a,b) and (c,d]")
      }),
      it("reads empty in a multirange", fn() {
        // Arrange
        let cell = Text(<<"{empty}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_ok()
        |> be_equal([EmptyRange])
        |> or_fail_with("Expected one empty range")
      }),
      it("gives a range's own error", fn() {
        // Arrange
        let cell = Text(<<"{[bad,b)}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("not an ltree"))
        |> or_fail_with(
          "Expected the bound bad to give the error of the path codec",
        )
      }),
      it("refuses a text with no opening brace", fn() {
        // Arrange
        let cell = Text(<<"[a,b)":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the multirange text does not start with a brace"))
        |> or_fail_with(
          "Expected a multirange text with no opening brace to be malformed",
        )
      }),
      it("refuses a character after a range", fn() {
        // Arrange
        let cell = Text(<<"{[a,b)x}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed(
          "the multirange text has a character after a range",
        ))
        |> or_fail_with("Expected a character after a range to be malformed")
      }),
      it("refuses a range that does not parse", fn() {
        // Arrange
        let cell = Text(<<"{a}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the range text does not start with [ or ("))
        |> or_fail_with(
          "Expected a range with no opening bracket to be malformed",
        )
      }),
      it("refuses text that is not UTF-8", fn() {
        // Arrange
        let cell = Text(<<255>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          range.multirange(path_codec.path()),
          type_catalog.path_multirange(),
        )
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the byte 255 to be refused as not UTF-8")
      }),
      it("refuses an array type", fn() {
        // Arrange
        let subject = range.multirange(path_codec.path())

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_array())
        |> be_false()
        |> or_fail_with(
          "Expected a multirange of the path codec to refuse an array type",
        )
      }),
    ]),
  ])
}
