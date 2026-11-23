//// Tests for the snippets of the getting started guide
//// (docs/guides/getting-started.md). Each test runs a snippet and asserts
//// the exact value that the guide shows. The "with a database" tests run
//// against the test PostgreSQL server, with the table and rows that the
//// guide's SQL makes. The other pools start on a local port where no
//// database listens.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/test_database
import gleam/result
import pog
import snippets/guide_getting_started_connect
import snippets/guide_getting_started_startup
import snippets/guide_getting_started_users.{Context, User}

const guide_path = "docs/guides/getting-started.md"

pub fn tests() -> TestSuite {
  describe("getting started guide", [
    with_database_tests(),
    it("step 1: connect starts a pool when no database listens", fn() {
      // Act
      let connected =
        guide_getting_started_connect.connect(
          database_url.unused_database_url(),
        )

      // Assert
      result.is_ok(connected)
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected Ok, because the pool connects later")
    }),
    it("step 1: connect explains an sslmode it does not support", fn() {
      // Act
      let connected =
        guide_getting_started_connect.connect(
          "postgresql://app:secret@db.example.com/app?sslmode=prefer",
        )

      // Assert
      connected
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(
        "DATABASE_URL is not valid: UnsupportedSslMode(\"prefer\")",
      ))
      |> or_fail_with("Expected the sslmode error")
    }),
    it("step 2: start stops when the database does not answer", fn() {
      // Act
      let started =
        guide_getting_started_startup.start(database_url.unused_database_url())
        |> result.map_error(guide_getting_started_startup.describe)

      // Assert
      started
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("The database did not answer: ConnectionUnavailable"))
      |> or_fail_with("Expected the database error")
    }),
    it("step 2: start stops on a password with an @ in it", fn() {
      // Act
      let started =
        guide_getting_started_startup.start(
          "postgresql://app:p@ss@db.example.com/app",
        )
        |> result.map_error(guide_getting_started_startup.describe)

      // Assert
      started
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("DATABASE_URL is not valid: MalformedUrl"))
      |> or_fail_with("Expected MalformedUrl")
    }),
    it("step 2: describe names a pool that did not start", fn() {
      // Act
      let text =
        guide_getting_started_startup.describe(
          guide_getting_started_startup.PoolDidNotStart,
        )

      // Assert
      text
      |> should
      |> be_equal("The database pool did not start")
      |> or_fail_with("Expected the pool message")
    }),
    it("step 3: greet_user answers when the database is not there", fn() {
      // Arrange
      let assert Ok(db) =
        guide_getting_started_connect.connect(
          database_url.unused_database_url(),
        )

      // Act
      let text = guide_getting_started_users.greet_user(Context(db:), 1)

      // Assert
      text
      |> should
      |> be_equal("The database is not available")
      |> or_fail_with("Expected the database message")
    }),
    it("step 3: greeting greets the user of the first row", fn() {
      // Arrange
      let result =
        Ok(
          pog.Returned(count: 2, rows: [
            User(id: 1, name: "Ada"),
            User(id: 2, name: "Grace"),
          ]),
        )

      // Act
      let text = guide_getting_started_users.greeting(result)

      // Assert
      text
      |> should
      |> be_equal("Hello, Ada")
      |> or_fail_with("Expected a greeting for Ada")
    }),
  ])
}

fn with_database_tests() {
  group("with a database", [
    it("step 1: connect gives a pool that runs a query", fn() {
      // Act
      let database = {
        use <- test_database.with_own_pools()
        guide_getting_started_connect.connect(test_database.url())
        |> result.map(test_database.texts(_, "SELECT current_database()"))
      }

      // Assert
      database
      |> should
      |> be_equal(Ok(Ok([test_database.config().database])))
      |> or_fail_with("Expected the name of the test database")
    }),
    it("step 2: start passes when the database answers", fn() {
      // Act
      let started = {
        use <- test_database.with_own_pools()
        guide_getting_started_startup.start(test_database.url())
        |> result.replace(Nil)
        |> result.map_error(guide_getting_started_startup.describe)
      }

      // Assert
      started
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the startup check to pass")
    }),
    it("step 3: find_user returns the row of the guide's SQL", fn() {
      // Act
      let found =
        test_database.with_schema(fn(db) {
          test_database.run_guide_sql(db, guide_path)
          guide_getting_started_users.find_user(db, 2)
        })

      // Assert
      found
      |> should
      |> be_equal(
        Ok(pog.Returned(count: 1, rows: [User(id: 2, name: "Grace")])),
      )
      |> or_fail_with("Expected Grace with id 2")
    }),
    it("step 3: greet_user greets the user with id 1", fn() {
      // Act
      let text =
        test_database.with_schema(fn(db) {
          test_database.run_guide_sql(db, guide_path)
          guide_getting_started_users.greet_user(Context(db:), 1)
        })

      // Assert
      text
      |> should
      |> be_equal("Hello, Ada")
      |> or_fail_with("Expected a greeting for Ada")
    }),
    it("step 3: greet_user says so for an id with no row", fn() {
      // Act
      let text =
        test_database.with_schema(fn(db) {
          test_database.run_guide_sql(db, guide_path)
          guide_getting_started_users.greet_user(Context(db:), 3)
        })

      // Assert
      text
      |> should
      |> be_equal("No user with that id")
      |> or_fail_with("Expected the no-user message")
    }),
    it(
      "step 3: greet_user gives the database message when the table is missing",
      fn() {
        // Act
        let text =
          test_database.with_schema(fn(db) {
            guide_getting_started_users.greet_user(Context(db:), 1)
          })

        // Assert
        text
        |> should
        |> be_equal("The database is not available")
        |> or_fail_with("Expected the database message for a missing table")
      },
    ),
  ])
}
