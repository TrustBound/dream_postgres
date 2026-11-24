//// Tests of the recorder that need no database: playback of the committed
//// recordings of `test/fixtures/recordings`, the errors of `start`, the
//// keys, and the file format. `recorder_playback_main` runs them alone,
//// with both test servers stopped.

import dream_postgres/recorder
import dream_postgres/recording.{
  Array, Atom, Boolean, Bytes, Failed, Integer, Map, Null, Real, RecordedQuery,
  Recording, Returned, Text, Tuple,
}
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recordings
import fixtures/user_queries
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import snippets/recorder_scrub

@external(erlang, "recorder_ffi", "describe")
fn describe_term(term: a) -> String

@external(erlang, "recorder_ffi", "unsafe_value")
fn unsafe_value(term: a) -> dream_postgres_client.Value

@external(erlang, "recorder_ffi", "unsafe_value")
fn any_to_dynamic(term: a) -> dynamic.Dynamic

pub fn tests() -> TestSuite {
  describe("recorder with no database", [
    playback_tests(),
    no_connection_tests(),
    miss_tests(),
    nearest_tests(),
    error_tests(),
    transaction_tests(),
    scrub_tests(),
    parse_mode_tests(),
    start_error_tests(),
    stop_tests(),
    key_tests(),
    file_format_tests(),
  ])
}

fn users() -> recorder.RecorderBuilder {
  recordings.builder(recordings.fixtures, "users")
}

fn playback_tests() {
  group("playback mode", [
    it("gives each query of users.json its recorded result", fn() {
      // Act
      let results = recordings.play(users(), user_queries.scenario)

      // Assert
      results
      |> should
      |> be_equal(user_queries.scenario_results)
      |> or_fail_with("Expected the results of the live run")
    }),
    it("matching wins over order: a later query can run first", fn() {
      // Act
      let names = recordings.play(users(), user_queries.user_names)

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada"]))
      |> or_fail_with("Expected the recorded names")
    }),
    it("the same query gets its recordings in recorded order", fn() {
      // Act
      let counts =
        recordings.play(users(), fn(db) {
          [user_queries.count_users(db), user_queries.count_users(db)]
        })

      // Assert
      counts
      |> should
      |> be_equal([Ok(1), Ok(2)])
      |> or_fail_with("Expected 1, then 2")
    }),
    it("gives a recorded error", fn() {
      // Act
      let inserted =
        recordings.play(users(), fn(db) {
          let _first = user_queries.insert_user(db, "Ada")
          user_queries.insert_user(db, "Ada")
        })

      // Assert
      inserted
      |> should
      |> be_equal(
        Error(dream_postgres_client.ConstraintViolated(
          message: "duplicate key value violates unique constraint \"users_name_key\"",
          constraint: "users_name_key",
          detail: "Key (name)=(Ada) already exists.",
        )),
      )
      |> or_fail_with("Expected the recorded error")
    }),
    it("gives 0 as the row count of a command with no row count", fn() {
      // Act
      let created = recordings.play(users(), user_queries.create_table)

      // Assert
      result.map(created, fn(returned) { returned.count })
      |> should
      |> be_equal(Ok(0))
      |> or_fail_with("Expected the count 0 of CREATE TABLE")
    }),
  ])
}

fn no_connection_tests() {
  group("playback mode opens no connection", [
    it("starts no pool under the name of the config", fn() {
      // Arrange
      let config = recordings.unreachable_config()

      // Act
      let registered = {
        let assert Ok(playback) =
          recorder.start(users() |> recorder.mode(recorder.Playback))
        let assert Ok(db) = recorder.connect(playback, config)
        let _names = user_queries.user_names(db)
        let assert Ok(Nil) = recorder.stop(playback)
        recordings.is_registered(config.pool_name)
      }

      // Assert
      registered
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected no process under the pool name")
    }),
    it("answers when nothing listens at the port of the config", fn() {
      // Act
      let names = recordings.play(users(), user_queries.user_names)

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada"]))
      |> or_fail_with("Expected the recorded names")
    }),
  ])
}

const insert_sql = "INSERT INTO users (name) VALUES ($1) RETURNING id"

const share_token_sql = "SELECT share_token FROM tasks WHERE id = $1"

const owner_sql = "SELECT share_token FROM tasks WHERE id = $1 AND owner = $2"

