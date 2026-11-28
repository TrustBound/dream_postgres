//// The Gleam values of PostgreSQL's geometric types. Every coordinate is a
//// finite `Float`: a `NaN` or an infinite coordinate, which PostgreSQL can
//// store, gives `OutOfRange` when it is read.

/// A `point`.
pub type Point {
  Point(x: Float, y: Float)
}

/// A `line`: the points where `a * x + b * y + c = 0`.
pub type Line {
  Line(a: Float, b: Float, c: Float)
}

/// An `lseg`: the segment from `start` to `end`.
pub type LineSegment {
  LineSegment(start: Point, end: Point)
}

/// A `box`, by two opposite corners. PostgreSQL keeps the upper right
/// corner first.
pub type Box {
  Box(upper_right: Point, lower_left: Point)
}

/// A `path`: open or closed, through its points in order.
pub type Path {
  Path(open: Bool, points: List(Point))
}

/// A `polygon`, by its vertices in order.
pub type Polygon {
  Polygon(vertices: List(Point))
}

/// A `circle`: its center and radius.
pub type Circle {
  Circle(center: Point, radius: Float)
}
