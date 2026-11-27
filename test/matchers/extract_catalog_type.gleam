//// Looks up a type in a table of type descriptions.

import dream_postgres/driver/catalog_table.{type CatalogTable, find}
import dream_postgres/internal/cell.{type TypeDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option}

/// Gives the description of the type `type_id` in the table, or `None`
/// when the table does not have it.
///
/// ```gleam
/// from_rows(rows)
/// |> should
/// |> be_ok
/// |> extract_catalog_type(type_id: 23)
/// |> be_some
/// |> be_equal(TypeDescription(23, "pg_catalog", "int4", Base))
/// |> or_fail_with("Expected int4")
/// ```
pub fn extract_catalog_type(
  result: MatchResult(CatalogTable),
  type_id type_id: Int,
) -> MatchResult(Option(TypeDescription)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(table) -> MatchOk(find(table, type_id))
  }
}
