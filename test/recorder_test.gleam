//// Tests of the recorder in record and passthrough mode, against the real
//// PostgreSQL 16 server. The files that these tests record are the
//// committed files of `test/fixtures/recordings`, which the playback tests
//// play back with no database.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_postgres/recorder
import dream_postgres/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recordings
import fixtures/test_database
import fixtures/user_queries
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import snippets/recorder_scrub

@external(erlang, "recorder_ffi", "describe")
fn describe_term(term: a) -> String

@external(erlang, "recorder_ffi", "unsafe_value")
fn unsafe_value(term: a) -> pog.Value

pub fn tests() -> TestSuite {
  describe("recorder with a database", [
    record_tests(),
    record_failure_tests(),
    passthrough_tests(),
    scrub_tests(),
  ])
}

fn record_tests() {
  group("record mode", [
    it("gives each query its live result", fn() {
      // Act
      let results = {
        use directory <- recordings.with_directory()
        record(directory, "users", user_queries.scenario).0
      }

      // Assert
      results
      |> should
      |> be_equal(user_queries.scenario_results)
      |> or_fail_with("Expected the live results")
    }),
    it("writes the committed users.json", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _recorded = record(directory, "users", user_queries.scenario)
        recordings.read(directory <> "/users.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recordings.read(recordings.fixtures <> "/users.json"))
      |> or_fail_with("Expected the committed recording")
    }),
    it("records the queries in pog.transaction as transaction.json", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _recorded =
          record(directory, "transaction", user_queries.transaction_scenario)
        recordings.read(directory <> "/transaction.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recordings.read(recordings.fixtures <> "/transaction.json"))
      |> or_fail_with("Expected the committed recording")
    }),
    it("a query returns only when its recording is on disk", fn() {
      // Act
      let recorded = {
        use directory <- recordings.with_directory()
        let path = directory <> "/on_disk.json"
        record(directory, "on_disk", fn(db) {
          let _created = user_queries.create_table(db)
          // Read the file before anything else runs
          recording.from_json(recordings.read(path))
          |> result.map(list.length)
        }).0
      }

      // Assert
      recorded
      |> should
      |> be_equal(Ok(1))
      |> or_fail_with("Expected the query in the file when it returned")
    }),
    it("start writes a file with no queries, over an earlier file", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _recorded = record(directory, "users", user_queries.scenario)
        let assert Ok(again) =
          recordings.start(recorder.Record, directory, "users")
        let assert Ok(Nil) = recorder.stop(again)
        recordings.read(directory <> "/users.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recording.to_json([]))
      |> or_fail_with("Expected a recording with no queries")
    }),
    it("stop gives Ok(Nil) when every query was recorded", fn() {
      // Act
      let stopped = {
        use directory <- recordings.with_directory()
        record(directory, "users", user_queries.scenario).1
      }

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
  ])
}

fn record(
  directory: String,
  name: String,
  run: fn(pog.Connection) -> a,
) -> #(a, Result(Nil, String)) {
  recordings.record_in_schema(recordings.builder(directory, name), run)
}

fn record_failure_tests() {
  group("record mode when a query cannot be recorded", [
    it("a query fails with WriteFailed when the file cannot be written", fn() {
      // Act
      let #(failed, expected) = {
        use directory <- recordings.with_directory()
        let #(count, _stopped) = read_only_after_start(directory)
        #(
          result.map_error(count, recorder.error),
          Error(
            Ok(recorder.WriteFailed(
              path: directory <> "/locked.json",
              reason: "permission denied",
            )),
          ),
        )
      }

      // Assert
      failed
      |> should
      |> be_equal(expected)
      |> or_fail_with("Expected the WriteFailed error")
    }),
    it("stop gives Ok(Nil) after a write failed its query", fn() {
      // Act
      let stopped = {
        use directory <- recordings.with_directory()
        let #(_count, stopped) = read_only_after_start(directory)
        stopped
      }

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
    it("a query after stop fails with RecorderStopped", fn() {
      // Act
      let answered = {
        use directory <- recordings.with_directory()
        use <- test_database.with_own_pools()
        let assert Ok(recording) =
          recordings.start(recorder.Record, directory, "late")
        let assert Ok(db) = recorder.connect(recording, test_database.config())
        let assert Ok(Nil) = recorder.stop(recording)
        postgres.check(db) |> result.map_error(recorder.error)
      }

      // Assert
      answered
      |> should
      |> be_equal(Error(Ok(recorder.RecorderStopped(sql: "SELECT 1"))))
      |> or_fail_with("Expected the RecorderStopped error")
    }),
    it("a parameter that cannot be recorded fails the query", fn() {
      // Arrange
      let pid = process.self()

      // Act
      let selected = {
        use directory <- recordings.with_directory()
        record(directory, "pid", fn(db) {
          pog.query("SELECT $1::text")
          |> pog.parameter(unsafe_value(pid))
          |> pog.execute(db)
          |> result.map_error(recorder.error)
        }).0
      }

      // Assert
      selected
      |> should
      |> be_equal(
        Error(
          Ok(recorder.NotRecordable(
            sql: "SELECT $1::text",
            reason: "A parameter cannot be recorded: " <> describe_term(pid),
          )),
        ),
      )
      |> or_fail_with("Expected the NotRecordable error")
    }),
  ])
}

// Starts a recorder, makes its directory read-only, runs two queries, and
// gives the result of the first and the result of `stop`.
fn read_only_after_start(
  directory: String,
) -> #(Result(Int, pog.QueryError), Result(Nil, String)) {
  let result =
    record(directory, "locked", fn(db) {
      recordings.make_read_only(directory)
      let count = count_tables(db)
      let _again = count_tables(db)
      count
    })
  recordings.make_writable(directory)
  result
}

