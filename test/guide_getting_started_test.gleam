//// Tests for the snippets of the getting started guide
//// (docs/guides/getting-started.md). Each test runs a snippet and asserts
//// the exact value that the guide shows. The "with a database" tests run
//// against the test PostgreSQL server, with the table and rows that the
//// guide's SQL makes. The other pools start on a local port where no
//// database listens.

import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/output_file
import fixtures/test_database
import gleam/int
import gleam/result
import gleam/string
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
            dream_postgres_client.Returned(count: 2, rows: [
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
            "greeting(Ok(dream_postgres_client.Returned(count: 2, rows: [User(1, \"Ada\"), User(2, \"Grace\")])))",
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
    // Each call of the start output file has its own test. A wrong password
    // and a port where nothing listens each take 2 to 3 seconds (see
    // `started`), so two of them in one test can pass the time limit of a
    // test.
    it(
      "step 2: start of the test database answers as the output file shows",
      fn() {
        // Arrange
        let call = start_call(test_database.url())

        // Act
        let answer = started(test_database.url())

        // Assert
        output_file.calls([#(call, answer)])
        |> should
        |> be_equal(output_file.block(start_output, call))
        |> or_fail_with("Expected the block of the output file")
      },
    ),
    it(
      "step 2: start with a wrong password answers as the output file shows",
      fn() {
        // Arrange
        let url = wrong_password_url()
        let call = start_call(url)

        // Act
        let answer = started(url)

        // Assert
        output_file.calls([#(call, answer)])
        |> should
        |> be_equal(output_file.block(start_output, call))
        |> or_fail_with("Expected the block of the output file")
      },
    ),
    it(
      "step 2: start of a malformed URL answers as the output file shows",
      fn() {
        // Arrange
        let call = start_call(malformed_url)

        // Act
        let answer = started(malformed_url)

        // Assert
        output_file.calls([#(call, answer)])
        |> should
        |> be_equal(output_file.block(start_output, call))
        |> or_fail_with("Expected the block of the output file")
      },
    ),
    it(
      "step 2: start where no database listens answers as the output file shows",
      fn() {
        // Arrange
        let port = database_url.unused_port()
        let url = unused_port_url(port)
        let call = output_file.hide_port(start_call(url), port)

        // Act
        let answer = started(url)

        // Assert
        output_file.calls([#(call, answer)])
        |> should
        |> be_equal(output_file.block(start_output, call))
        |> or_fail_with("Expected the block of the output file")
      },
    ),
    it("step 2: the start output file shows the calls of the tests", fn() {
      // Arrange
      let port = database_url.unused_port()
      let calls = [
        start_call(test_database.url()),
        start_call(wrong_password_url()),
        start_call(malformed_url),
        output_file.hide_port(start_call(unused_port_url(port)), port),
      ]

      // Act
      let file_calls = output_file.call_lines(start_output)

      // Assert
      file_calls
      |> should
      |> be_equal(calls)
      |> or_fail_with("Expected the four calls of the step 2 tests, in order")
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

// The output file of step 2, which the guide shows under "What start
// returns".
const start_output = "guide_getting_started_start"

// A URL that `from_url` cannot read: the password holds an `@`.
const malformed_url = "postgresql://app:p@ss@db.example.com/app"

fn wrong_password_url() -> String {
  let config = test_database.config()
  test_database.url_for(
    user: config.user,
    password: "wrong-password",
    database: config.database,
  )
}

fn unused_port_url(port: Int) -> String {
  "postgresql://user:pass@127.0.0.1:" <> int.to_string(port) <> "/myapp"
}

// The call as the output file shows it.
fn start_call(url: String) -> String {
  "start(" <> string.inspect(url) <> ")"
}

// Runs `start` of the guide on `url` and stops its pool. Gives the answer
// as the guide shows it: `Ok(connection)`, because the connection holds a
// pool name that changes from one run to the next, or the error through
// `describe`.
//
// When the database does not answer, `check` returns `ConnectionUnavailable`
// only when the pool drops the queued `SELECT 1`. The pool of
// `dream_postgres_driver` drops a queued checkout at a queue poll, once per
// `queue_interval` (1 second) from the start of the pool. The poll at 2
// seconds drops it when the checkout came in the same millisecond as the pool
// start, and the poll at 3 seconds drops it when it came later in the first
// second. So this function takes 2 to 3 seconds for a wrong password or a
// port where nothing listens.
fn started(url: String) -> String {
  use <- test_database.with_own_pools()
  case guide_getting_started_startup.start(url) {
    Ok(_connection) -> "Ok(connection)"
    Error(error) ->
      string.inspect(Error(guide_getting_started_startup.describe(error)))
  }
}
