//// The rows and the command results of a statement: RowDescription, DataRow and
//// CommandComplete.

import dream_postgres/driver/cell.{
  type Cell, type ColumnDescription, type Format, Binary, BinaryFormat, Null,
  Text, TextFormat,
}
import dream_postgres/driver/message.{
  type ResultColumn, CommandComplete, DataRow,
}
import dream_postgres/driver/query/machine.{
  type CellFormats, type Machine, type Transition, BoundFormats, ColumnFormats,
  Machine, command_result, unexpected, wait_with,
}
import dream_postgres/driver/query/step.{
  type UnexpectedMessage, AwaitingStatementResult, StatementResult,
}
import gleam/bool.{guard}
import gleam/int.{parse}
import gleam/list.{contains, last, map, strict_zip}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string.{split, split_once}

/// The commands whose tag ends with a row count (docs, "CommandComplete").
const counted_commands = [
  "INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY",
]

pub fn with_columns(machine: Machine, columns: List(ResultColumn)) -> Machine {
  Machine(
    ..machine,
    columns: map(columns, column_description),
    cell_formats: ColumnFormats(map(columns, column_format)),
  )
}

fn column_description(column: ResultColumn) -> ColumnDescription {
  column.column
}

fn column_format(column: ResultColumn) -> Format {
  column.format
}

pub fn add_row(
  machine: Machine,
  values: List(Option(BitArray)),
) -> Result(Transition, UnexpectedMessage) {
  case row_cells(values, machine.cell_formats) {
    Ok(row) -> Ok(wait_with(Machine(..machine, rows: [row, ..machine.rows])))
    Error(Nil) -> unexpected(machine, DataRow(values:))
  }
}

/// Tags each value of a row with the format of its column. A row with
/// another number of values than the formats give is an error.
fn row_cells(
  values: List(Option(BitArray)),
  cell_formats: CellFormats,
) -> Result(List(Cell), Nil) {
  case cell_formats {
    BoundFormats([]) -> Ok(map(values, to_cell(_, TextFormat)))
    BoundFormats([format]) -> Ok(map(values, to_cell(_, format)))
    BoundFormats(formats) | ColumnFormats(formats) ->
      strict_zip(values, formats)
      |> result.map(map(_, paired_cell))
  }
}

fn paired_cell(value_and_format: #(Option(BitArray), Format)) -> Cell {
  to_cell(value_and_format.0, value_and_format.1)
}

fn to_cell(value: Option(BitArray), format: Format) -> Cell {
  case value, format {
    None, _ -> Null
    Some(bytes), BinaryFormat -> Binary(bytes)
    Some(bytes), TextFormat -> Text(bytes)
  }
}

/// Keeps the tag and its row count. A tag whose count is not a number is
/// an error.
pub fn complete_command(
  machine: Machine,
  tag: String,
) -> Result(Machine, UnexpectedMessage) {
  case row_count(tag) {
    Ok(count) -> Ok(Machine(..machine, tag:, count:))
    Error(Nil) -> unexpected(machine, CommandComplete(tag:))
  }
}

/// Ends one statement of a simple query: its result joins the others, and the
/// next statement starts with no columns and no rows.
pub fn finish_statement(
  machine: Machine,
  tag: String,
) -> Result(Transition, UnexpectedMessage) {
  use completed <- result.map(complete_command(machine, tag))
  let statement =
    StatementResult(
      columns: completed.columns,
      result: command_result(completed),
    )
  Machine(
    ..completed,
    phase: AwaitingStatementResult,
    results: [statement, ..completed.results],
    columns: [],
    cell_formats: ColumnFormats([]),
    rows: [],
  )
  |> wait_with
}

/// The row count of a command tag: its last number for the commands that
/// the docs list under "CommandComplete", else 0.
fn row_count(tag: String) -> Result(Int, Nil) {
  case split_once(tag, " ") {
    Ok(#(command, numbers)) -> counted_rows(command, numbers)
    Error(Nil) -> counted_rows(tag, "")
  }
}

fn counted_rows(command: String, numbers: String) -> Result(Int, Nil) {
  use <- guard(!contains(counted_commands, command), Ok(0))
  numbers
  |> split(" ")
  |> last
  |> result.try(parse)
}
