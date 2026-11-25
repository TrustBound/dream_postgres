import architecture_snippets_test
import client_model_test
import client_query_snippets_test
import client_test
import deployment_guide_snippets_test
import dream_test/coverage
import dream_test/parallel
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import fixtures/ssl_database
import fixtures/test_database
import generated_sql_test
import gleam/io
import gleam/result
import guide_connecting_test
import guide_getting_started_test
import guide_queries_test
import guide_recording_test
import hexdocs_snippets_test
import learn_building_api_snippets_test
import postgres_server_test
import postgres_ssl_test
import query_test
import readme_snippets_test
import recorder_playback_test
import recorder_snippets_test
import recorder_test
import recorder_types_test
import snippets/guide_connecting_testing
import snippets/guide_getting_started_testing
import snippets/guide_queries_testing
import snippets/guide_recording_testing

@external(erlang, "database_ffi", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "database_ffi", "drop_pool_shutdown_reports")
fn drop_pool_shutdown_reports() -> Nil

// Many tests run queries on the two real PostgreSQL servers of
// docker-compose.yml. When one does not answer, the run stops here with
// one message, not with a failure in each of those tests.
pub fn main() {
  drop_pool_shutdown_reports()
  ssl_database.drop_tls_alert_reports()
  let reachable = {
    use Nil <- result.try(test_database.check_reachable())
    ssl_database.check_reachable()
  }
  case reachable {
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
    client_query_snippets_test.tests(),
    client_model_test.tests(),
    generated_sql_test.tests(),
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
    recorder_types_test.tests(),
    recorder_test.tests(),
    recorder_playback_test.tests(),
    recorder_snippets_test.tests(),
    guide_recording_test.tests(),
    guide_recording_testing.tests(),
  ])
  // The SSL tests change the CA list of the whole BEAM, so they run one at
  // a time, after the other suites.
  |> runner.add_suites_with_config(
    parallel.ParallelConfig(max_concurrency: 1, default_timeout_ms: 30_000),
    [postgres_ssl_test.tests()],
  )
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
