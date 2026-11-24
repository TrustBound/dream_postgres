//// Runs only the recorder tests that need no database, with no check that
//// a test server answers. `make test-playback` runs this module with both
//// test servers stopped, to prove that playback opens no connection.

import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import guide_recording_test
import recorder_playback_test
import recorder_snippets_test
import snippets/guide_recording_testing

pub fn main() {
  runner.new([
    recorder_playback_test.tests(),
    recorder_snippets_test.tests(),
    guide_recording_test.playback_tests(),
    guide_recording_testing.tests(),
  ])
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}
