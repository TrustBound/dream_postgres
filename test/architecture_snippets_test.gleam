//// Tests for the dream_postgres snippet in Dream's
//// docs/reference/architecture.md.
////
//// These tests check the config the builder makes, that connect_database
//// starts the pool, and how query results become values. The pool connects
//// in the background, so pool start returns Ok with no database.
//// find_user_name runs its query on the test PostgreSQL server.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/test_database
import gleam/result
import pog
import snippets/architecture_postgres

pub fn tests() -> TestSuite {
  describe("architecture snippets", [
    group("find_user_name with a database", [
      it("returns the name of the user with the id", fn() {
        // Act
        let name =
          with_one_user(fn(db) { architecture_postgres.find_user_name(db, 1) })

        // Assert
        name
        |> should
        |> be_equal("Ada")
        |> or_fail_with("Expected Ada")
      }),
      it("returns No such user for an id with no row", fn() {
        // Act
        let name =
          with_one_user(fn(db) { architecture_postgres.find_user_name(db, 2) })

        // Assert
        name
        |> should
        |> be_equal("No such user")
        |> or_fail_with("Expected No such user")
      }),
    ]),
    group("create_database_config", [
      it("sets the host", fn() {
        // Act
        let config = architecture_postgres.create_database_config()

        // Assert
        config.host
        |> should
        |> be_equal("localhost")
        |> or_fail_with("Expected host localhost")
      }),
      it("sets the database", fn() {
        // Act
        let config = architecture_postgres.create_database_config()

        // Assert
        config.database
        |> should
        |> be_equal("app")
        |> or_fail_with("Expected database app")
      }),
      it("sets the pool size", fn() {
        // Act
        let config = architecture_postgres.create_database_config()

        // Assert
        config.pool_size
        |> should
        |> be_equal(10)
        |> or_fail_with("Expected pool size 10")
      }),
    ]),
    group("connect_database", [
      it("starts the pool", fn() {
        // Act
        let result = architecture_postgres.connect_database()

        // Assert
        result
        |> result.replace(Nil)
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("Expected the pool to start")
      }),
    ]),
    group("describe_user_name", [
      it("returns the name when the result has a row", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 1, rows: ["Ada"]))

        // Act
        let description = architecture_postgres.describe_user_name(result)

        // Assert
        description
        |> should
        |> be_equal("Ada")
        |> or_fail_with("Expected Ada")
      }),
      it("returns No such user when the result has no rows", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 0, rows: []))

        // Act
        let description = architecture_postgres.describe_user_name(result)

        // Assert
        description
        |> should
        |> be_equal("No such user")
        |> or_fail_with("Expected No such user")
      }),
      it("returns a failure message when the query failed", fn() {
        // Arrange
        let result = Error(pog.ConnectionUnavailable)

        // Act
        let description = architecture_postgres.describe_user_name(result)

        // Assert
        description
        |> should
        |> be_equal("The database query failed")
        |> or_fail_with("Expected The database query failed")
      }),
    ]),
  ])
}

// Runs `run` on a schema of its own with a users table that holds Ada with
// id 1.
fn with_one_user(run: fn(pog.Connection) -> a) -> a {
  test_database.with_schema(fn(db) {
    let assert Ok(_created) =
      test_database.execute(
        db,
        "CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL)",
      )
    let assert Ok(_inserted) =
      test_database.execute(db, "INSERT INTO users (name) VALUES ('Ada')")
    run(db)
  })
}
