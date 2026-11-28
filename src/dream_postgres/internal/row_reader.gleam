//// Row readers: the type, the functions that build one, the check of a
//// reader against the columns of a prepared statement, and the read of a
//// row. The module `dream_postgres/row` gives the public functions. A
//// composite codec reads the fields of a value with the same readers.
////
//// The check runs a reader with each codec's placeholder in place of the
//// values. So it lists the columns that the reader reads before any row
//// comes. The read of a row then follows that list, and refuses a reader
//// that reads other columns for some values.

import dream_postgres/error.{
  type Reason, AmbiguousColumnName, ColumnCountMismatch, ColumnReadTwice,
  ColumnTypeMismatch, CopyNeedsBinaryCodec, DecodeFailed, MixedColumnReaders,
  NoColumnAtPosition, NoColumnNamed, ProtocolViolation, ReaderDependsOnValue,
  UnexpectedNull, ValueOutOfRange,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type Format, type TypeDescription,
}
import dream_postgres/internal/codec_type.{
  type Codec, type DecodeIssue, type TypeLookup, Malformed, NullValue,
  OutOfRange,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}

/// Reads a row into a value of type `a`.
pub opaque type Row(a) {
  Finished(value: a)
  Reading(
    selector: Selector,
    codec_name: String,
    format: Format,
    accepts: fn(TypeDescription, TypeLookup) -> Bool,
    read: fn(Cell, TypeDescription, TypeLookup) -> Result(Row(a), DecodeIssue),
    skip: fn() -> Row(a),
  )
}

type Selector {
  Next
  At(position: Int)
  Named(name: String)
}

/// Reads the next column with the codec, then goes on with its value.
pub fn column(codec: Codec(a), next: fn(a) -> Row(b)) -> Row(b) {
  reading(Next, codec, next)
}

/// Reads the column at `position`, which counts from 1.
pub fn column_at(
  position: Int,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  reading(At(position), codec, next)
}

/// Reads the column named `name`.
pub fn column_named(
  name: String,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  reading(Named(name), codec, next)
}

/// Gives the value of the row.
pub fn row(value: a) -> Row(a) {
  Finished(value)
}

/// Reads a row of one column with the codec.
pub fn single(codec: Codec(a)) -> Row(a) {
  use value <- column(codec)
  row(value)
}

fn reading(
  selector: Selector,
  codec: Codec(a),
  next: fn(a) -> Row(b),
) -> Row(b) {
  Reading(
    selector:,
    codec_name: codec_type.name(codec),
    format: codec_type.format(codec),
    accepts: fn(description, lookup) {
      codec_type.accepts(codec, description, lookup)
    },
    read: fn(value, description, lookup) {
      codec_type.decode(codec, value, description, lookup)
      |> result.map(next)
    },
    skip: fn() { next(codec_type.placeholder(codec)) },
  )
}

// --- The check -------------------------------------------------------------------

/// A column of a result, with the description of its type.
pub type DescribedColumn {
  DescribedColumn(column: ColumnDescription, type_description: TypeDescription)
}

/// A reader checked against the columns of a result.
pub opaque type CheckedRow(a) {
  CheckedRow(
    reader: Row(a),
    /// What the reader reads, in order.
    reads: List(PlannedRead),
    /// The number of columns of the result.
    column_count: Int,
    /// The format of each column of the result, for the Bind message.
    formats: List(Format),
  )
}

// One read of the reader: which column, with which codec. The position
// counts from 0.
type PlannedRead {
  PlannedRead(
    selector: Selector,
    codec_name: String,
    format: Format,
    position: Int,
    column: DescribedColumn,
  )
}

type Step {
  Step(
    selector: Selector,
    codec_name: String,
    format: Format,
    accepts: fn(TypeDescription, TypeLookup) -> Bool,
  )
}

/// The formats in which the server must send the columns: the codec's
/// format for each column the reader reads, and text for the others.
pub fn result_formats(checked: CheckedRow(a)) -> List(Format) {
  checked.formats
}

