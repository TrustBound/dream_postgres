//// Column descriptions of a statement, the way the server gives them.

import dream_postgres/internal/cell.{type ColumnDescription, ColumnDescription}

/// The description of a result column `name` of the type `type_id`, with no
/// type modifier and no table.
///
/// ## Example
///
/// ```gleam
/// column_description.new("id", 23)
/// // -> ColumnDescription(name: "id", type_id: 23, type_modifier: -1, table_id: 0, column_number: 0)
/// ```
pub fn new(name: String, type_id: Int) -> ColumnDescription {
  ColumnDescription(
    name:,
    type_id:,
    type_modifier: -1,
    table_id: 0,
    column_number: 0,
  )
}
