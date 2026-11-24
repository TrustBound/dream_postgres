//// Recorded queries guide: Test your code
////
//// Plays back the committed recording of `create_and_find`. No database
//// runs: the URL points at a port where nothing listens.

import dream_postgres/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/guide_recording_round_trip.{run_recorded}
import snippets/guide_recording_users.{User}

const recordings = "test/fixtures/recordings"

const no_database = "postgresql://app:secret@127.0.0.1:1/app"

pub fn tests() -> TestSuite {
  describe("create_and_find", [
    it("creates Ada and finds her", fn() {
      // Act
      let user = run_recorded(recorder.Playback, no_database, recordings)

      // Assert
      user
      |> should
      |> be_equal(Ok(User(id: 1, name: "Ada", email: "ada@example.com")))
      |> or_fail_with("Expected Ada from the recording")
    }),
  ])
}
