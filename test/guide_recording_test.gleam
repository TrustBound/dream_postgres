//// Tests for the snippets of the recorded queries guide
//// (docs/guides/recorded-queries.md). The "with a database" tests record
//// against the test PostgreSQL server and compare the files the recorder
//// wrote with the output files of the guide. `playback_tests` need no
//// database, and `recorder_playback_main` runs them too.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_postgres/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/guide_schema
import fixtures/output_file
import fixtures/recordings
import fixtures/test_database
import gleam/string
import recorder_test
import snippets/guide_recording_changed
import snippets/guide_recording_round_trip.{create_and_find, run_recorded}
import snippets/guide_recording_setup.{connect, start_recorder}
import snippets/guide_recording_users.{create_user, find_user}
import snippets/recorder_scrub

const no_database = "postgresql://app:secret@127.0.0.1:1/app"

pub fn tests() -> TestSuite {
  describe("recorded queries guide", [with_database_tests(), playback_group()])
}

/// The tests of the guide that need no database.
pub fn playback_tests() -> TestSuite {
  describe("recorded queries guide", [playback_group()])
}

fn with_database_tests() {
  group("with a database", [
    it(
      "step 3: run_recorded in record mode answers as the output file shows",
      fn() {
        // Act
        let user = {
          use directory <- recordings.with_directory()
          use url <- guide_schema.with_users_url()
          run_recorded("record", url, directory)
        }

        // Assert
        output_file.calls([
          #(
            "run_recorded(\"record\", database_url, \"test/fixtures/recordings\")",
            string.inspect(user),
          ),
        ])
        |> should
        |> be_equal(output_file.read("guide_recording_record"))
        |> or_fail_with("Expected the output file")
      },
    ),
    it("step 3: the recorder writes the file of the output file", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        use url <- guide_schema.with_users_url()
        let _user = run_recorded("record", url, directory)
        recordings.read(directory <> "/create_and_find.json")
      }

      // Assert
      file
      |> should
      |> be_equal(output_file.read("guide_recording_file"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 3: the committed recording is the file the recorder writes", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        use url <- guide_schema.with_users_url()
        let _user = run_recorded("record", url, directory)
        recordings.read(directory <> "/create_and_find.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recordings.read(
        recordings.fixtures <> "/create_and_find.json",
      ))
      |> or_fail_with("Expected the committed recording")
    }),
    it(
      "step 6: the scrubbing recorder writes the file of the output file",
      fn() {
        // Act
        let file = {
          use directory <- recordings.with_directory()
          let _recorded =
            recordings.record_in_schema(
              recorder_scrub.scrubbing_builder(directory, "sessions"),
              recorder_test.scrub_scenario,
            )
          recordings.read(directory <> "/sessions.json")
        }

        // Assert
        file
        |> should
        |> be_equal(output_file.read("guide_recording_scrubbed"))
        |> or_fail_with("Expected the output file")
      },
    ),
  ])
}

fn playback_group() {
  group("with no database", [
    it("step 4: playback answers as the output file shows", fn() {
      // Act
      let played =
        run_recorded("playback", no_database, recordings.fixtures)
        |> string.inspect
      let live = {
        use <- test_database.with_own_pools()
        let assert Ok(db) =
          postgres.from_url(database_url.unused_database_url())
        create_and_find(db) |> string.inspect
      }

      // Assert
      output_file.calls([
        #(
          "run_recorded(\"playback\", \"postgresql://app:secret@127.0.0.1:1/app\", \"test/fixtures/recordings\")",
          played,
        ),
        #("create_and_find(a pool with no database)", live),
      ])
      |> should
      |> be_equal(output_file.read("guide_recording_playback"))
      |> or_fail_with("Expected the output file")
    }),
    it(
      "step 5: a query with no recording answers as the output file shows",
      fn() {
        // Act
        let missed = play(fn(db) { find_user(db, 2) |> string.inspect })

        // Assert
        output_file.calls([#("find_user(db, 2)", missed)])
        |> should
        |> be_equal(output_file.read("guide_recording_miss"))
        |> or_fail_with("Expected the output file")
      },
    ),
    it("step 7: a changed query answers as the output file shows", fn() {
      // Act
      let missed =
        play(fn(db) {
          let _created = create_user(db, "Ada", "ada@example.com")
          guide_recording_changed.find_user(db, 1) |> string.inspect
        })

      // Assert
      output_file.calls([#("find_user(db, 1)", missed)])
      |> should
      |> be_equal(output_file.read("guide_recording_changed"))
      |> or_fail_with("Expected the output file")
    }),
  ])
}

// Plays back the committed recording of create_and_find.
fn play(run: fn(pog.Connection) -> a) -> a {
  let assert Ok(recording) =
    start_recorder("playback", recordings.fixtures, "create_and_find")
  let assert Ok(db) = connect(recording, no_database)
  let value = run(db)
  let assert Ok(Nil) = recorder.stop(recording)
  value
}
