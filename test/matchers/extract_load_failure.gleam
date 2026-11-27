//// Extracts the driver error of a failed catalog load.

import dream_postgres/driver/catalog.{type CatalogError, LoadFailed}
import dream_postgres/driver/connection.{type RunError}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the driver error of a `LoadFailed`. Fails for another catalog
/// error.
///
/// ```gleam
/// catalog.describe(type_catalog, connection, 23, 5000)
/// |> should
/// |> be_error
/// |> extract_load_failure
/// |> extract_driver_error_code
/// |> be_equal("25P02")
/// |> or_fail_with("Expected 25P02 from the load")
/// ```
pub fn extract_load_failure(
  result: MatchResult(CatalogError),
) -> MatchResult(RunError) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> load_failure_of(error)
  }
}

fn load_failure_of(error: CatalogError) -> MatchResult(RunError) {
  case error {
    LoadFailed(driver_error) -> MatchOk(driver_error)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_load_failure",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected LoadFailed",
        )),
      ))
  }
}
