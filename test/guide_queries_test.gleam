//// Tests for the snippets of the queries guide
//// (docs/guides/queries.md). Each test runs a snippet and asserts the exact
//// value that the guide shows. The "with a database" tests run the query
//// functions and the handlers against the test PostgreSQL server, on the
//// table that the guide's SQL makes. The other tests build the results by
//// hand, or run the handlers on a pool where no database listens.

import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/test_database
import pog
import snippets/guide_queries_create_user
import snippets/guide_queries_list_users
import snippets/guide_queries_log_failure
import snippets/guide_queries_show_user.{Response}
import snippets/guide_queries_sql.{CreateUserRow, FindUserRow, ListUsersRow}

const guide_path = "docs/guides/queries.md"

pub fn tests() -> TestSuite {
  describe("queries guide", [
    with_database_tests(),
    it("step 2: user_response answers 500 for a query error", fn() {
      // Act
      let response =
        guide_queries_show_user.user_response(Error(pog.QueryTimeout))

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
    it("step 3: users_response joins the names", fn() {
      // Arrange
      let result =
        Ok(
          pog.Returned(count: 2, rows: [
            ListUsersRow(id: 1, name: "Ada"),
            ListUsersRow(id: 2, name: "Grace"),
          ]),
        )

      // Act
      let response = guide_queries_list_users.users_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(200, "Ada, Grace"))
      |> or_fail_with("Expected both names")
    }),
    it("step 3: users_response answers 200 for no rows", fn() {
      // Act
      let response =
        guide_queries_list_users.users_response(
          Ok(pog.Returned(count: 0, rows: [])),
        )

      // Assert
      response
      |> should
      |> be_equal(Response(200, "No users yet"))
      |> or_fail_with("Expected the empty list message")
    }),
    it("step 3: index_users answers 500 when the database is not there", fn() {
      // Arrange
      let assert Ok(db) = postgres.from_url(database_url.unused_database_url())

      // Act
      let response = guide_queries_list_users.index_users(db)

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
    it("step 4: created_response answers 201 with the new id", fn() {
      // Act
      let response =
        guide_queries_create_user.created_response(
          Ok(pog.Returned(count: 1, rows: [CreateUserRow(id: 7)])),
        )

      // Assert
      response
      |> should
      |> be_equal(Response(201, "Created user 7"))
      |> or_fail_with("Expected 201")
    }),
    it("step 4: created_response answers 500 for another constraint", fn() {
      // Arrange
      let result =
        Error(pog.ConstraintViolated(
          message: "new row violates check constraint \"users_name_check\"",
          constraint: "users_name_check",
          detail: "",
        ))

      // Act
      let response = guide_queries_create_user.created_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
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
    it("step 1: a duplicate email gives the error the test shows", fn() {
      // Act
      let duplicate =
        with_users_table(fn(db) {
          let assert Ok(_first) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_sql.create_user(db, "Ada", "ada@example.com")
        })

      // Assert
      duplicate
      |> should
      |> be_equal(
        Error(pog.ConstraintViolated(
          message: "duplicate key value violates unique constraint \"users_email_key\"",
          constraint: "users_email_key",
          detail: "Key (email)=(ada@example.com) already exists.",
        )),
      )
      |> or_fail_with("Expected the unique violation of users_email_key")
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
    it("step 2: show_user answers 200 with the user", fn() {
      // Act
      let response =
        with_users_table(fn(db) {
          let assert Ok(_created) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_show_user.show_user(db, 1)
        })

      // Assert
      response
      |> should
      |> be_equal(Response(200, "1: Ada <ada@example.com>"))
      |> or_fail_with("Expected 200 with Ada")
    }),
    it("step 2: show_user answers 404 for an id with no row", fn() {
      // Act
      let response =
        with_users_table(fn(db) { guide_queries_show_user.show_user(db, 1) })

      // Assert
      response
      |> should
      |> be_equal(Response(404, "No user with that id"))
      |> or_fail_with("Expected 404")
    }),
    it("step 3: index_users answers with the names in order", fn() {
      // Act
      let response =
        with_users_table(fn(db) {
          let assert Ok(_grace) =
            guide_queries_sql.create_user(db, "Grace", "grace@example.com")
          let assert Ok(_ada) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_list_users.index_users(db)
        })

      // Assert
      response
      |> should
      |> be_equal(Response(200, "Ada, Grace"))
      |> or_fail_with("Expected both names")
    }),
    it("step 3: index_users answers 200 for an empty table", fn() {
      // Act
      let response =
        with_users_table(fn(db) { guide_queries_list_users.index_users(db) })

      // Assert
      response
      |> should
      |> be_equal(Response(200, "No users yet"))
      |> or_fail_with("Expected the empty list message")
    }),
    it("step 4: create_user answers 201 with the new id", fn() {
      // Act
      let response =
        with_users_table(fn(db) {
          guide_queries_create_user.create_user(db, "Ada", "ada@example.com")
        })

      // Assert
      response
      |> should
      |> be_equal(Response(201, "Created user 1"))
      |> or_fail_with("Expected 201")
    }),
    it("step 4: create_user answers 409 for an email that is taken", fn() {
      // Act
      let response =
        with_users_table(fn(db) {
          let assert Ok(_first) =
            guide_queries_sql.create_user(db, "Ada", "ada@example.com")
          guide_queries_create_user.create_user(db, "Ada", "ada@example.com")
        })

      // Assert
      response
      |> should
      |> be_equal(Response(409, "That email is already taken"))
      |> or_fail_with("Expected 409")
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
    test_database.run_guide_sql(db, guide_path)
    run(db)
  })
}
