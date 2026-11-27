//// A matcher that gives the client reason of an error of the type catalog.

import dream_postgres/driver/catalog.{type CatalogError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/endpoints

/// Give the client reason of an error of the type catalog, as the client
/// sees it.
///
/// ## Example
///
/// ```gleam
/// catalog.UnknownType(90_000)
/// |> should
/// |> map_catalog_error()
/// |> be_equal(error.UnknownType(90_000))
/// |> or_fail_with("Expected UnknownType(90000)")
/// ```
pub fn map_catalog_error(
  result: MatchResult(CatalogError),
) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(catalog_error) ->
      MatchOk(driver_executor.catalog_error_reason(
        catalog_error,
        endpoints.example_endpoint(),
      ))
  }
}