fn nearest() -> recorder.RecorderBuilder {
  recordings.builder(recordings.fixtures, "nearest")
}

/// Runs `sql` with the parameters on a playback connection of `builder`,
/// and gives the recorder's error.
fn miss(
  builder: recorder.RecorderBuilder,
  sql: String,
  parameters: List(dream_postgres_client.Value),
) -> Result(recorder.RecorderError, Nil) {
  recordings.play(builder, fn(db) {
    list.fold(parameters, dream_postgres_client.query(sql), fn(query, value) {
      dream_postgres_client.parameter(query, value)
    })
    |> dream_postgres_client.execute(db)
  })
  |> fn(executed) {
    case executed {
      Ok(_returned) -> Error(Nil)
      Error(query_error) -> recorder.error(query_error)
    }
  }
}

fn nearest_tests() {
  group("the nearest recordings of a miss", [
    it("a changed parameter shows the parameter diff", fn() {
      // Act
      let text =
        miss(nearest(), share_token_sql, [dream_postgres_client.int(42)])
        |> result.map(recorder.describe_error)

      // Assert
      text
      |> should
      |> be_equal(Ok(
        "No recording matches SELECT share_token FROM tasks WHERE id = $1 with [42]\n"
        <> "Nearest recording in test/fixtures/recordings/nearest.json:\n"
        <> "  parameters:\n"
        <> "  - [7]\n"
        <> "  + [42]",
      ))
      |> or_fail_with("The miss should show the changed parameter")
    }),
    it("the typed error holds the nearest recording", fn() {
      // Act
      let error =
        miss(nearest(), share_token_sql, [dream_postgres_client.int(42)])

      // Assert
      error
      |> should
      |> be_equal(
        Ok(
          recorder.NoRecording(
            sql: share_token_sql,
            parameters: "[42]",
            path: "test/fixtures/recordings/nearest.json",
            nearest: [
              recorder.NearestRecording(
                position: 1,
                recorded: "[7]",
                requested: "[42]",
              ),
            ],
          ),
        ),
      )
      |> or_fail_with("The miss should hold the nearest recording")
    }),
    it("orders the candidates nearest first, at most three", fn() {
      // Act
      let positions =
        miss(nearest(), owner_sql, [
          dream_postgres_client.int(42),
          dream_postgres_client.text("ada"),
        ])
        |> result.map(nearest_positions)

      // Assert
      positions
      |> should
      |> be_equal(Ok([3, 5, 2]))
      |> or_fail_with("Fewest changed parameters first, then file order")
    }),
    it("shows each candidate in the text", fn() {
      // Act
      let text =
        miss(nearest(), owner_sql, [
          dream_postgres_client.int(42),
          dream_postgres_client.text("ada"),
        ])
        |> result.map(recorder.describe_error)

      // Assert
      text
      |> should
      |> be_equal(Ok(
        "No recording matches SELECT share_token FROM tasks WHERE id = $1 AND owner = $2 with [42,\"ada\"]\n"
        <> "Nearest recording in test/fixtures/recordings/nearest.json:\n"
        <> "  parameters:\n"
        <> "  - [7,\"ada\"]\n"
        <> "  + [42,\"ada\"]\n"
        <> "Next nearest recording in test/fixtures/recordings/nearest.json:\n"
        <> "  parameters:\n"
        <> "  - [6,\"ada\"]\n"
        <> "  + [42,\"ada\"]\n"
        <> "Next nearest recording in test/fixtures/recordings/nearest.json:\n"
        <> "  parameters:\n"
        <> "  - [9,\"bob\"]\n"
        <> "  + [42,\"ada\"]",
      ))
      |> or_fail_with("Each candidate should show its parameters")
    }),
    it("a parameter list of another length counts each extra value", fn() {
      // Act
      let positions =
        miss(nearest(), owner_sql, [
          dream_postgres_client.int(5),
          dream_postgres_client.text("cy"),
          dream_postgres_client.int(4),
        ])
        |> result.map(nearest_positions)

      // Assert
      positions
      |> should
      |> be_equal(Ok([7, 2, 3]))
      |> or_fail_with("The recording with three values is nearest")
    }),
    it("with no recording of the SQL, names the file it searched", fn() {
      // Act
      let text =
        miss(nearest(), "SELECT title FROM tasks WHERE id = $1", [
          dream_postgres_client.int(42),
        ])
        |> result.map(recorder.describe_error)

      // Assert
      text
      |> should
      |> be_equal(Ok(
        "No recording matches SELECT title FROM tasks WHERE id = $1 with [42]\n"
        <> "No recording in test/fixtures/recordings/nearest.json has this SQL",
      ))
      |> or_fail_with("The miss should name the file it searched")
    }),
    it("compares the SQL as the key does", fn() {
      // Act
      let positions =
        miss(
          nearest() |> recorder.key(recorder.normalized_sql_and_parameters),
          "SELECT  share_token\nFROM tasks WHERE id = $1",
          [dream_postgres_client.int(42)],
        )
        |> result.map(nearest_positions)

      // Assert
      positions
      |> should
      |> be_equal(Ok([1]))
      |> or_fail_with("A key that ignores whitespace finds the recording")
    }),
    it("shows a parameter after the query transformer", fn() {
      // Act
      let text =
        miss(
          recorder_scrub.scrubbing_builder(recordings.fixtures, "scrubbed"),
          "INSERT INTO sessions (user_name, token) VALUES ($1, $2)",
          [
            dream_postgres_client.text("grace"),
            dream_postgres_client.text("s3cret"),
          ],
        )
        |> result.map(recorder.describe_error)

      // Assert
      text
      |> should
      |> be_equal(Ok(
        "No recording matches INSERT INTO sessions (user_name, token) VALUES ($1, $2) with [\"grace\",\"[hidden]\"]\n"
        <> "Nearest recording in test/fixtures/recordings/scrubbed.json:\n"
        <> "  parameters:\n"
        <> "  - [\"ada\",\"[hidden]\"]\n"
        <> "  + [\"grace\",\"[hidden]\"]",
      ))
      |> or_fail_with("The miss should show the hidden parameter")
    }),
    it("never shows a value that the query transformer removes", fn() {
      // Act
      let has_secret =
        miss(
          recorder_scrub.scrubbing_builder(recordings.fixtures, "scrubbed"),
          "INSERT INTO sessions (user_name, token) VALUES ($1, $2)",
          [
            dream_postgres_client.text("grace"),
            dream_postgres_client.text("s3cret"),
          ],
        )
        |> result.map(recorder.describe_error)
        |> result.map(string.contains(_, "s3cret"))

      // Assert
      has_secret
      |> should
      |> be_equal(Ok(False))
      |> or_fail_with("A hidden secret must not show")
    }),
    it("describes a query that was played already", fn() {
      // Act
      let text =
        recordings.play(users(), fn(db) {
          let _first = user_queries.insert_user(db, "Grace")
          user_queries.insert_user(db, "Grace")
          |> result.map_error(recorder.error)
        })
        |> result.map_error(result.map(_, recorder.describe_error))

      // Assert
      text
      |> should
      |> be_equal(
        Error(Ok(
          "Each recording of INSERT INTO users (name) VALUES ($1) RETURNING id with [\"Grace\"] in test/fixtures/recordings/users.json was played already",
        )),
      )
      |> or_fail_with("The text should say the recording was used")
    }),
    it("describes a write that failed", fn() {
      // Act
      let text =
        recorder.describe_error(recorder.WriteFailed(
          path: "test/recordings/tasks.json",
          reason: "permission denied",
        ))

      // Assert
      text
      |> should
      |> be_equal(
        "Could not write test/recordings/tasks.json: permission denied",
      )
      |> or_fail_with("The text should name the file and the reason")
    }),
    it("describes a query that cannot be recorded", fn() {
      // Act
      let text =
        recorder.describe_error(recorder.NotRecordable(
          sql: "SELECT $1::text",
          reason: "A parameter cannot be recorded: <0.1.0>",
        ))

      // Assert
      text
      |> should
      |> be_equal(
        "Cannot record SELECT $1::text: A parameter cannot be recorded: <0.1.0>",
      )
      |> or_fail_with("The text should name the query and the reason")
    }),
    it("describes a stopped recorder", fn() {
      // Act
      let text =
        recorder.describe_error(recorder.RecorderStopped(sql: "SELECT 1"))

      // Assert
      text
      |> should
      |> be_equal("The recorder stopped before SELECT 1")
      |> or_fail_with("The text should name the query")
    }),
  ])
}