/// Whether every codec the reader reads with uses the binary format, as
/// the fields of a composite value in binary need.
pub fn reads_only_binary(checked: CheckedRow(a)) -> Bool {
  list.all(checked.reads, fn(read) { read.format == cell.BinaryFormat })
}

/// Checks that every codec the reader reads with uses the binary format,
/// as a binary COPY needs. The first codec in the text format gives
/// `CopyNeedsBinaryCodec` with its column.
pub fn require_binary_reads(checked: CheckedRow(a)) -> Result(Nil, Reason) {
  case list.find(checked.reads, fn(read) { read.format == cell.TextFormat }) {
    Error(Nil) -> Ok(Nil)
    Ok(read) ->
      Error(CopyNeedsBinaryCodec(
        position: read.position + 1,
        name: read.column.column.name,
        codec: read.codec_name,
      ))
  }
}

/// Checks the reader against the columns of a result, before the run:
/// each column it reads exists, is read one time, and has a type that
/// the codec takes.
pub fn check(
  reader: Row(a),
  columns: List(DescribedColumn),
  lookup: TypeLookup,
) -> Result(CheckedRow(a), Reason) {
  let steps = steps_of(reader, [])
  let column_count = list.length(columns)
  let numbered = list.index_map(columns, fn(column, index) { #(index, column) })
  use found <- result.try(
    case list.all(steps, fn(step) { step.selector == Next }) {
      True -> in_order(steps, numbered, column_count)
      False -> by_selector(steps, numbered, column_count, [], set.new())
    },
  )
  use reads <- result.try(
    list.try_map(found, fn(pair) { checked_read(pair, lookup) }),
  )
  let read_formats =
    found
    |> list.map(fn(pair) { #(pair.1.0, { pair.0 }.format) })
    |> dict.from_list
  let formats =
    list.map(numbered, fn(numbered_column) {
      dict.get(read_formats, numbered_column.0)
      |> result.unwrap(cell.TextFormat)
    })
  Ok(CheckedRow(reader:, reads:, column_count:, formats:))
}

fn steps_of(reader: Row(a), steps: List(Step)) -> List(Step) {
  case reader {
    Finished(..) -> list.reverse(steps)
    Reading(selector:, codec_name:, format:, accepts:, skip:, ..) ->
      steps_of(skip(), [
        Step(selector:, codec_name:, format:, accepts:),
        ..steps
      ])
  }
}

fn in_order(
  steps: List(Step),
  numbered: List(#(Int, DescribedColumn)),
  column_count: Int,
) -> Result(List(#(Step, #(Int, DescribedColumn))), Reason) {
  let expected = list.length(steps)
  case expected == column_count {
    True -> Ok(list.zip(steps, numbered))
    False -> Error(ColumnCountMismatch(expected:, got: column_count))
  }
}

fn by_selector(
  steps: List(Step),
  numbered: List(#(Int, DescribedColumn)),
  column_count: Int,
  found: List(#(Step, #(Int, DescribedColumn))),
  seen: Set(Int),
) -> Result(List(#(Step, #(Int, DescribedColumn))), Reason) {
  case steps {
    [] -> Ok(list.reverse(found))
    [step, ..rest] -> {
      use match <- result.try(column_of(step.selector, numbered, column_count))
      let #(index, described) = match
      use Nil <- result.try(unseen_column(seen, index, described))
      by_selector(
        rest,
        numbered,
        column_count,
        [#(step, match), ..found],
        set.insert(seen, index),
      )
    }
  }
}

fn unseen_column(
  seen: Set(Int),
  index: Int,
  described: DescribedColumn,
) -> Result(Nil, Reason) {
  case set.contains(seen, index) {
    True ->
      Error(ColumnReadTwice(position: index + 1, name: described.column.name))
    False -> Ok(Nil)
  }
}

fn column_of(
  selector: Selector,
  numbered: List(#(Int, DescribedColumn)),
  column_count: Int,
) -> Result(#(Int, DescribedColumn), Reason) {
  case selector {
    Next -> Error(MixedColumnReaders)
    At(position:) -> column_at_position(numbered, position, column_count)
    Named(name:) -> column_of_name(numbered, name)
  }
}

fn column_at_position(
  numbered: List(#(Int, DescribedColumn)),
  position: Int,
  column_count: Int,
) -> Result(#(Int, DescribedColumn), Reason) {
  case list.filter(numbered, fn(pair) { pair.0 == position - 1 }) {
    [match, ..] -> Ok(match)
    [] -> Error(NoColumnAtPosition(position:, columns: column_count))
  }
}

fn column_of_name(
  numbered: List(#(Int, DescribedColumn)),
  name: String,
) -> Result(#(Int, DescribedColumn), Reason) {
  case list.filter(numbered, fn(pair) { { pair.1 }.column.name == name }) {
    [] -> Error(NoColumnNamed(name:))
    [match] -> Ok(match)
    matches -> Error(AmbiguousColumnName(name:, count: list.length(matches)))
  }
}

fn checked_read(
  pair: #(Step, #(Int, DescribedColumn)),
  lookup: TypeLookup,
) -> Result(PlannedRead, Reason) {
  let #(step, #(index, described)) = pair
  case step.accepts(described.type_description, lookup) {
    True ->
      Ok(PlannedRead(
        selector: step.selector,
        codec_name: step.codec_name,
        format: step.format,
        position: index,
        column: described,
      ))
    False ->
      Error(ColumnTypeMismatch(
        position: index + 1,
        name: described.column.name,
        database_type: described.type_description.name,
        codec: step.codec_name,
      ))
  }
}

// --- The read of a row --------------------------------------------------------------

/// Reads a row: its cells, one for each column of the result.
pub fn read(
  checked: CheckedRow(a),
  cells: List(Cell),
  lookup: TypeLookup,
) -> Result(a, Reason) {
  let cell_count = list.length(cells)
  case cell_count == checked.column_count {
    False ->
      Error(ProtocolViolation(
        "a row has "
        <> int.to_string(cell_count)
        <> " values, and the result has "
        <> int.to_string(checked.column_count)
        <> " columns",
      ))
    True -> {
      let by_position =
        cells
        |> list.index_map(fn(value, index) { #(index, value) })
        |> dict.from_list
      // Each planned position is less than the number of cells, so each
      // read finds its cell.
      let reads_with_cells =
        list.filter_map(checked.reads, fn(planned) {
          dict.get(by_position, planned.position)
          |> result.map(fn(value) { #(planned, value) })
        })
      read_steps(checked.reader, reads_with_cells, lookup, 1)
    }
  }
}

fn read_steps(
  reader: Row(a),
  reads: List(#(PlannedRead, Cell)),
  lookup: TypeLookup,
  count: Int,
) -> Result(a, Reason) {
  case reader, reads {
    Finished(value:), [] -> Ok(value)
    Reading(selector:, codec_name:, read:, ..), [#(planned, value), ..rest]
      if selector == planned.selector && codec_name == planned.codec_name
    -> {
      use next <- result.try(
        read(value, planned.column.type_description, lookup)
        |> result.map_error(fn(issue) { decode_reason(issue, planned) }),
      )
      read_steps(next, rest, lookup, count + 1)
    }
    _, _ -> Error(ReaderDependsOnValue(read: count))
  }
}

fn decode_reason(issue: DecodeIssue, planned: PlannedRead) -> Reason {
  let position = planned.position + 1
  let name = planned.column.column.name
  case issue {
    NullValue -> UnexpectedNull(position:, name:)
    OutOfRange(value:) -> ValueOutOfRange(position:, name:, value:)
    Malformed(reason:) -> DecodeFailed(position:, name:, reason:)
  }
}
