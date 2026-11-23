//// Tests for the code blocks in README.md.
////
//// The README shows one snippet, readme_connection_setup. These tests check
//// the config it makes, and that connect_database starts a pool for
//// localhost:5432. The pool connects in the background, so it starts with
//// no database there.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/option
import gleam/result
import snippets/readme_connection_setup

pub fn tests() -> TestSuite {
  describe("README snippets", [
    connection_setup_tests(),
  ])
}

fn connection_setup_tests() {
  group("Connection Setup", [
    it("database_config sets every value", fn() {
      // Act
      let config = readme_connection_setup.database_config()

      // Assert
      #(
        config.host,
        config.port,
        config.database,
        config.user,
        config.password,
        config.pool_size,
      )
      |> should
      |> be_equal(#(
        "localhost",
        5432,
        "myapp",
        "postgres",
        option.Some("secret"),
        15,
      ))
      |> or_fail_with("Expected every value of the README config")
    }),
    it("connect_database starts the pool", fn() {
      // Act
      let result = readme_connection_setup.connect_database()

      // Assert
      result
      |> result.replace(Nil)
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the pool to start")
    }),
  ])
}
