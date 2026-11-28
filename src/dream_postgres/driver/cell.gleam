//// The values that pass between the driver and the rest of dream_postgres.
////
//// The driver moves bytes. It never decodes a value: a parameter goes to
//// the server as the bytes that a codec wrote, and a cell of a row comes
//// back as the bytes that the server sent. The codecs turn those bytes into
//// Gleam values. Both sides build on the types of this module, so they
//// cannot disagree about what a cell, a column or a type is.
////
//// This module is internal. An app sees these values only through an
//// interceptor's request and outcome.

import gleam/option.{type Option}

/// One value of a parameter or of a row, as it travels on the wire.
pub type Cell {
  /// The binary form of the value's type.
  Binary(bytes: BitArray)
  /// The text form of the value's type, as UTF-8 bytes.
  Text(bytes: BitArray)
  /// SQL NULL.
  Null
}

/// The wire format of a parameter or of a result column.
pub type Format {
  BinaryFormat
  TextFormat
}

/// What PostgreSQL said about one parameter of a prepared statement.
pub type ParameterDescription {
  ParameterDescription(type_id: Int)
}

/// What PostgreSQL said about one result column of a prepared statement.
pub type ColumnDescription {
  ColumnDescription(
    /// The column's name in the result, for example `id` or `?column?`.
    name: String,
    /// The OID of the column's type.
    type_id: Int,
    /// The type modifier, for example the length of a `varchar(20)` or the
    /// precision and scale of a `numeric(10,2)`, or -1 for none.
    type_modifier: Int,
    /// The OID of the table that the column comes from, or 0 for a column
    /// that no table column gives, such as `count(*)`.
    table_id: Int,
    /// The column number inside that table, or 0 when `table_id` is 0.
    column_number: Int,
  )
}

/// What PostgreSQL said about a prepared statement, before any Bind.
pub type StatementDescription {
  StatementDescription(
    parameters: List(ParameterDescription),
    columns: List(ColumnDescription),
  )
}

/// What a type OID is, from the server's catalog.
pub type TypeDescription {
  TypeDescription(id: Int, schema: String, name: String, kind: TypeKind)
}

/// The kind of a type, with the parts that the codecs need.
pub type TypeKind {
  /// A base type, such as `int4`, `text` or an extension's `vector`.
  Base
  /// An enum, with its labels in the order of the type.
  Enum(labels: List(String))
  /// A composite, with each field's name and type OID, in order.
  Composite(fields: List(#(String, Int)))
  /// A domain, with the OID of the type it is based on.
  Domain(base_type_id: Int)
  /// A range, with the OID of its element type.
  Range(element_type_id: Int)
  /// A multirange, with the OID of its range type.
  Multirange(range_type_id: Int)
  /// An array, with the OID of its element type.
  Array(element_type_id: Int)
  /// A pseudo-type, such as `void` or `record`.
  Pseudo
}

/// The state of the connection's transaction, after each command.
pub type TransactionStatus {
  /// Not in a transaction.
  Idle
  /// In a transaction that can still commit.
  InTransaction
  /// In a transaction that failed. Only a rollback can end it.
  InFailedTransaction
}

/// The result of one command: its rows, in cells, and its command tag.
pub type CommandResult {
  CommandResult(
    /// Each row, one cell per column, in column order.
    rows: List(List(Cell)),
    /// The tag that PostgreSQL sent, for example `INSERT 0 3` or `SELECT 2`.
    tag: String,
    /// The row count of the tag, or 0 for a tag with no count.
    count: Int,
  )
}

/// Every field of an ErrorResponse or a NoticeResponse, as the server sent
/// them. The driver drops nothing: a field type that this module does not
/// name goes to `other_fields` with its type byte.
pub type ServerReport {
  ServerReport(
    /// `ERROR`, `FATAL`, `PANIC`, `WARNING`, `NOTICE`, `DEBUG`, `INFO` or
    /// `LOG`, never localized (field `V`).
    severity: String,
    /// The severity in the server's language (field `S`).
    localized_severity: String,
    /// The SQLSTATE code, for example `23505` (field `C`).
    code: String,
    /// The primary message (field `M`).
    message: String,
    /// Field `D`.
    detail: Option(String),
    /// Field `H`.
    hint: Option(String),
    /// A 1-based character position in the query text (field `P`).
    position: Option(Int),
    /// A 1-based character position in `internal_query` (field `p`).
    internal_position: Option(Int),
    /// Field `q`.
    internal_query: Option(String),
    /// The call stack of the error (field `W`).
    context: Option(String),
    /// Field `s`.
    schema: Option(String),
    /// Field `t`.
    table: Option(String),
    /// Field `c`.
    column: Option(String),
    /// Field `d`.
    data_type: Option(String),
    /// Field `n`.
    constraint: Option(String),
    /// The server's source file (field `F`).
    file: Option(String),
    /// The server's source line (field `L`).
    line: Option(Int),
    /// The server's source routine (field `R`).
    routine: Option(String),
    /// Any field type byte not named above, with its value.
    other_fields: List(#(Int, String)),
  )
}
