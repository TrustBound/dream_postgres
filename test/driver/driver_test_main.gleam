//// Runs the driver tests alone, with the coverage gate on the driver
//// modules only: `make test-driver`. `gleam test` runs the same tests with
//// all the others.

import dream_test/coverage.{minimum_percent, show_missing, source_directory}
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import dream_test/suite.{type TestSuite}
import driver/bit_array_test
import driver/channel_binding_test
import driver/decode_test
import driver/encode_test
import driver/login_server_test
import driver/login_test
import driver/query_server_test
import driver/query_test
import driver/recorded_test
import driver/saslprep_test
import driver/scram_test
import driver/server_test
import driver/transaction_test
import driver/transport_test

/// Every suite of the driver tests, in the order they run.
pub fn suites() -> List(TestSuite) {
  [
    bit_array_test.tests(),
    encode_test.tests(),
    decode_test.tests(),
    query_test.tests(),
    transaction_test.tests(),
    recorded_test.tests(),
    saslprep_test.tests(),
    scram_test.tests(),
    channel_binding_test.tests(),
    login_test.tests(),
    login_server_test.tests(),
    query_server_test.tests(),
    server_test.tests(),
    transport_test.tests(),
  ]
}

/// Runs the driver tests, and fails below 100% line coverage of
/// `src/dream_postgres/driver`.
pub fn main() -> Nil {
  runner.new(suites())
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.coverage(
    coverage.new()
    |> source_directory("src/dream_postgres/driver")
    |> show_missing()
    |> minimum_percent(100.0),
  )
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}
