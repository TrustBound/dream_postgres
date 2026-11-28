//// A matcher that gives the config fault of an error of a login config.

import dream_postgres/driver/login/login_config.{type ConfigError}
import dream_postgres/error.{type ConfigFault}
import dream_postgres/query/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the config fault of an error of a login config, as the client
/// sees it.
///
/// ## Example
///
/// ```gleam
/// login.EmptyUser
/// |> should
/// |> map_login_config_fault()
/// |> be_equal(error.EmptyUser)
/// |> or_fail_with("Expected EmptyUser")
/// ```
pub fn map_login_config_fault(
  result: MatchResult(ConfigError),
) -> MatchResult(ConfigFault) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(config_error) ->
      MatchOk(driver_executor.login_config_fault(config_error))
  }
}
