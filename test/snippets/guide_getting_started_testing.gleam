//// Getting started guide: Test your code
////
//// Tests `greeting` with results built by hand, and `start` with a URL
//// that is not valid. Neither test needs a database.

import dream_pog as pog
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/result
import snippets/guide_getting_started_startup.{describe as describe_error, start}
import snippets/guide_getting_started_users.{User, greeting}

pub fn tests() -> TestSuite {
  describe("my app's database code", [
    it("greets the user of the first row", fn() {
      // Arrange
      let result = Ok(pog.Returned(count: 1, rows: [User(id: 1, name: "Ada")]))

      // Act
      let text = greeting(result)

      // Assert
      text
      |> should
      |> be_equal("Hello, Ada")
      |> or_fail_with("Expected a greeting for Ada")
    }),
    it("says so when no user has the id", fn() {
      // Arrange
      let result = Ok(pog.Returned(count: 0, rows: []))

      // Act
      let text = greeting(result)

      // Assert
      text
      |> should
      |> be_equal("No user with that id")
      |> or_fail_with("Expected the no-user message")
    }),
    it("stops at startup when the URL has no database name", fn() {
      // Act
      let started =
        start("postgresql://app:secret@localhost:5432")
        |> result.map_error(describe_error)

      // Assert
      started
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("DATABASE_URL is not valid: MissingDatabase"))
      |> or_fail_with("Expected the URL error")
    }),
  ])
}
