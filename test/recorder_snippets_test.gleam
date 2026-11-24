//// Tests for the snippets of the doc comments of `dream_postgres/recorder`
//// and `dream_postgres/recording`. None needs a database.

import dream_postgres/recorder
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/recordings
import gleam/dynamic/decode
import gleam/result
import snippets/guide_recording_users.{find_user}
import snippets/recorder_error
import snippets/recorder_key
import snippets/recorder_keys
import snippets/recorder_parse_mode
import snippets/recording_by_hand
import snippets/recording_read
import snippets/recording_values

pub fn tests() -> TestSuite {
  describe("recorder doc snippets", [
    it("start_from_text starts a playback recorder from its text", fn() {
      // Act
      let stopped =
        recorder_parse_mode.start_from_text(
          "playback",
          recordings.fixtures,
          "users",
        )
        |> result.try(recorder.stop)

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected a playback recorder to start and stop")
    }),
    it("start_from_text refuses a text that is not a mode", fn() {
      // Act
      let started =
        recorder_parse_mode.start_from_text(
          "replay",
          recordings.fixtures,
          "users",
        )
        |> result.replace(Nil)

      // Assert
      started
      |> should
      |> be_equal(Error(
        "The recorder mode \"replay\" is not known. Use \"record\", \"playback\" or \"passthrough\".",
      ))
      |> or_fail_with("Expected the mode error")
    }),
    it("keys gives the three keys of the query", fn() {
      // Act
      let keys = recorder_keys.keys()

      // Assert
      keys
      |> should
      |> be_equal([
        "SELECT name\n  FROM users WHERE id = $1\n[7]",
        "SELECT name FROM users WHERE id = $1\n[7]",
        "SELECT name\n  FROM users WHERE id = $1",
      ])
      |> or_fail_with("Expected the three keys")
    }),
    it("playback_ignoring_whitespace matches SQL with other line breaks", fn() {
      // Act
      let names = {
        let assert Ok(playback) =
          recorder_key.playback_ignoring_whitespace(
            recordings.fixtures,
            "create_and_find",
          )
        let assert Ok(db) =
          recorder.connect(playback, recordings.unreachable_config())
        let names =
          dream_postgres_client.query(
            "SELECT id, name, email\n  FROM users\n  WHERE id = $1",
          )
          |> dream_postgres_client.parameter(dream_postgres_client.int(1))
          |> dream_postgres_client.returning(decode.at([1], decode.string))
          |> dream_postgres_client.execute(db)
          |> result.map(fn(returned) { returned.rows })
        let assert Ok(Nil) = recorder.stop(playback)
        names
      }

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada"]))
      |> or_fail_with("Expected the recorded name")
    }),
    it("timeout_recording makes find_user time out in playback", fn() {
      // Act
      let found = {
        use directory <- recordings.with_directory()
        let assert Ok(written) =
          recordings.start(recorder.Record, directory, "timeout")
        let assert Ok(Nil) = recorder.stop(written)
        recordings.write(
          directory <> "/timeout.json",
          recording_by_hand.timeout_recording(),
        )
        recordings.play(recordings.builder(directory, "timeout"), fn(db) {
          find_user(db, 1)
        })
      }

      // Assert
      found
      |> should
      |> be_equal(Error(dream_postgres_client.QueryTimeout))
      |> or_fail_with("Expected the recorded timeout")
    }),
    it("recorded_sql reads the SQL of a recording file", fn() {
      // Act
      let sql =
        recording_read.recorded_sql(recordings.read(
          recordings.fixtures <> "/create_and_find.json",
        ))

      // Assert
      sql
      |> should
      |> be_equal(
        Ok([
          "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
          "SELECT id, name, email FROM users WHERE id = $1",
        ]),
      )
      |> or_fail_with("Expected the SQL of each query")
    }),
    it("parameters_text writes the values on one line", fn() {
      // Act
      let text = recording_values.parameters_text()

      // Assert
      text
      |> should
      |> be_equal("[1,\"Ada\",null]")
      |> or_fail_with("Expected one line of JSON")
    }),
    it("explain names the file, the SQL and the parameters of a miss", fn() {
      // Arrange
      let builder = recordings.builder(recordings.fixtures, "create_and_find")

      // Act
      let explained =
        recordings.play(builder, fn(db) {
          case find_user(db, 2) {
            Ok(_user) -> "Expected a miss"
            Error(query_error) -> recorder_error.explain(query_error)
          }
        })

      // Assert
      explained
      |> should
      |> be_equal(
        "Record again: test/fixtures/recordings/create_and_find.json has no SELECT id, name, email FROM users WHERE id = $1 with [2]",
      )
      |> or_fail_with("Expected the explanation of the miss")
    }),
    it("explain tells a database error from a recorder error", fn() {
      // Act
      let explained =
        recorder_error.explain(dream_postgres_client.PostgresqlError(
          code: "42601",
          name: "syntax_error",
          message: "syntax error",
        ))

      // Assert
      explained
      |> should
      |> be_equal("The database failed the query")
      |> or_fail_with("Expected the database explanation")
    }),
  ])
}