fn nearest_positions(error: recorder.RecorderError) -> List(Int) {
  case error {
    recorder.NoRecording(nearest:, ..) ->
      list.map(nearest, fn(candidate) { candidate.position })
    _ -> []
  }
}

fn miss_tests() {
  group("a query with no recording", [
    it("gives the NoRecording error that names the query", fn() {
      // Act
      let inserted =
        recordings.play(users(), fn(db) {
          user_queries.insert_user(db, "Linus")
          |> result.map_error(recorder.error)
        })

      // Assert
      inserted
      |> should
      |> be_equal(
        Error(
          Ok(
            recorder.NoRecording(
              sql: insert_sql,
              parameters: "[\"Linus\"]",
              path: "test/fixtures/recordings/users.json",
              nearest: [
                recorder.NearestRecording(
                  position: 2,
                  recorded: "[\"Ada\"]",
                  requested: "[\"Linus\"]",
                ),
                recorder.NearestRecording(
                  position: 6,
                  recorded: "[\"Grace\"]",
                  requested: "[\"Linus\"]",
                ),
              ],
            ),
          ),
        ),
      )
      |> or_fail_with("Expected the NoRecording error")
    }),
    it("gives the PlayedAlready error when each recording was played", fn() {
      // Act
      let inserted =
        recordings.play(users(), fn(db) {
          let _first = user_queries.insert_user(db, "Grace")
          user_queries.insert_user(db, "Grace")
          |> result.map_error(recorder.error)
        })

      // Assert
      inserted
      |> should
      |> be_equal(
        Error(
          Ok(recorder.PlayedAlready(
            sql: insert_sql,
            parameters: "[\"Grace\"]",
            path: "test/fixtures/recordings/users.json",
          )),
        ),
      )
      |> or_fail_with("Expected the PlayedAlready error")
    }),
    it("gives the NotRecordable error for a parameter it cannot read", fn() {
      // Arrange
      let pid = process.self()

      // Act
      let selected =
        recordings.play(users(), fn(db) {
          dream_postgres_client.query("SELECT $1::text")
          |> dream_postgres_client.parameter(unsafe_value(pid))
          |> dream_postgres_client.execute(db)
          |> result.map_error(recorder.error)
        })

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
    it("gives the NotRecordable error for a list or a map it cannot read", fn() {
      // Arrange
      let pid = process.self()

      // Act
      let selected =
        list.map(
          [unsafe_value([pid]), unsafe_value(dict.from_list([#(1, pid)]))],
          fn(value) {
            recordings.play(users(), fn(db) {
              dream_postgres_client.query("SELECT $1")
              |> dream_postgres_client.parameter(value)
              |> dream_postgres_client.execute(db)
              |> result.replace(Nil)
              |> result.map_error(recorder.error)
            })
          },
        )

      // Assert
      selected
      |> should
      |> be_equal(list.repeat(
        Error(
          Ok(recorder.NotRecordable(
            sql: "SELECT $1",
            reason: "A parameter cannot be recorded: " <> describe_term(pid),
          )),
        ),
        2,
      ))
      |> or_fail_with("Expected the NotRecordable error for each")
    }),
    it("gives the RecorderStopped error after the recorder stopped", fn() {
      // Act
      let names = {
        let assert Ok(playback) =
          recorder.start(users() |> recorder.mode(recorder.Playback))
        let assert Ok(db) =
          recorder.connect(playback, recordings.unreachable_config())
        let assert Ok(Nil) = recorder.stop(playback)
        user_queries.user_names(db) |> result.map_error(recorder.error)
      }

      // Assert
      names
      |> should
      |> be_equal(
        Error(
          Ok(recorder.RecorderStopped(sql: "SELECT name FROM users ORDER BY id")),
        ),
      )
      |> or_fail_with("Expected the RecorderStopped error")
    }),
  ])
}

fn error_tests() {
  group("error", [
    it("gives Error(Nil) for a PostgresqlError", fn() {
      // Act
      let read =
        recorder.error(dream_postgres_client.PostgresqlError(
          code: "42601",
          name: "syntax_error",
          message: "syntax error",
        ))

      // Assert
      read
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil)")
    }),
    it(
      "gives Error(Nil) for the InterceptorFailed of another interceptor",
      fn() {
        // Act
        let read =
          recorder.error(
            dream_postgres_client.InterceptorFailed(dynamic.string(
              "no_recording",
            )),
          )

        // Assert
        read
        |> should
        |> be_equal(Error(Nil))
        |> or_fail_with("Expected Error(Nil)")
      },
    ),
    it(
      "gives Error(Nil) for a value with the tag of the recorder and another shape",
      fn() {
        // Arrange
        let reason =
          any_to_dynamic(#(
            atom.create("dream_postgres_recorder_error"),
            #(atom.create("no_recording"), 1, 2, 3),
          ))

        // Act
        let read =
          recorder.error(dream_postgres_client.InterceptorFailed(reason))

        // Assert
        read
        |> should
        |> be_equal(Error(Nil))
        |> or_fail_with("Expected Error(Nil)")
      },
    ),
  ])
}

fn transaction_tests() {
  group("dream_postgres_client.transaction in playback mode", [
    it("gives each query of transaction.json its recorded result", fn() {
      // Act
      let results =
        recordings.play(
          recordings.builder(recordings.fixtures, "transaction"),
          user_queries.transaction_scenario,
        )

      // Assert
      results
      |> should
      |> be_equal([
        "Ok(Returned(0, []))",
        "Error(TransactionRolledBack(ConstraintViolated(\"duplicate key value violates unique constraint \\\"users_name_key\\\"\", \"users_name_key\", \"Key (name)=(Ada) already exists.\")))",
        "Ok(0)",
        "Ok(#(3, 4))",
        "Ok([\"Ada\", \"Grace\"])",
      ])
      |> or_fail_with("Expected the results of the live run")
    }),
  ])
}

fn scrub_tests() {
  group("scrubbing", [
    it("scrubbed.json holds no secret", fn() {
      // Act
      let holds_secret =
        recordings.read(recordings.fixtures <> "/scrubbed.json")
        |> string.contains("s3cret")

      // Assert
      holds_secret
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected no secret in the file")
    }),
    it("an INSERT with the real secret matches its hidden recording", fn() {
      // Act
      let inserted =
        recordings.play(
          recorder_scrub.scrubbing_builder(recordings.fixtures, "scrubbed"),
          fn(db) {
            dream_postgres_client.query(
              "INSERT INTO sessions (user_name, token) VALUES ($1, $2)",
            )
            |> dream_postgres_client.parameter(dream_postgres_client.text("ada"))
            |> dream_postgres_client.parameter(dream_postgres_client.text(
              "s3cret-token",
            ))
            |> dream_postgres_client.execute(db)
            |> result.map(fn(returned) { returned.count })
          },
        )

      // Assert
      inserted
      |> should
      |> be_equal(Ok(1))
      |> or_fail_with("Expected the recorded count")
    }),
    it("playback gives the hidden rows", fn() {
      // Act
      let tokens =
        recordings.play(
          recorder_scrub.scrubbing_builder(recordings.fixtures, "scrubbed"),
          fn(db) { recorder_scrub.find_tokens(db, "ada") },
        )

      // Assert
      tokens
      |> should
      |> be_equal(Ok(["[hidden]"]))
      |> or_fail_with("Expected the hidden token")
    }),
  ])
}

fn parse_mode_tests() {
  group("parse_mode", [
    it("reads record as Record", fn() {
      // Act
      let parsed = recorder.parse_mode("record")

      // Assert
      parsed
      |> should
      |> be_equal(Ok(recorder.Record))
      |> or_fail_with("Expected Record")
    }),
    it("reads playback as Playback", fn() {
      // Act
      let parsed = recorder.parse_mode("playback")

      // Assert
      parsed
      |> should
      |> be_equal(Ok(recorder.Playback))
      |> or_fail_with("Expected Playback")
    }),
    it("reads passthrough as Passthrough", fn() {
      // Act
      let parsed = recorder.parse_mode("passthrough")

      // Assert
      parsed
      |> should
      |> be_equal(Ok(recorder.Passthrough))
      |> or_fail_with("Expected Passthrough")
    }),
    it("refuses a mode it does not know", fn() {
      // Act
      let parsed = recorder.parse_mode("replay")

      // Assert
      parsed
      |> should
      |> be_equal(Error(
        "The recorder mode \"replay\" is not known. Use \"record\", \"playback\" or \"passthrough\".",
      ))
      |> or_fail_with("Expected the mode error")
    }),
    it("refuses a mode in another case", fn() {
      // Act
      let parsed = recorder.parse_mode("Record")

      // Assert
      parsed
      |> should
      |> be_equal(Error(
        "The recorder mode \"Record\" is not known. Use \"record\", \"playback\" or \"passthrough\".",
      ))
      |> or_fail_with("Expected the mode error")
    }),
  ])
}

fn start_error_tests() {
  group("start", [
    it("starts in record mode", fn() {
      // Act
      let stopped = {
        use directory <- recordings.with_directory()
        recordings.builder(directory, "started")
        |> recorder.mode(recorder.Record)
        |> recorder.start()
        |> result.try(recorder.stop)
      }

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected a record recorder to start and stop")
    }),
    it("starts in playback mode", fn() {
      // Act
      let stopped =
        users()
        |> recorder.mode(recorder.Playback)
        |> recorder.start()
        |> result.try(recorder.stop)

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected a playback recorder to start and stop")
    }),
    it("starts in passthrough mode", fn() {
      // Act
      let stopped =
        recorder.new()
        |> recorder.mode(recorder.Passthrough)
        |> recorder.start()
        |> result.try(recorder.stop)

      // Assert
      stopped
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected a passthrough recorder to start and stop")
    }),
    it("needs a directory in record mode", fn() {
      // Act
      let started =
        recorder.new()
        |> recorder.name("users")
        |> recorder.mode(recorder.Record)
        |> recorder.start()
        |> result.replace(Nil)

      // Assert
      started
      |> should
      |> be_equal(Error(
        "The recorder needs a directory: call recorder.directory.",
      ))
      |> or_fail_with("Expected the directory error")
    }),
    it("needs a name in playback mode", fn() {
      // Act
      let started =
        recorder.new()
        |> recorder.directory(recordings.fixtures)
        |> recorder.mode(recorder.Playback)
        |> recorder.start()
        |> result.replace(Nil)

      // Assert
      started
      |> should
      |> be_equal(Error("The recorder needs a name: call recorder.name."))
      |> or_fail_with("Expected the name error")
    }),
    it("refuses a name that is not one file in the directory", fn() {
      // Act
      let started =
        list.map(["", "../users", ".hidden", "a/b", "a b"], fn(name) {
          recordings.builder(recordings.fixtures, name)
          |> recorder.mode(recorder.Playback)
          |> recorder.start()
          |> result.replace(Nil)
        })

      // Assert
      started
      |> should
      |> be_equal(
        list.map(["", "../users", ".hidden", "a/b", "a b"], fn(name) {
          Error(
            "The recording name "
            <> string.inspect(name)
            <> " is not valid. Use letters, digits, _, - and ., and do not start with a dot.",
          )
        }),
      )
      |> or_fail_with("Expected the name error for each name")
    }),
    it(
      "gives the file error in playback mode for a file that is not there",
      fn() {
        // Act
        let started =
          recordings.builder(recordings.fixtures, "missing")
          |> recorder.mode(recorder.Playback)
          |> recorder.start()
          |> result.replace(Nil)

        // Assert
        started
        |> should
        |> be_equal(Error(
          "test/fixtures/recordings/missing.json: no such file or directory",
        ))
        |> or_fail_with("Expected the file error")
      },
    ),
    it(
      "gives the format error in playback mode for a file that is not a recording",
      fn() {
        // Act
        let started = {
          use directory <- recordings.with_directory()
          let assert Ok(written) =
            recordings.start(recorder.Record, directory, "x")
          let assert Ok(Nil) = recorder.stop(written)
          recordings.write(directory <> "/x.json", "{\"version\": 1}")
          recordings.start(recorder.Playback, directory, "x")
          |> result.map_error(string.replace(_, directory, "<directory>"))
          |> result.replace(Nil)
        }

        // Assert
        started
        |> should
        |> be_equal(Error(
          "<directory>/x.json: This is not a recording file: UnableToDecode([DecodeError(\"Field\", \"Nothing\", [\"format\"]), DecodeError(\"Field\", \"Nothing\", [\"queries\"]), DecodeError(\"the format dream_postgres query recording\", \"Dict\", [])])",
        ))
        |> or_fail_with("Expected the format error")
      },
    ),
    it(
      "gives the write error in record mode for a directory it cannot make",
      fn() {
        // Act
        let started =
          recordings.builder("README.md/recordings", "x")
          |> recorder.mode(recorder.Record)
          |> recorder.start()
          |> result.replace(Nil)

        // Assert
        started
        |> should
        |> be_equal(Error("README.md/recordings/x.json: not a directory"))
        |> or_fail_with("Expected the write error")
      },
    ),
    it("passthrough needs no directory and no name", fn() {
      // Act
      let started =
        recorder.new() |> recorder.start() |> result.try(recorder.stop)

      // Assert
      started
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
  ])
}

fn stop_tests() {
  group("stop", [
    it("gives an error the second time", fn() {
      // Act
      let stopped = {
        let assert Ok(playback) =
          recorder.start(users() |> recorder.mode(recorder.Playback))
        let assert Ok(Nil) = recorder.stop(playback)
        recorder.stop(playback)
      }

      // Assert
      stopped
      |> should
      |> be_equal(Error("The recorder had stopped already."))
      |> or_fail_with("Expected the stopped error")
    }),
  ])
}

const lookup =
  RecordedQuery(
    sql: "SELECT name\n  FROM users\n  WHERE name = 'a  b' AND id = $1 ",
    parameters: [Integer(1)],
  )

fn key_tests() {
  group("keys", [
    it("sql_and_parameters keeps the SQL as it is", fn() {
      // Act
      let key = recorder.sql_and_parameters(lookup)

      // Assert
      key
      |> should
      |> be_equal(
        "SELECT name\n  FROM users\n  WHERE name = 'a  b' AND id = $1 \n[1]",
      )
      |> or_fail_with("Expected the SQL and the parameters")
    }),
    it(
      "normalized_sql_and_parameters makes whitespace outside quotes one space",
      fn() {
        // Act
        let key = recorder.normalized_sql_and_parameters(lookup)

        // Assert
        key
        |> should
        |> be_equal(
          "SELECT name FROM users WHERE name = 'a  b' AND id = $1\n[1]",
        )
        |> or_fail_with("Expected the normalized SQL and the parameters")
      },
    ),
    it("normalized_sql_and_parameters keeps a quote inside quotes", fn() {
      // Act
      let key =
        recorder.normalized_sql_and_parameters(
          RecordedQuery(sql: "SELECT  'it''s  here',  \"a  b\"", parameters: []),
        )

      // Assert
      key
      |> should
      |> be_equal("SELECT 'it''s  here', \"a  b\"\n[]")
      |> or_fail_with("Expected the quoted text unchanged")
    }),
    it("sql_only keeps only the SQL", fn() {
      // Act
      let key = recorder.sql_only(lookup)

      // Assert
      key
      |> should
      |> be_equal(
        "SELECT name\n  FROM users\n  WHERE name = 'a  b' AND id = $1 ",
      )
      |> or_fail_with("Expected the SQL")
    }),
    it("a custom key matches queries the way it says", fn() {
      // Act
      let id =
        recordings.play(users() |> recorder.key(recorder.sql_only), fn(db) {
          user_queries.insert_user(db, "Someone else")
        })

      // Assert
      id
      |> should
      |> be_equal(Ok(1))
      |> or_fail_with("Expected the first recorded INSERT")
    }),
  ])
}

fn file_format_tests() {
  group("the file format", [
    it("to_json writes each kind of value", fn() {
      // Act
      let text =
        recording.to_json([
          Recording(
            RecordedQuery("SELECT $1", [
              Null,
              Boolean(True),
              Integer(-3),
              Real(1.0e30),
              Real(0.5),
              Text("é\"\n"),
              Bytes(<<0, 255>>),
              Bytes(<<5:size(3)>>),
              Array([Integer(1), Null]),
              Tuple([Integer(2026), Integer(11), Integer(23)]),
              Map([#(Atom("x"), Real(1.0))]),
              Atom("infinity"),
            ]),
            Returned(0, []),
          ),
        ])

      // Assert
      text
      |> should
      |> be_equal(
        "{\n  \"format\": \"dream_postgres query recording\",\n  \"version\": 1,\n  \"queries\": [\n    {\n      \"sql\": \"SELECT $1\",\n      \"parameters\": [null,true,-3,1.0e30,0.5,\"é\\\"\\n\",{\"bytes\":\"00FF\"},{\"bits\":{\"size\":3,\"hex\":\"A0\"}},[1,null],{\"tuple\":[2026,11,23]},{\"map\":[[{\"atom\":\"x\"},1.0]]},{\"atom\":\"infinity\"}],\n      \"result\": {\n        \"count\": 0,\n        \"rows\": []\n      }\n    }\n  ]\n}\n",
      )
      |> or_fail_with("Expected the text of the file")
    }),
    it("from_json reads back each kind of value", fn() {
      // Arrange
      let recorded = [
        Recording(
          RecordedQuery("SELECT $1", [
            Null,
            Boolean(False),
            Integer(9_223_372_036_854_775_807),
            Real(0.1),
            Text(""),
            Bytes(<<0, 255>>),
            Bytes(<<5:size(3)>>),
            Array([]),
            Tuple([]),
            Map([#(Text("id"), Integer(1))]),
            Atom("NaN"),
          ]),
          Returned(2, [Tuple([Text("a")])]),
        ),
      ]

      // Act
      let read = recording.from_json(recording.to_json(recorded))

      // Assert
      read
      |> should
      |> be_equal(Ok(recorded))
      |> or_fail_with("Expected the same recordings")
    }),
    it("from_json reads back each kind of error", fn() {
      // Arrange
      let recorded =
        list.map(
          [
            dream_postgres_client.ConstraintViolated("m", "c", "d"),
            dream_postgres_client.PostgresqlError(
              "42P01",
              "undefined_table",
              "m",
            ),
            dream_postgres_client.UnexpectedArgumentCount(expected: 1, got: 2),
            dream_postgres_client.UnexpectedArgumentType(
              expected: "int4",
              got: "\"a\"",
            ),
            dream_postgres_client.UnexpectedResultType([
              decode.DecodeError(expected: "Int", found: "String", path: ["0"]),
            ]),
            dream_postgres_client.QueryTimeout,
            dream_postgres_client.ConnectionUnavailable,
            dream_postgres_client.InterceptorFailed(
              any_to_dynamic(#(atom.create("tag"), "reason", [1, 2])),
            ),
          ],
          fn(error) { Recording(RecordedQuery("SELECT 1", []), Failed(error)) },
        )

      // Act
      let read = recording.from_json(recording.to_json(recorded))

      // Assert
      read
      |> should
      |> be_equal(Ok(recorded))
      |> or_fail_with("Expected the same errors")
    }),
    it(
      "to_json writes an InterceptorFailed reason that no value holds as its text",
      fn() {
        // Arrange
        let pid = process.self()
        let recorded = [
          Recording(
            RecordedQuery("SELECT 1", []),
            Failed(dream_postgres_client.InterceptorFailed(any_to_dynamic(pid))),
          ),
        ]

        // Act
        let read = recording.from_json(recording.to_json(recorded))

        // Assert
        read
        |> should
        |> be_equal(
          Ok([
            Recording(
              RecordedQuery("SELECT 1", []),
              Failed(
                dream_postgres_client.InterceptorFailed(
                  dynamic.string(describe_term(pid)),
                ),
              ),
            ),
          ]),
        )
        |> or_fail_with("Expected the text of the reason")
      },
    ),
    it("from_json refuses another format, another version and bad values", fn() {
      // Act
      let read =
        list.map(
          [
            "{\"format\":\"other\",\"version\":1,\"queries\":[]}",
            "{\"format\":\"dream_postgres query recording\",\"version\":2,\"queries\":[]}",
            query_with_value("{\"bytes\":\"zz\"}"),
            query_with_value("{\"bits\":{\"size\":9,\"hex\":\"A0\"}}"),
            query_with_value("{\"bits\":{\"size\":3,\"hex\":\"zz\"}}"),
            query_with_value("{\"other\":1}"),
            "{\"format\":\"dream_postgres query recording\",\"version\":1,\"queries\":[{\"sql\":\"\",\"parameters\":[],\"result\":{\"error\":\"other\"}}]}",
            "not JSON",
          ],
          fn(text) { result.is_ok(recording.from_json(text)) },
        )

      // Assert
      read
      |> should
      |> be_equal([False, False, False, False, False, False, False, False])
      |> or_fail_with("Expected an error for each text")
    }),
    it("values_to_json writes the values on one line", fn() {
      // Act
      let text = recording.values_to_json([Integer(1), Text("Ada"), Null])

      // Assert
      text
      |> should
      |> be_equal("[1,\"Ada\",null]")
      |> or_fail_with("Expected one line of JSON")
    }),
  ])
}

fn query_with_value(value: String) -> String {
  "{\"format\":\"dream_postgres query recording\",\"version\":1,\"queries\":[{\"sql\":\"\",\"parameters\":["
  <> value
  <> "],\"result\":{\"count\":0,\"rows\":[]}}]}"
}
