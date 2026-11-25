//// Tests that code from the SQL generator compiles and runs against
//// `dream_postgres/client`. The modules of `test/generated` are the
//// generated modules of two Dream examples, with
//// `import dream_postgres/client as pog` as their only change. The record
//// tests run their queries on the real PostgreSQL 16 server. The playback
//// tests play the committed recordings back with no database.

import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/generated_queries
import fixtures/recordings
import gleam/list
import gleam/result
import gleam/string

pub fn tests() -> TestSuite {
  describe("generated SQL code with dream_postgres/client", [
    setting_tests(),
    record_tests(),
    playback_group(),
  ])
}

/// The tests that need no database.
pub fn playback_tests() -> TestSuite {
  describe("generated SQL code with dream_postgres/client", [
    setting_tests(),
    playback_group(),
  ])
}

fn setting_tests() {
  group("the client_module setting", [
    it("the generated modules import the module of the setting as pog", fn() {
      // Arrange
      let setting =
        recordings.read("test/fixtures/generated/gleam.toml")
        |> string.split("\n")
        |> list.find(string.starts_with(_, "client_module = "))
        |> result.map(string.replace(_, "client_module = ", ""))
        |> result.map(string.replace(_, "\"", ""))

      // Act
      let import_line =
        recordings.read("test/generated/database_sql.gleam")
        |> string.split("\n")
        |> list.find(fn(line) {
          string.starts_with(line, "import ")
          && string.ends_with(line, " as pog")
        })

      // Assert
      import_line
      |> should
      |> be_equal(
        result.map(setting, fn(module) { "import " <> module <> " as pog" }),
      )
      |> or_fail_with("Expected import dream_postgres/client as pog")
    }),
  ])
}

fn record_tests() {
  group("record mode", [
    it("the database example gives each query its live result", fn() {
      // Act
      let results = {
        use directory <- recordings.with_directory()
        record(
          directory,
          "generated_database",
          generated_queries.database_scenario,
        ).0
      }

      // Assert
      results
      |> should
      |> be_equal(generated_queries.database_results)
      |> or_fail_with("Expected the live results")
    }),
    it(
      "the database example writes the committed generated_database.json",
      fn() {
        // Act
        let file = {
          use directory <- recordings.with_directory()
          let _recorded =
            record(
              directory,
              "generated_database",
              generated_queries.database_scenario,
            )
          recordings.read(directory <> "/generated_database.json")
        }

        // Assert
        file
        |> should
        |> be_equal(recordings.read(
          recordings.fixtures <> "/generated_database.json",
        ))
        |> or_fail_with("Expected the committed recording")
      },
    ),
    it("the tasks example gives each query its live result", fn() {
      // Act
      let results = {
        use directory <- recordings.with_directory()
        record(directory, "generated_tasks", generated_queries.task_scenario).0
      }

      // Assert
      results
      |> should
      |> be_equal(generated_queries.task_results)
      |> or_fail_with("Expected the live results")
    }),
    it("the tasks example writes the committed generated_tasks.json", fn() {
      // Act
      let file = {
        use directory <- recordings.with_directory()
        let _recorded =
          record(directory, "generated_tasks", generated_queries.task_scenario)
        recordings.read(directory <> "/generated_tasks.json")
      }

      // Assert
      file
      |> should
      |> be_equal(recordings.read(
        recordings.fixtures <> "/generated_tasks.json",
      ))
      |> or_fail_with("Expected the committed recording")
    }),
  ])
}

fn playback_group() {
  group("playback mode", [
    it("the database example gives each query its recorded result", fn() {
      // Act
      let results =
        recordings.play(
          recordings.builder(recordings.fixtures, "generated_database"),
          generated_queries.database_scenario,
        )

      // Assert
      results
      |> should
      |> be_equal(generated_queries.database_results)
      |> or_fail_with("Expected the results of the live run")
    }),
    it("the tasks example gives each query its recorded result", fn() {
      // Act
      let results =
        recordings.play(
          recordings.builder(recordings.fixtures, "generated_tasks"),
          generated_queries.task_scenario,
        )

      // Assert
      results
      |> should
      |> be_equal(generated_queries.task_results)
      |> or_fail_with("Expected the results of the live run")
    }),
  ])
}

fn record(
  directory: String,
  name: String,
  run: fn(postgres.Connection) -> a,
) -> #(a, Result(Nil, String)) {
  recordings.record_in_schema(recordings.builder(directory, name), run)
}