fn count_tables(db: pog.Connection) -> Result(Int, pog.QueryError) {
  pog.query(
    "SELECT count(*)::int FROM pg_tables WHERE schemaname = current_schema()",
  )
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { list.fold(returned.rows, 0, fn(_, row) { row }) })
}

fn passthrough_tests() {
  group("passthrough mode", [
    it("runs each query on the database", fn() {
      // Act
      let names = {
        use directory <- recordings.with_directory()
        passthrough(directory, fn(db) {
          let assert Ok(_created) = user_queries.create_table(db)
          let assert Ok(_id) = user_queries.insert_user(db, "Ada")
          user_queries.user_names(db)
        })
      }

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada"]))
      |> or_fail_with("Expected the live names")
    }),
    it("writes no file", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _names = passthrough(directory, user_queries.user_names)
        recordings.read(directory <> "/passthrough.json")
      }

      // Assert
      file
      |> should
      |> be_equal("")
      |> or_fail_with("Expected no file")
    }),
  ])
}

// Runs `run` on a connection of a passthrough recorder, in a new schema.
fn passthrough(directory: String, run: fn(pog.Connection) -> a) -> a {
  recordings.in_schema(
    recordings.builder(directory, "passthrough"),
    recorder.Passthrough,
    run,
  ).0
}

fn scrub_tests() {
  group("scrubbing", [
    it("writes the committed scrubbed.json, with no secret in it", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _recorded =
          recordings.record_in_schema(
            recorder_scrub.scrubbing_builder(directory, "scrubbed"),
            scrub_scenario,
          )
        recordings.read(directory <> "/scrubbed.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recordings.read(recordings.fixtures <> "/scrubbed.json"))
      |> or_fail_with("Expected the committed recording")
    }),
    it("gives each query its live result, with the secret", fn() {
      // Act
      let tokens = {
        use directory <- recordings.with_directory()
        recordings.record_in_schema(
          recorder_scrub.scrubbing_builder(directory, "scrubbed"),
          scrub_scenario,
        ).0
      }

      // Assert
      tokens
      |> should
      |> be_equal(Ok(["s3cret-token"]))
      |> or_fail_with("Expected the live token")
    }),
  ])
}

/// The queries of `scrubbed.json`.
pub fn scrub_scenario(
  db: pog.Connection,
) -> Result(List(String), pog.QueryError) {
  let assert Ok(_created) =
    pog.query("CREATE TABLE sessions (user_name text, token text)")
    |> pog.execute(db)
  let assert Ok(_inserted) =
    pog.query("INSERT INTO sessions (user_name, token) VALUES ($1, $2)")
    |> pog.parameter(pog.text("ada"))
    |> pog.parameter(pog.text("s3cret-token"))
    |> pog.execute(db)
  recorder_scrub.find_tokens(db, "ada")
}
