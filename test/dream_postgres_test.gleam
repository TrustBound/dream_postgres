import architecture_snippets_test
import client_test
import deployment_guide_snippets_test
import dream_test/coverage
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import hexdocs_snippets_test
import learn_building_api_snippets_test
import query_test
import readme_snippets_test

pub fn main() {
  runner.new([
    client_test.tests(),
    query_test.tests(),
    hexdocs_snippets_test.tests(),
    readme_snippets_test.tests(),
    architecture_snippets_test.tests(),
    deployment_guide_snippets_test.tests(),
    learn_building_api_snippets_test.tests(),
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
}
