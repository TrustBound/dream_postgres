//// The codecs of the geometric types, in PostgreSQL's binary formats. Each
//// coordinate is a float8:
////
//// - `point`: x, y. `line`: a, b, c. `lseg`: the two points.
//// - `box`: the upper right point, then the lower left point.
//// - `path`: 1 for closed or 0 for open, the number of points (32 bits),
////   then the points. `polygon`: the number of points, then the points.
//// - `circle`: the center, then the radius.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  read_float8,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import dream_postgres/geometry.{
  type Box, type Circle, type Line, type LineSegment, type Path, type Point,
  type Polygon, Box, Circle, Line, LineSegment, Path, Point, Polygon,
}
import gleam/list
import gleam/result

pub const point =
  Codec(
    name: "point",
    gleam_type: "Point",
    format: cell.BinaryFormat,
    accepts: accepts_point,
    encode: encode_point,
    decode: decode_point,
    placeholder: Point(0.0, 0.0),
  )

pub const line =
  Codec(
    name: "line",
    gleam_type: "Line",
    format: cell.BinaryFormat,
    accepts: accepts_line,
    encode: encode_line,
    decode: decode_line,
    placeholder: Line(0.0, 1.0, 0.0),
  )

pub const line_segment =
  Codec(
    name: "line segment",
    gleam_type: "LineSegment",
    format: cell.BinaryFormat,
    accepts: accepts_line_segment,
    encode: encode_line_segment,
    decode: decode_line_segment,
    placeholder: LineSegment(Point(0.0, 0.0), Point(0.0, 0.0)),
  )

pub const box =
  Codec(
    name: "box",
    gleam_type: "Box",
    format: cell.BinaryFormat,
    accepts: accepts_box,
    encode: encode_box,
    decode: decode_box,
    placeholder: Box(Point(0.0, 0.0), Point(0.0, 0.0)),
  )

pub const path =
  Codec(
    name: "path",
    gleam_type: "Path",
    format: cell.BinaryFormat,
    accepts: accepts_path,
    encode: encode_path,
    decode: decode_path,
    placeholder: Path(True, []),
  )

pub const polygon =
  Codec(
    name: "polygon",
    gleam_type: "Polygon",
    format: cell.BinaryFormat,
    accepts: accepts_polygon,
    encode: encode_polygon,
    decode: decode_polygon,
    placeholder: Polygon([]),
  )

pub const circle =
  Codec(
    name: "circle",
    gleam_type: "Circle",
    format: cell.BinaryFormat,
    accepts: accepts_circle,
    encode: encode_circle,
    decode: decode_circle,
    placeholder: Circle(Point(0.0, 0.0), 0.0),
  )

// --- accepts -------------------------------------------------------------------

fn accepts_point(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["point"])
}

fn accepts_line(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["line"])
}

fn accepts_line_segment(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["lseg"])
}

fn accepts_box(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["box"])
}

fn accepts_path(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["path"])
}

fn accepts_polygon(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["polygon"])
}

fn accepts_circle(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["circle"])
}

// --- encode --------------------------------------------------------------------

fn point_bytes(value: Point) -> BitArray {
  <<value.x:float-size(64), value.y:float-size(64)>>
}

fn points_bytes(points: List(Point)) -> BitArray {
  list.fold(points, <<>>, fn(bytes, value) {
    <<bytes:bits, point_bytes(value):bits>>
  })
}

fn encode_point(
  value: Point,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(point_bytes(value)))
}

fn encode_line(
  value: Line,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case value.a == 0.0 && value.b == 0.0 {
    True -> Error("a line with a and b both 0 is not a line")
    False ->
      Ok(
        Binary(<<
          value.a:float-size(64),
          value.b:float-size(64),
          value.c:float-size(64),
        >>),
      )
  }
}

fn encode_line_segment(
  value: LineSegment,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(<<point_bytes(value.start):bits, point_bytes(value.end):bits>>))
}

fn encode_box(
  value: Box,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(
    Binary(<<
      point_bytes(value.upper_right):bits,
      point_bytes(value.lower_left):bits,
    >>),
  )
}

fn encode_path(
  value: Path,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let closed = case value.open {
    True -> 0
    False -> 1
  }
  case value.points {
    [] -> Error("a path needs at least one point")
    _ ->
      Ok(
        Binary(<<
          closed,
          { list.length(value.points) }:size(32),
          points_bytes(value.points):bits,
        >>),
      )
  }
}

fn encode_polygon(
  value: Polygon,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case value.vertices {
    [] -> Error("a polygon needs at least one vertex")
    _ ->
      Ok(
        Binary(<<
          { list.length(value.vertices) }:size(32),
          points_bytes(value.vertices):bits,
        >>),
      )
  }
}

fn encode_circle(
  value: Circle,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case value.radius <. 0.0 {
    True -> Error("a circle cannot have a negative radius")
    False ->
      Ok(
        Binary(<<point_bytes(value.center):bits, value.radius:float-size(64)>>),
      )
  }
}

// --- decode --------------------------------------------------------------------

fn read_point(bytes: BitArray) -> Result(#(Point, BitArray), DecodeIssue) {
  use #(x, rest) <- result.try(read_float8(bytes))
  use #(y, rest) <- result.try(read_float8(rest))
  Ok(#(Point(x, y), rest))
}

fn read_points(
  bytes: BitArray,
  remaining: Int,
  points: List(Point),
) -> Result(#(List(Point), BitArray), DecodeIssue) {
  case remaining {
    0 -> Ok(#(list.reverse(points), bytes))
    _ -> {
      use #(found, rest) <- result.try(read_point(bytes))
      read_points(rest, remaining - 1, [found, ..points])
    }
  }
}

fn finish(value: a, rest: BitArray) -> Result(a, DecodeIssue) {
  case rest {
    <<>> -> Ok(value)
    _ -> Error(Malformed("the value has bytes after its end"))
  }
}

fn decode_point(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Point, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use #(found, rest) <- result.try(read_point(bytes))
  finish(found, rest)
}

fn decode_line(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Line, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use #(a, rest) <- result.try(read_float8(bytes))
  use #(b, rest) <- result.try(read_float8(rest))
  use #(c, rest) <- result.try(read_float8(rest))
  finish(Line(a, b, c), rest)
}

fn decode_line_segment(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(LineSegment, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use #(start, rest) <- result.try(read_point(bytes))
  use #(end, rest) <- result.try(read_point(rest))
  finish(LineSegment(start, end), rest)
}

fn decode_box(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Box, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use #(upper_right, rest) <- result.try(read_point(bytes))
  use #(lower_left, rest) <- result.try(read_point(rest))
  finish(Box(upper_right, lower_left), rest)
}

fn decode_path(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Path, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<closed, count:size(32), rest:bits>> -> {
      use #(points, rest) <- result.try(read_points(rest, count, []))
      finish(Path(open: closed == 0, points:), rest)
    }
    _ -> Error(Malformed("the path's header is cut short"))
  }
}

fn decode_polygon(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Polygon, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<count:size(32), rest:bits>> -> {
      use #(vertices, rest) <- result.try(read_points(rest, count, []))
      finish(Polygon(vertices), rest)
    }
    _ -> Error(Malformed("the polygon's header is cut short"))
  }
}

fn decode_circle(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Circle, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  use #(center, rest) <- result.try(read_point(bytes))
  use #(radius, rest) <- result.try(read_float8(rest))
  finish(Circle(center, radius), rest)
}
