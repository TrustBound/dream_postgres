import architecture_snippets_test
import client_test
import deployment_guide_snippets_test
import dream_test/coverage
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import fixtures/test_database
import gleam/io
import guide_connecting_test
import guide_getting_started_test
import guide_queries_test
import hexdocs_snippets_test
import learn_building_api_snippets_test
import postgres_server_test
import query_test
import readme_snippets_test
import snippets/guide_connecting_testing
import snippets/guide_getting_started_testing
import snippets/guide_queries_testing

@external(erlang, "database_ffi", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "database_ffi", "drop_pool_shutdown_reports")
fn drop_pool_shutdown_reports() -> Nil

// Many tests run queries on a real PostgreSQL server. When it does not
// answer, the run stops here with one message, not with a failure in each
// of those tests.
pub fn main() {
  drop_pool_shutdown_reports()
  case test_database.check_reachable() {
    Ok(Nil) -> run_tests()
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
  }
}

fn run_tests() -> Nil {
  runner.new([
    client_test.tests(),
    query_test.tests(),
    hexdocs_snippets_test.tests(),
    readme_snippets_test.tests(),
    architecture_snippets_test.tests(),
    deployment_guide_snippets_test.tests(),
    learn_building_api_snippets_test.tests(),
    guide_getting_started_test.tests(),
    guide_getting_started_testing.tests(),
    guide_connecting_test.tests(),
    guide_connecting_testing.tests(),
    guide_queries_test.tests(),
    guide_queries_testing.tests(),
    postgres_server_test.tests(),
  ])
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.coverage(
    coverage.new()
    |> coverage.show_missing()
    |> coverage.minimum_percent(100.0)
    |> coverage.json_path("build/coverage/coverage.json"),
  )
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}
