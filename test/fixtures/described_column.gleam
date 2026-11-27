//// Result columns with the description of their type, the way a row
//// reader checks them.

import dream_postgres/internal/cell.{type TypeDescription}
import dream_postgres/internal/row_reader.{type DescribedColumn, DescribedColumn}
import fixtures/column_description

/// The result column `name` of the type `type_description`.
///
/// ## Example
///
/// ```gleam
/// described_column.new("id", type_catalog.int4())
/// ```
pub fn new(name: String, type_description: TypeDescription) -> DescribedColumn {
  DescribedColumn(
    column: column_description.new(name, type_description.id),
    type_description:,
  )
}
