//// Queries guide: Test your code
////
//// Tests the response functions with results built by hand, and a handler
//// against a pool where no database listens.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/guide_queries_create_user.{created_response}
import snippets/guide_queries_show_user.{Response, show_user, user_response}
import snippets/guide_queries_sql.{FindUserRow}

pub fn tests() -> TestSuite {
  describe("user handlers", [
    it("answers 200 with the user of the first row", fn() {
      // Arrange
      let ada = FindUserRow(id: 1, name: "Ada", email: "ada@example.com")
      let result = Ok(pog.Returned(count: 1, rows: [ada]))

      // Act
      let response = user_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(200, "1: Ada <ada@example.com>"))
      |> or_fail_with("Expected 200 with Ada")
    }),
    it("answers 404 when no row has the id", fn() {
      // Arrange
      let result = Ok(pog.Returned(count: 0, rows: []))

      // Act
      let response = user_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(404, "No user with that id"))
      |> or_fail_with("Expected 404")
    }),
    it("answers 409 when the email is taken", fn() {
      // Arrange
      let result =
        Error(pog.ConstraintViolated(
          message: "duplicate key value violates unique constraint \"users_email_key\"",
          constraint: "users_email_key",
          detail: "Key (email)=(ada@example.com) already exists.",
        ))

      // Act
      let response = created_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(409, "That email is already taken"))
      |> or_fail_with("Expected 409")
    }),
    it("answers 500 when the database is not there", fn() {
      // Arrange
      // Nothing listens on port 1 of this machine
      let assert Ok(db) =
        postgres.from_url("postgresql://app:secret@127.0.0.1:1/app")

      // Act
      let response = show_user(db, 1)

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
  ])
}
