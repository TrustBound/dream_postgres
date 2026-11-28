//// The recorder: each scenario is recorded against PostgreSQL 16 once in
//// the setup, and each test plays one back on a connection whose port has
//// no server, so playback cannot reach a database.

import dream_postgres/codec
import dream_postgres/config
import dream_postgres/copy.{copy_from, copy_to, table}
import dream_postgres/error.{
  RecordingInUse, RecordingNotFound, RecordingNotRead, RecordingNotWritten,
  SecretColumnNotReplaced,
}
import dream_postgres/interceptor.{SqlAnswer, command}
import dream_postgres/normalize
import dream_postgres/pool.{with_interceptor}
import dream_postgres/posix
import dream_postgres/query.{affected, query}
import dream_postgres/recorder
import dream_postgres/row.{single}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, contain_string, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{describe, it}
import fixtures/copy_users
import fixtures/interceptors
import fixtures/recorded_scenarios.{type RecordedRuns}
import fixtures/server_pools
import fixtures/supervisors
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import matchers/be_equal_parts.{be_equal_parts}
import matchers/have_cause.{have_cause}
import matchers/have_reason.{have_reason}
import matchers/not_contain_text.{not_contain_text}
import matchers/play_back.{play_back}
import matchers/read_recording_file.{read_recording_file}
import matchers/read_recording_pair.{read_recording_pair}
import matchers/run_and_stop_supervisor.{run_and_stop_supervisor}
import matchers/run_with_recorder.{run_with_recorder}
import matchers/summarise_error.{summarise_error}
import simplifile

