//// Looks up the underlying type of a type in a table of type descriptions.

import dream_postgres/driver/catalog_table.{type CatalogTable, find_underlying}
import dream_postgres/internal/cell.{type TypeDescription}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/option.{type Option}

/// Gives the description at the end of the domain chain of the type
/// `type_id` in the table, or `None` when the table does not have it. For
/// a type that is not a domain, it gives the type itself.
///
/// ```gleam
/// from_rows(rows)
/// |> should
/// |> be_ok
/// |> extract_underlying_catalog_type(type_id: 911)
/// |> be_some
/// |> be_equal(TypeDescription(3904, "pg_catalog", "int4range", Range(23)))
/// |> or_fail_with("Expected int4range")
/// ```
pub fn extract_underlying_catalog_type(
  result: MatchResult(CatalogTable),
  type_id type_id: Int,
) -> MatchResult(Option(TypeDescription)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(table) -> MatchOk(find_underlying(table, type_id))
  }
}
