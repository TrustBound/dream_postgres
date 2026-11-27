import dream_postgres/advanced_guide_snippets_test
import dream_postgres/client_test
import dream_postgres/codec_parity_test
import dream_postgres/codec_probe_test
import dream_postgres/codec_test
import dream_postgres/composite_codecs_test
import dream_postgres/copy_stream_test
import dream_postgres/copy_test
import dream_postgres/database_url_test
import dream_postgres/driver_executor_test
import dream_postgres/error_test
import dream_postgres/geometry_range_codecs_test
import dream_postgres/guide_snippets_test
import dream_postgres/interceptor_test
import dream_postgres/json_test
import dream_postgres/listener_test
import dream_postgres/match_test
import dream_postgres/network_codecs_test
import dream_postgres/normalize_test
import dream_postgres/numeric_codec_test
import dream_postgres/pool_options_test
import dream_postgres/posix_test
import dream_postgres/query_test
import dream_postgres/reconnect_test
import dream_postgres/recorder_test
import dream_postgres/recording_test
import dream_postgres/row_reader_test
import dream_postgres/runner_test
import dream_postgres/secrets_test
import dream_postgres/sql_state_test
import dream_postgres/supervision_test
import dream_postgres/text_search_vector_codecs_test
import dream_postgres/time_codecs_test
import dream_postgres/verify_test
import dream_test/coverage.{json_path, minimum_percent, show_missing}
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner.{exit_on_failure, progress_reporter, results_reporters}
import driver/driver_test_main

pub fn main() {
  runner.new([
    sql_state_test.tests(),
    posix_test.tests(),
    error_test.tests(),
    codec_test.tests(),
    codec_parity_test.tests(),
    numeric_codec_test.tests(),
    json_test.tests(),
    time_codecs_test.tests(),
    network_codecs_test.tests(),
    geometry_range_codecs_test.tests(),
    text_search_vector_codecs_test.tests(),
    row_reader_test.tests(),
    query_test.tests(),
    database_url_test.tests(),
    composite_codecs_test.tests(),
    runner_test.tests(),
    supervision_test.tests(),
    reconnect_test.tests(),
    codec_probe_test.tests(),
    driver_executor_test.mapping_tests(),
    driver_executor_test.tests(),
    client_test.unit_tests(),
    client_test.tests(),
    interceptor_test.unit_tests(),
    interceptor_test.tests(),
    copy_stream_test.tests(),
    copy_test.tests(),
    recording_test.tests(),
    secrets_test.unit_tests(),
    secrets_test.tests(),
    match_test.tests(),
    normalize_test.tests(),
    recorder_test.tests(),
    pool_options_test.unit_tests(),
    pool_options_test.tests(),
    listener_test.mapping_tests(),
    listener_test.tests(),
    verify_test.unit_tests(),
    verify_test.tests(),
    guide_snippets_test.tests(),
    advanced_guide_snippets_test.unit_tests(),
    advanced_guide_snippets_test.tests(),
    ..driver_test_main.suites()
  ])
  |> progress_reporter(progress.new())
  |> results_reporters([bdd.new()])
  |> runner.coverage(
    coverage.new()
    |> show_missing()
    |> minimum_percent(100.0)
    |> json_path("build/coverage/coverage.json"),
  )
  |> exit_on_failure()
  |> runner.run()
}