/// The recorder tests, with the recordings made once for all of them.
pub fn tests() -> TestSuite {
  describe(
    "recorder",
    context.setup(
      recorded_scenarios.record_all,
      teardown: recorded_scenarios.remove,
    ),
    [
      it("all replays its rows", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("all", recorded_scenarios.select_series)
        |> be_ok()
        |> be_equal("[1, 2, 3]")
        |> or_fail_with("Expected the three recorded rows")
      }),
      it(
        "the same SQL with other parameters replays its own answer",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("two_parameters", recorded_scenarios.select_two_series)
          |> be_ok()
          |> be_equal("#([1, 2], [1, 2, 3])")
          |> or_fail_with("Expected two rows, then three rows")
        },
      ),
      it(
        "one replays its row, read from an array parameter",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("one", recorded_scenarios.count_array)
          |> be_ok()
          |> be_equal("3")
          |> or_fail_with("Expected the length 3")
        },
      ),
      it("maybe_one replays no row", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("maybe_one", recorded_scenarios.select_nothing)
        |> be_ok()
        |> be_equal("None")
        |> or_fail_with("Expected no row")
      }),
      it("affected replays its row count", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("affected", recorded_scenarios.update_rows)
        |> be_ok()
        |> be_equal("3")
        |> or_fail_with("Expected 3 rows updated")
      }),
      it("a `run_sql` call replays", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("run_sql", recorded_scenarios.run_two_statements)
        |> be_ok()
        |> be_equal("Nil")
        |> or_fail_with("Expected the `run_sql` call to succeed")
      }),
      it(
        "a failed statement of a `run_sql` call replays its server error",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("run_sql_failure", recorded_scenarios.run_failing_sql)
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid SqlStatementFailed 1 22012")
          |> or_fail_with(
            "Expected the division by zero of the second statement",
          )
        },
      ),
      it(
        "a transaction replays its steps and its commit",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("transaction", recorded_scenarios.count_in_transaction)
          |> be_ok()
          |> be_equal("1")
          |> or_fail_with("Expected one row in the transaction")
        },
      ),
      it(
        "a commit after a failed statement replays its rollback",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("rolled_back", recorded_scenarios.commit_after_conflict)
          |> be_error()
          |> summarise_error()
          |> be_equal("failed CommitRolledBack 23505")
          |> or_fail_with("Expected the rollback with the unique violation")
        },
      ),
      it(
        "copy_from replays the count of the rows it sent",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("copy_from", recorded_scenarios.store_users)
          |> be_ok()
          |> be_equal("#(3, 3)")
          |> or_fail_with("Expected three rows stored and counted")
        },
      ),
      it(
        "copy_from into a missing table replays its server error",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back(
            "copy_from_refused",
            recorded_scenarios.store_into_missing_table,
          )
          |> be_error()
          |> summarise_error()
          |> be_equal("failed 42P01")
          |> or_fail_with("Expected an undefined table")
        },
      ),
      it("copy_to replays its rows through the reader", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("copy_to", recorded_scenarios.read_series)
        |> be_ok()
        |> be_equal("[3, 2, 1]")
        |> or_fail_with("Expected the three rows folded")
      }),
      it(
        "copy_to replays the server error that ended its stream",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back(
            "copy_to_failure",
            recorded_scenarios.read_series_divided_by_zero,
          )
          |> be_error()
          |> summarise_error()
          |> be_equal("invalid 22012")
          |> or_fail_with("Expected the division by zero")
        },
      ),
      it(
        "copy_to of a missing column replays its server error",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back(
            "copy_to_refused",
            recorded_scenarios.read_missing_column,
          )
          |> be_error()
          |> summarise_error()
          |> be_equal("failed 42703")
          |> or_fail_with("Expected an undefined column")
        },
      ),
      it(
        "a copy_to that the reader failed is not recorded",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("copy_to_unexpected_null", recorded_scenarios.read_null)
          |> be_error()
          |> summarise_error()
          |> be_equal("failed RequestNotRecorded(\"SELECT NULL::int4\")")
          |> or_fail_with("Expected the COPY not recorded")
        },
      ),
      it("a unique violation replays as Conflict", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("conflict", recorded_scenarios.insert_twice)
        |> be_error()
        |> summarise_error()
        |> be_equal("conflict 23505")
        |> or_fail_with("Expected the second insert to be a conflict")
      }),
      it(
        "a statement refused before its parameters replays",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back(
            "statement_refused",
            recorded_scenarios.select_missing_column,
          )
          |> be_error()
          |> summarise_error()
          |> be_equal("failed 42703")
          |> or_fail_with("Expected an undefined column")
        },
      ),
      it(
        "a statement that failed in the client is not recorded",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("parameter_mismatch", recorded_scenarios.count_with_text)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotRecorded(\"SELECT cardinality($1::int4[])\")",
          )
          |> or_fail_with("Expected the statement not recorded")
        },
      ),
      it(
        "a request with other parameters than the next recorded one is not matched",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", recorded_scenarios.select_four)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotMatched(\"SELECT x FROM generate_series(1, $1) AS x\", \"SELECT x FROM generate_series(1, $1) AS x\")",
          )
          |> or_fail_with(
            "Expected the request not matched, with both SQL texts",
          )
        },
      ),
      it(
        "a request of another kind than the next recorded one is not matched",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("run_sql", recorded_scenarios.select_series)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotMatched(\"SELECT 1; SELECT 2\", \"SELECT x FROM generate_series(1, $1) AS x\")",
          )
          |> or_fail_with(
            "Expected the statement not matched to the `run_sql` call",
          )
        },
      ),
      it(
        "values of other SQL that the recorded types cannot write are not matched",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("one", recorded_scenarios.select_series)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotMatched(\"SELECT cardinality($1::int4[])\", \"SELECT x FROM generate_series(1, $1) AS x\")",
          )
          |> or_fail_with("Expected the other SQL not matched")
        },
      ),
      it(
        "a codec that does not take the recorded type is refused",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("one", recorded_scenarios.count_with_text)
          |> be_error()
          |> summarise_error()
          |> be_equal("failed ParameterTypeMismatch(1, \"_int4\", \"text\")")
          |> or_fail_with("Expected the text codec refused for int4[]")
        },
      ),
      it("playback follows the recorded order", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> play_back("two_parameters", recorded_scenarios.select_three_then_two)
        |> be_error()
        |> summarise_error()
        |> be_equal(
          "failed RequestNotMatched(\"SELECT x FROM generate_series(1, $1) AS x\", \"SELECT x FROM generate_series(1, $1) AS x\")",
        )
        |> or_fail_with("Expected the second recorded request out of order")
      }),
      it(
        "a request after the last recorded one is not recorded",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", recorded_scenarios.select_series_twice)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotRecorded(\"SELECT x FROM generate_series(1, $1) AS x\")",
          )
          |> or_fail_with("Expected no request after the last one")
        },
      ),
      it(
        "match.sql_only plays back the recorded answer for other parameters",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("series_sql_only", recorded_scenarios.select_four)
          |> be_ok()
          |> be_equal("[1, 2, 3]")
          |> or_fail_with("Expected the rows recorded for 3")
        },
      ),
      it(
        "a key of the app plays back the recorded answer of the same name",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("named_key", recorded_scenarios.check_password_in_plain)
          |> be_ok()
          |> be_equal("True")
          |> or_fail_with("Expected the answer recorded for the name")
        },
      ),
      it(
        "a secret parameter plays back with another value",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("secret", recorded_scenarios.check_other_password)
          |> be_ok()
          |> be_equal("True")
          |> or_fail_with("Expected the recorded answer for another password")
        },
      ),
      it(
        "a parameter next to a secret one still matches exactly",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back(
            "secret",
            recorded_scenarios.check_password_against_other_hash,
          )
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotMatched(\"SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2\", \"SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2\")",
          )
          |> or_fail_with("Expected another hash not matched")
        },
      ),
      it(
        "a parameter that is not secret does not match a recorded secret",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("secret", recorded_scenarios.check_password_in_plain)
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed RequestNotMatched(\"SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2\", \"SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2\")",
          )
          |> or_fail_with("Expected the plain password not matched")
        },
      ),
      it(
        "the recording file holds no bytes of a secret parameter",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("secret")
          |> not_contain_text(
            bit_array.base16_encode(<<recorded_scenarios.password:utf8>>)
            |> string.lowercase,
          )
          |> or_fail_with("Expected no hex of the password in the file")
        },
      ),
      it(
        "the recording file holds no text of a secret parameter",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("secret")
          |> not_contain_text(recorded_scenarios.password)
          |> or_fail_with("Expected no text of the password in the file")
        },
      ),
      it(
        "the recording file keeps the codec of a secret parameter",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("secret")
          |> contain_string("{\"secret\":{\"codec\":\"text\"}}")
          |> or_fail_with("Expected the secret mark with its codec")
        },
      ),
      it("two record runs write the same bytes", fn(runs: RecordedRuns) {
        // Act and assert
        runs
        |> should
        |> read_recording_pair("identical")
        |> be_equal_parts
        |> or_fail_with("Expected the same file from both runs")
      }),
      it(
        "two record runs with a generated UUID and now() write the same bytes",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_pair("api_key")
          |> be_equal_parts
          |> or_fail_with("Expected the same file from both runs")
        },
      ),
      it(
        "the UUID of an answer plays back as its placeholder in the next parameter",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("api_key", recorded_scenarios.api_key().run)
          |> be_ok()
          |> be_equal(
            "deadbeef-dead-4eef-8ead-beef00000001 token-redacted 2024-01-01T00:00:00Z",
          )
          |> or_fail_with(
            "Expected the placeholder, the secret column and the fixed time",
          )
        },
      ),
      it(
        "the recording file holds the bytes of the UUID placeholder",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("api_key")
          |> contain_string("deadbeefdead4eef8eadbeef00000001")
          |> or_fail_with("Expected the placeholder in the uuid cells")
        },
      ),
      it(
        "the recording file holds the replaced text of the SQL",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("api_key")
          |> contain_string("'sk_test_' || md5(random()::text)")
          |> or_fail_with("Expected sk_test_ in the SQL")
        },
      ),
      it(
        "the recording file holds no text of a secret in the SQL",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("api_key")
          |> not_contain_text("sk_live_")
          |> or_fail_with("Expected no sk_live_ in the file")
        },
      ),
      it(
        "the recording file holds no bytes of a secret column",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("api_key")
          |> not_contain_text(
            bit_array.base16_encode(<<"sk_live_":utf8>>) |> string.lowercase,
          )
          |> or_fail_with("Expected no hex of the live token in the file")
        },
      ),
      it(
        "an answer of another kind from a recorder interceptor is not saved",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> read_recording_file("other_kind")
          |> contain_string("\"entries\": []")
          |> or_fail_with("Expected no entry")
        },
      ),
      it(
        "an interceptor added to a playback connection runs first",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", fn(connection) {
            query("UPDATE nothing")
            |> affected(with_interceptor(
              connection,
              interceptors.answer_with(command("UPDATE 7")),
            ))
            |> result.map(int.to_string)
          })
          |> be_ok()
          |> be_equal("7")
          |> or_fail_with("Expected the answer of the interceptor")
        },
      ),
      it(
        "stop of a playback connection stops its recorder",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", fn(connection) {
            pool.stop_pool(connection)
            recorded_scenarios.select_series(connection)
          })
          |> be_error()
          |> summarise_error()
          |> be_equal("unavailable RecorderStopped")
          |> or_fail_with("Expected the recorder stopped")
        },
      ),
      it(
        "copy_from answered with a `run_sql` call answer fails",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", fn(connection) {
            copy_from(
              with_interceptor(
                connection,
                interceptors.answer_with(Ok(SqlAnswer(results: []))),
              ),
              into: table("users"),
              columns: ["id", "email"],
              rows: copy_users.users(),
              write: copy_users.user_fields,
            )
            |> result.map(int.to_string)
          })
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed InterceptorFailed(\"an interceptor answered a COPY FROM with the answer of another kind of request\")",
          )
          |> or_fail_with("Expected the answer refused")
        },
      ),
      it(
        "copy_to answered with a `run_sql` call answer fails",
        fn(runs: RecordedRuns) {
          // Act and assert
          runs
          |> should
          |> play_back("all", fn(connection) {
            copy_to(
              with_interceptor(
                connection,
                interceptors.answer_with(Ok(SqlAnswer(results: []))),
              ),
              query("SELECT 1"),
              read: single(codec.int),
              from: [],
              with: list.prepend,
            )
            |> result.map(string.inspect)
          })
          |> be_error()
          |> summarise_error()
          |> be_equal(
            "failed InterceptorFailed(\"an interceptor answered a COPY TO with the answer of another kind of request\")",
          )
          |> or_fail_with("Expected the answer refused")
        },
      ),
      it(
        "RecordMissing plays back a recording that exists",
        fn(runs: RecordedRuns) {
          // Act and assert
          recorded_scenarios.copy_of(runs, "all")
          |> result.map(fn(path) {
            recorder.recorder(file: path)
            |> recorder.mode(recorder.RecordMissing)
            |> recorded_scenarios.normalized
          })
          |> should
          |> be_ok()
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.closed_port),
            recorded_scenarios.select_series,
          )
          |> be_ok()
          |> be_equal("[1, 2, 3]")
          |> or_fail_with("Expected the recorded rows with no database")
        },
      ),
      it(
        "RecordMissing records a recording that is missing",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "record_missing")

          // Act and assert
          recorder.recorder(file: path)
          |> recorder.mode(recorder.RecordMissing)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port),
            fn(connection) {
              let _rows = recorded_scenarios.select_series(connection)
              simplifile.read(path)
            },
          )
          |> be_ok()
          |> contain_string("generate_series")
          |> or_fail_with("Expected the request saved")
        },
      ),
      it(
        "Passthrough runs each request on the database",
        fn(runs: RecordedRuns) {
          // Act and assert
          recorder.recorder(file: recorded_scenarios.new_path(
            runs,
            "passthrough",
          ))
          |> recorder.mode(recorder.Passthrough)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port),
            recorded_scenarios.select_four,
          )
          |> be_ok()
          |> be_equal("[1, 2, 3, 4]")
          |> or_fail_with("Expected the rows of the database")
        },
      ),
      it("Passthrough writes no file", fn(runs: RecordedRuns) {
        // Arrange
        let path = recorded_scenarios.new_path(runs, "passthrough")

        // Act and assert
        recorder.recorder(file: path)
        |> recorder.mode(recorder.Passthrough)
        |> should
        |> run_with_recorder(
          server_pools.config(recorded_scenarios.server_port),
          fn(connection) {
            let _rows = recorded_scenarios.select_series(connection)
            simplifile.is_file(path)
          },
        )
        |> be_equal(Ok(False))
        |> or_fail_with("Expected no file")
      }),
      it(
        "a path that another recorder holds is refused",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "held")

          // Act and assert
          recorder.recorder(file: path)
          |> recorder.mode(recorder.Passthrough)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port),
            fn(_connection) {
              recorder.recorder(file: path)
              |> recorder.mode(recorder.Passthrough)
              |> recorder.start_recorder
            },
          )
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(RecordingInUse(path:))
          |> or_fail_with("Expected the path refused")
        },
      ),
      it(
        "a path is free again after its connection stops",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "freed")
          let _first_run =
            recorder.recorder(file: path)
            |> recorder.mode(recorder.Passthrough)
            |> recorder.start_recorder
            |> result.try(fn(test_recorder) {
              server_pools.config(recorded_scenarios.server_port)
              |> config.record(test_recorder)
              |> pool.start_pool
            })
            |> result.map(pool.stop_pool)

          // Act and assert
          recorder.recorder(file: path)
          |> recorder.mode(recorder.Passthrough)
          |> recorder.start_recorder
          |> should
          |> be_ok()
          |> or_fail_with("Expected the path free after the first stop")
        },
      ),
      it(
        "a recorder stops when the process that started it ends",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "owner_ended")
          recorded_scenarios.start_in_ended_process(path)

          // Act and assert
          recorded_scenarios.start_when_free(path, attempts: 100)
          |> should
          |> be_ok()
          |> or_fail_with("Expected the path free after its owner ended")
        },
      ),
      it("playback of a missing file fails to start", fn(runs: RecordedRuns) {
        // Arrange
        let path = recorded_scenarios.new_path(runs, "missing")

        // Act and assert
        recorder.recorder(file: path)
        |> recorder.start_recorder
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(RecordingNotFound(path:))
        |> or_fail_with("Expected the missing file named")
      }),
      it(
        "a file that is not a recording fails to start",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "not_a_recording")
          let _written =
            simplifile.create_directory_all(runs.directory <> "/new")
            |> result.try(fn(_made) { simplifile.write(path, "{}") })

          // Act and assert
          recorder.recorder(file: path)
          |> recorder.start_recorder
          |> should
          |> be_error()
          |> summarise_error()
          |> contain_string("failed RecordingNotDecoded(")
          |> or_fail_with("Expected the file not decoded")
        },
      ),
      it("a file that cannot be read fails to start", fn(runs: RecordedRuns) {
        // Arrange
        let path = recorded_scenarios.new_path(runs, "unreadable")
        let _written =
          simplifile.create_directory_all(runs.directory <> "/new")
          |> result.try(fn(_made) { simplifile.write(path, "{}") })
          |> result.try(fn(_written) {
            simplifile.set_permissions_octal(path, 0o000)
          })

        // Act and assert
        recorder.recorder(file: path)
        |> recorder.start_recorder
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(RecordingNotRead(path:, reason: posix.Eacces))
        |> or_fail_with("Expected the file not read")
      }),
      it("record mode under a file fails to start", fn(runs: RecordedRuns) {
        // Arrange
        let path =
          recorded_scenarios.first_path(runs, "all") <> "/under/recording.json"

        // Act and assert
        recorder.recorder(file: path)
        |> recorder.mode(recorder.Record)
        |> recorder.start_recorder
        |> should
        |> be_error()
        |> have_cause()
        |> have_reason()
        |> be_equal(RecordingNotWritten(path:, reason: posix.Enotdir))
        |> or_fail_with("Expected the directory not made")
      }),
      it(
        "a recording that cannot be written fails the request",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "blocked")

          // Act and assert
          recorder.recorder(file: path)
          |> recorder.mode(recorder.Record)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port),
            fn(connection) {
              let _blocked =
                simplifile.delete(path)
                |> result.try(fn(_deleted) { simplifile.create_directory(path) })
              recorded_scenarios.select_series(connection)
            },
          )
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(RecordingNotWritten(path:, reason: posix.Eisdir))
          |> or_fail_with("Expected the file that could not be written")
        },
      ),
      it(
        "a secret column that its codec cannot write fails the request",
        fn(runs: RecordedRuns) {
          // Act and assert
          recorder.recorder(file: recorded_scenarios.new_path(runs, "token"))
          |> recorder.mode(recorder.Record)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port)
              |> config.secret_column("token", codec.int, with: 1),
            recorded_scenarios.read_token,
          )
          |> be_error()
          |> have_cause()
          |> have_reason()
          |> be_equal(SecretColumnNotReplaced(
            column: "token",
            reason: "the codec int does not take the type text",
          ))
          |> or_fail_with("Expected the secret column refused")
        },
      ),
      it(
        "a recorder in Record mode saves the queries of a supervised pool",
        fn(runs: RecordedRuns) {
          // Arrange
          let path = recorded_scenarios.new_path(runs, "supervised")
          let pool_name = process.new_name("recorded_pool")

          // Act and assert
          {
            use test_recorder <- result.try(
              recorder.recorder(file: path)
              |> recorder.mode(recorder.Record)
              |> recorder.start_recorder
              |> result.map_error(string.inspect),
            )
            use pool_child <- result.try(
              server_pools.config(recorded_scenarios.server_port)
              |> config.record(test_recorder)
              |> pool.supervised(name: pool_name)
              |> result.map_error(string.inspect),
            )
            static_supervisor.new(static_supervisor.OneForOne)
            |> static_supervisor.add(pool_child)
            |> static_supervisor.start
            |> result.replace_error("the supervisor did not start")
          }
          |> should
          |> be_ok()
          |> run_and_stop_supervisor(fn() {
            let _rows =
              recorded_scenarios.select_series(pool.named_connection(pool_name))
            simplifile.read(path)
          })
          |> be_ok()
          |> contain_string("generate_series")
          |> or_fail_with("Expected the request of the supervised pool saved")
        },
      ),
      it(
        "a supervised Playback pool answers through its name with no database",
        fn(runs: RecordedRuns) {
          // Arrange
          let pool_name = process.new_name("played_pool")

          // Act and assert
          recorded_scenarios.start_supervised_playback(runs, "all", pool_name)
          |> should
          |> be_ok()
          |> run_and_stop_supervisor(fn() {
            recorded_scenarios.select_series(pool.named_connection(pool_name))
          })
          |> be_ok()
          |> be_equal("[1, 2, 3]")
          |> or_fail_with("Expected the recorded rows through the name")
        },
      ),
      it(
        "a supervised Playback pool answers again after its supervisor restarts it",
        fn(runs: RecordedRuns) {
          // Arrange
          let pool_name = process.new_name("restarted_pool")
          let connection = pool.named_connection(pool_name)

          // Act and assert
          recorded_scenarios.start_supervised_playback(
            runs,
            "identical",
            pool_name,
          )
          |> should
          |> be_ok()
          |> run_and_stop_supervisor(fn() {
            use _series <- result.try(
              recorded_scenarios.select_series(connection)
              |> result.map_error(string.inspect),
            )
            use Nil <- result.try(supervisors.restart_named_pool(pool_name))
            recorded_scenarios.count_array(connection)
            |> result.map_error(string.inspect)
          })
          |> be_ok()
          |> be_equal("3")
          |> or_fail_with("Expected the next recorded answer after the restart")
        },
      ),
      it(
        "a live copy_to stream goes through a normalizer as it is",
        fn(runs: RecordedRuns) {
          // Act and assert
          recorder.recorder(file: recorded_scenarios.new_path(runs, "live_copy"))
          |> recorder.mode(recorder.Passthrough)
          |> should
          |> run_with_recorder(
            server_pools.config(recorded_scenarios.server_port)
              |> config.intercept(normalize.timestamps_near_now(window_days: 1)),
            recorded_scenarios.read_series,
          )
          |> be_ok()
          |> be_equal("[3, 2, 1]")
          |> or_fail_with("Expected the rows of the database")
        },
      ),
    ],
  )
}
