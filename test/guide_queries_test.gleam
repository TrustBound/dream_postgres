//// Tests for the snippets of the queries guide
//// (docs/guides/queries.md). Each test runs a snippet and asserts the exact
//// value that the guide shows. The "with a database" tests run the query
//// functions and the handlers against the test PostgreSQL server, on the
//// table that the guide's SQL makes. The other tests build the results by
//// hand, or run the handlers on a pool where no database listens.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/output_file
import fixtures/test_database
import gleam/list
import gleam/string
import snippets/guide_queries_create_user
import snippets/guide_queries_list_users
import snippets/guide_queries_log_failure
import snippets/guide_queries_show_user.{Response}
import snippets/guide_queries_sql.{CreateUserRow, FindUserRow, ListUsersRow}

// The SQL that the guide shows in its `sql` block.
const users_sql = "test/fixtures/sql/queries_users.sql"

pub fn tests() -> TestSuite {
  describe("queries guide", [
    with_database_tests(),
    it("step 2: user_response answers as the output file shows", fn() {
      // Arrange
      let results = [
        #(
          "user_response(Ok(pog.Returned(count: 1, rows: [FindUserRow(1, \"Ada\", \"ada@example.com\")])))",
          Ok(
            pog.Returned(count: 1, rows: [
              FindUserRow(id: 1, name: "Ada", email: "ada@example.com"),
            ]),
          ),
        ),
        #(
          "user_response(Ok(pog.Returned(count: 0, rows: [])))",
          Ok(pog.Returned(count: 0, rows: [])),
        ),
        #("user_response(Error(pog.QueryTimeout))", Error(pog.QueryTimeout)),
      ]

      // Act
      let answers =
        list.map(results, fn(entry) {
          #(
            entry.0,
            string.inspect(guide_queries_show_user.user_response(entry.1)),
          )
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_queries_user_response"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 4: created_response answers as the output file shows", fn() {
      // Arrange
      let results = [
        #(
          "created_response(Ok(pog.Returned(count: 1, rows: [CreateUserRow(7)])))",
          Ok(pog.Returned(count: 1, rows: [CreateUserRow(id: 7)])),
        ),
        #(
          "created_response(Error(pog.ConstraintViolated(constraint: \"users_email_key\", ..)))",
          Error(pog.ConstraintViolated(
            message: "duplicate key value violates unique constraint \"users_email_key\"",
            constraint: "users_email_key",
            detail: "Key (email)=(ada@example.com) already exists.",
          )),
        ),
        #(
          "created_response(Error(pog.ConstraintViolated(constraint: \"users_name_check\", ..)))",
          Error(pog.ConstraintViolated(
            message: "new row violates check constraint \"users_name_check\"",
            constraint: "users_name_check",
            detail: "",
          )),
        ),
      ]

      // Act
      let answers =
        list.map(results, fn(entry) {
          #(
            entry.0,
            string.inspect(guide_queries_create_user.created_response(entry.1)),
          )
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_queries_created_response"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 5: log_failure gives back the result it gets", fn() {
      // Act
      let result: Result(pog.Returned(Int), pog.QueryError) =
        guide_queries_log_failure.log_failure(Error(pog.QueryTimeout))

      // Assert
      result
      |> should
      |> be_equal(Error(pog.QueryTimeout))
      |> or_fail_with("Expected the same error")
    }),
    it("step 5: show_user answers 500 when the database is not there", fn() {
      // Arrange
      let assert Ok(db) = postgres.from_url(database_url.unused_database_url())

      // Act
      let response = guide_queries_log_failure.show_user(db, 1)

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
  ])
}

fn with_database_tests() {
  group("with a database", [
    it("step 1: create_user returns the id of the new row", fn() {
      // Act
      let created =
        with_users_table(fn(db) {
          guide_queries_sql.create_user(db, "Ada", "ada@example.com")
        })

      // Assert
      created
      |> should
      |> be_equal(Ok(pog.Returned(count: 1, rows: [CreateUserRow(id: 1)])))
      |> or_fail_with("Expected the new id 1")
    }),
    it("step 1: find_user returns every column of the row", fn() {
      // Act
      let found =
        with_users_table(fn(db) {
          let assert Ok(_created) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_sql.find_user(db, 1)
        })

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          pog.Returned(count: 1, rows: [
            FindUserRow(id: 1, name: "Ada", email: "ada@example.com"),
          ]),
        ),
      )
      |> or_fail_with("Expected Ada with every column")
    }),
    it("step 1: list_users returns the rows ordered by name", fn() {
      // Act
      let listed =
        with_users_table(fn(db) {
          let assert Ok(_grace) =
            guide_queries_sql.create_user(db, "Grace", "grace@example.com")
          let assert Ok(_ada) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_sql.list_users(db)
        })

      // Assert
      listed
      |> should
      |> be_equal(
        Ok(
          pog.Returned(count: 2, rows: [
            ListUsersRow(id: 2, name: "Ada"),
            ListUsersRow(id: 1, name: "Grace"),
          ]),
        ),
      )
      |> or_fail_with("Expected Ada, then Grace")
    }),
    it(
      "step 1: find_user gives PostgresqlError when the table is missing",
      fn() {
        // Act
        let found =
          test_database.with_schema(fn(db) {
            guide_queries_sql.find_user(db, 1)
          })

        // Assert
        found
        |> should
        |> be_equal(
          Error(pog.PostgresqlError(
            code: "42P01",
            name: "undefined_table",
            message: "relation \"users\" does not exist",
          )),
        )
        |> or_fail_with("Expected undefined_table")
      },
    ),
    it("step 2: show_user answers as the output file shows", fn() {
      // Act
      let answers =
        with_users_table(fn(db) {
          let assert Ok(_created) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          [
            #(
              "show_user(db, 1)",
              string.inspect(guide_queries_show_user.show_user(db, 1)),
            ),
            #(
              "show_user(db, 2)",
              string.inspect(guide_queries_show_user.show_user(db, 2)),
            ),
          ]
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_queries_show_user"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 3: index_users answers as the output file shows", fn() {
      // Act
      let answers =
        with_users_table(fn(db) {
          let empty = guide_queries_list_users.index_users(db)
          let assert Ok(_grace) =
            guide_queries_sql.create_user(db, "Grace", "grace@example.com")
          let assert Ok(_ada) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          let full = guide_queries_list_users.index_users(db)
          let both =
            guide_queries_list_users.users_response(
              Ok(
                pog.Returned(count: 2, rows: [
                  ListUsersRow(id: 1, name: "Ada"),
                  ListUsersRow(id: 2, name: "Grace"),
                ]),
              ),
            )
          let none =
            guide_queries_list_users.users_response(
              Ok(pog.Returned(count: 0, rows: [])),
            )
          let assert Ok(unavailable_db) =
            postgres.from_url(database_url.unused_database_url())
          let unavailable = guide_queries_list_users.index_users(unavailable_db)
          [
            #(
              "index_users(db)                       // the table is empty",
              string.inspect(empty),
            ),
            #(
              "index_users(db)                       // after Grace, then Ada, signed up",
              string.inspect(full),
            ),
            #(
              "users_response(Ok(pog.Returned(count: 2, rows: [ListUsersRow(1, \"Ada\"), ListUsersRow(2, \"Grace\")])))",
              string.inspect(both),
            ),
            #(
              "users_response(Ok(pog.Returned(count: 0, rows: [])))",
              string.inspect(none),
            ),
            #(
              "index_users(<a pool where nothing listens>)",
              string.inspect(unavailable),
            ),
          ]
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_queries_index_users"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 4: create_user answers as the output file shows", fn() {
      // Act
      let answers =
        with_users_table(fn(db) {
          let first =
            guide_queries_create_user.create_user(db, "Ada", "ada@example.com")
          let second =
            guide_queries_create_user.create_user(db, "Ada", "ada@example.com")
          let error =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          [
            #(
              "create_user(db, \"Ada\", \"ada@example.com\")",
              string.inspect(first),
            ),
            #(
              "create_user(db, \"Ada\", \"ada@example.com\")",
              string.inspect(second),
            ),
            #(
              "sql.create_user(db, \"Ada\", \"ada@example.com\")   // the email is taken",
              constraint_text(error),
            ),
          ]
        })

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_queries_create_user"))
      |> or_fail_with("Expected the output file")
    }),
    it("step 5: show_user answers 500 when the table is missing", fn() {
      // Act
      let response =
        test_database.with_schema(fn(db) {
          guide_queries_log_failure.show_user(db, 1)
        })

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
    it("step 5: show_user answers 200 when the query works", fn() {
      // Act
      let response =
        with_users_table(fn(db) {
          let assert Ok(_created) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_log_failure.show_user(db, 1)
        })

      // Assert
      response
      |> should
      |> be_equal(Response(200, "1: Ada <ada@example.com>"))
      |> or_fail_with("Expected 200 with Ada")
    }),
  ])
}

// Runs `run` on a schema of its own that has the users table of the
// guide's SQL, with no rows.
fn with_users_table(run: fn(pog.Connection) -> a) -> a {
  test_database.with_schema(fn(db) {
    test_database.run_sql_file(db, users_sql)
    run(db)
  })
}

// Writes a unique violation as the guide shows it, one field on a line.
// Any other result is written with `string.inspect`.
fn constraint_text(result: Result(a, pog.QueryError)) -> String {
  case result {
    Error(pog.ConstraintViolated(message:, constraint:, detail:)) ->
      "Error(ConstraintViolated(\n       message: "
      <> string.inspect(message)
      <> ",\n       constraint: "
      <> string.inspect(constraint)
      <> ",\n       detail: "
      <> string.inspect(detail)
      <> ",\n     ))"
    other -> string.inspect(other)
  }
}
