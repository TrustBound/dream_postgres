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
import fixtures/output_file
import fixtures/test_database
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pog
import snippets/guide_getting_started_connect
import snippets/guide_getting_started_startup
import snippets/guide_getting_started_users.{Context, User}

// The SQL that the guide shows in its `sql` block.
const users_sql = "test/fixtures/sql/getting_started_users.sql"

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
    it("step 1: connect explains an sslmode, as the output file shows", fn() {
      // Arrange
      let url = "postgresql://app:secret@db.example.com/app?sslmode=prefer"

      // Act
      let connected =
        guide_getting_started_connect.connect(url)
        |> result.replace(Nil)

      // Assert
      output_file.calls([
        #("connect(" <> string.inspect(url) <> ")", string.inspect(connected)),
      ])
      |> should
      |> be_equal(output_file.read("guide_getting_started_connect_error"))
      |> or_fail_with("Expected the output file")
    }),
    it(
      "step 3: greeting and greet_user without a database answer as the output file shows",
      fn() {
        // Arrange
        let result =
          Ok(
            pog.Returned(count: 2, rows: [
              User(id: 1, name: "Ada"),
              User(id: 2, name: "Grace"),
            ]),
          )
        let assert Ok(db) =
          guide_getting_started_connect.connect(
            database_url.unused_database_url(),
          )

        // Act
        let greeting = guide_getting_started_users.greeting(result)
        let unavailable =
          guide_getting_started_users.greet_user(Context(db:), 1)

        // Assert
        output_file.calls([
          #(
            "greeting(Ok(pog.Returned(count: 2, rows: [User(1, \"Ada\"), User(2, \"Grace\")])))",
            string.inspect(greeting),
          ),
          #(
            "greet_user(Context(db: <a pool where nothing listens>), 1)",
            string.inspect(unavailable),
          ),
        ])
        |> should
        |> be_equal(output_file.read("guide_getting_started_greeting"))
        |> or_fail_with("Expected the output file")
      },
    ),
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
    it("step 2: start answers as the output file shows", fn() {
      // Arrange
      let config = test_database.config()
      let port = database_url.unused_port()
      let urls = [
        test_database.url(),
        test_database.url_for(
          user: config.user,
          password: "wrong-password",
          database: config.database,
        ),
        "postgresql://app:p@ss@db.example.com/app",
        "postgresql://user:pass@127.0.0.1:" <> int.to_string(port) <> "/myapp",
      ]

      // Act
      let answers = list.map(urls, started)

      // Assert
      list.zip(urls, answers)
      |> list.map(fn(pair) {
        #(
          output_file.hide_port("start(" <> string.inspect(pair.0) <> ")", port),
          pair.1,
        )
      })
      |> output_file.calls()
      |> should
      |> be_equal(output_file.read("guide_getting_started_start"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 3: greet_user and find_user answer as the output file shows", fn() {
      // Act
      let answers =
        test_database.with_schema(fn(db) {
          test_database.run_sql_file(db, users_sql)
          [
            #(
              "greet_user(Context(db:), 1)",
              string.inspect(guide_getting_started_users.greet_user(
                Context(db:),
                1,
              )),
            ),
            #(
              "greet_user(Context(db:), 3)",
              string.inspect(guide_getting_started_users.greet_user(
                Context(db:),
                3,
              )),
            ),
            #(
              "find_user(db, 2)",
              string.inspect(guide_getting_started_users.find_user(db, 2)),
            ),
          ]
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_getting_started_greet_user"))
      |> or_fail_with("Expected the output file")
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

// Runs `start` of the guide on `url` and stops its pool. Gives the answer
// as the guide shows it: `Ok(connection)`, because the connection holds a
// pool name that changes from one run to the next, or the error through
// `describe`.
fn started(url: String) -> String {
  use <- test_database.with_own_pools()
  case guide_getting_started_startup.start(url) {
    Ok(_connection) -> "Ok(connection)"
    Error(error) ->
      string.inspect(Error(guide_getting_started_startup.describe(error)))
  }
}
