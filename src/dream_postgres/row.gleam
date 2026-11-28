//// How to read one row of a result into a value: the columns in order, by
//// position or by name, or a result of one column.

import dream_postgres/codec.{type Codec}
import dream_postgres/internal/row_reader

/// How to read one row of a result into a value.
pub type Row(a) =
  row_reader.Row(a)

/// Reads the next column with the codec. A reader that uses `column` reads
/// every column, in order.
pub fn column(codec: Codec(a), next: fn(a) -> Row(b)) -> Row(b) {
  row_reader.column(codec, next)
}

/// Reads the column at a position. Positions count from 1, like `$1`.
pub fn column_at(
  position: Int,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  row_reader.column_at(position, codec, next)
}

/// Reads the column with this name. The name must belong to one column
/// only.
pub fn column_named(
  name: String,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  row_reader.column_named(name, codec, next)
}

/// The value of a row, after its columns are read.
pub fn row(value: a) -> Row(a) {
  row_reader.row(value)
}

/// Reads a result of one column with the codec.
pub fn single(codec: Codec(a)) -> Row(a) {
  row_reader.single(codec)
}
