//// Tests for the code blocks in README.md.
////
//// These tests need no database. They check the config each builder makes
//// and how query results become values. The connect functions
//// (connect_database, connect_from_url, connect_production) start a pool for
//// localhost:5432. The pool connects in the background, so pool start
//// returns Ok with no database. find_user and list_users run a query on a
//// pool, so they are only compiled.

import dream_postgres/query
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/option
import gleam/result
import pog
import snippets/readme_connection_builder
import snippets/readme_connection_from_url
import snippets/readme_connection_setup
import snippets/readme_error_handling
import snippets/readme_query_execution
import snippets/readme_query_result_helpers

pub fn tests() -> TestSuite {
  describe("README snippets", [
    connection_setup_tests(),
    connection_from_url_tests(),
    query_execution_tests(),
    connection_builder_tests(),
    query_result_helper_tests(),
    error_handling_tests(),
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

fn connection_from_url_tests() {
  group("Or from URL", [
    it("describe_url names the database and the host", fn() {
      // Act
      let description =
        readme_connection_from_url.describe_url(
          "postgresql://user:pass@localhost:5432/myapp",
        )

      // Assert
      description
      |> should
      |> be_equal("Database myapp on localhost")
      |> or_fail_with("Expected the database and the host")
    }),
    it("describe_url names an unsupported parameter", fn() {
      // Act
      let description =
        readme_connection_from_url.describe_url(
          "postgresql://user:pass@localhost:5432/myapp?connect_timeout=10",
        )

      // Assert
      description
      |> should
      |> be_equal("Unsupported parameter: connect_timeout")
      |> or_fail_with("Expected the unsupported parameter")
    }),
    it("describe_url inspects any other error", fn() {
      // Act
      let description =
        readme_connection_from_url.describe_url(
          "postgresql://user:pass@localhost:5432",
        )

      // Assert
      description
      |> should
      |> be_equal("Invalid URL: MissingDatabase")
      |> or_fail_with("Expected Invalid URL: MissingDatabase")
    }),
    it("connect_from_url starts the pool", fn() {
      // Act
      let result = readme_connection_from_url.connect_from_url()

      // Assert
      result
      |> result.replace(Nil)
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the pool to start from the URL")
    }),
  ])
}

fn query_execution_tests() {
  group("Query Execution", [
    it("describe_user describes the user of the first row", fn() {
      // Arrange
      let result =
        Ok(
          pog.Returned(count: 1, rows: [
            readme_query_execution.User(id: 7, name: "Ada"),
          ]),
        )

      // Act
      let description = readme_query_execution.describe_user(result)

      // Assert
      description
      |> should
      |> be_equal("User 7: Ada")
      |> or_fail_with("Expected User 7: Ada")
    }),
    it("describe_user returns No such user for no rows", fn() {
      // Arrange
      let result = Ok(pog.Returned(count: 0, rows: []))

      // Act
      let description = readme_query_execution.describe_user(result)

      // Assert
      description
      |> should
      |> be_equal("No such user")
      |> or_fail_with("Expected No such user")
    }),
    it("describe_user returns a failure message for a query error", fn() {
      // Arrange
      let result = Error(pog.ConnectionUnavailable)

      // Act
      let description = readme_query_execution.describe_user(result)

      // Assert
      description
      |> should
      |> be_equal("The database query failed")
      |> or_fail_with("Expected The database query failed")
    }),
    it("describe_user_count counts the rows", fn() {
      // Arrange
      let result =
        Ok(
          pog.Returned(count: 2, rows: [
            readme_query_execution.User(id: 1, name: "Ada"),
            readme_query_execution.User(id: 2, name: "Grace"),
          ]),
        )

      // Act
      let description = readme_query_execution.describe_user_count(result)

      // Assert
      description
      |> should
      |> be_equal("2 users")
      |> or_fail_with("Expected 2 users")
    }),
    it("describe_user_count returns a failure message for a query error", fn() {
      // Arrange
      let result = Error(pog.ConnectionUnavailable)

      // Act
      let description = readme_query_execution.describe_user_count(result)

      // Assert
      description
      |> should
      |> be_equal("The database query failed: DatabaseError")
      |> or_fail_with("Expected the failure message with DatabaseError")
    }),
  ])
}

fn connection_builder_tests() {
  group("Connection Builder Pattern", [
    it("production_config sets every value", fn() {
      // Act
      let config = readme_connection_builder.production_config()

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
        "myapp_prod",
        "postgres",
        option.Some("secret"),
        20,
      ))
      |> or_fail_with("Expected every value of the production config")
    }),
    it("connect_production starts the pool", fn() {
      // Act
      let result = readme_connection_builder.connect_production()

      // Assert
      result
      |> result.replace(Nil)
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the production pool to start")
    }),
  ])
}

fn query_result_helper_tests() {
  group("Query Result Helpers", [
    it("user_from_result returns the user of the first row", fn() {
      // Arrange
      let user = readme_query_result_helpers.User(id: 7, name: "Ada")
      let result = Ok(pog.Returned(count: 1, rows: [user]))

      // Act
      let found = readme_query_result_helpers.user_from_result(result)

      // Assert
      found
      |> should
      |> be_equal(Ok(readme_query_result_helpers.User(id: 7, name: "Ada")))
      |> or_fail_with("Expected Ada")
    }),
    it("user_from_result returns User not found for no rows", fn() {
      // Arrange
      let result = Ok(pog.Returned(count: 0, rows: []))

      // Act
      let found = readme_query_result_helpers.user_from_result(result)

      // Assert
      found
      |> should
      |> be_equal(Error("User not found"))
      |> or_fail_with("Expected Error(User not found)")
    }),
    it("user_from_result returns Database error for a query error", fn() {
      // Arrange
      let result = Error(pog.ConnectionUnavailable)

      // Act
      let found = readme_query_result_helpers.user_from_result(result)

      // Assert
      found
      |> should
      |> be_equal(Error("Database error"))
      |> or_fail_with("Expected Error(Database error)")
    }),
    it("user_names_from_result returns every name", fn() {
      // Arrange
      let result =
        Ok(
          pog.Returned(count: 2, rows: [
            readme_query_result_helpers.User(id: 1, name: "Ada"),
            readme_query_result_helpers.User(id: 2, name: "Grace"),
          ]),
        )

      // Act
      let names = readme_query_result_helpers.user_names_from_result(result)

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada", "Grace"]))
      |> or_fail_with("Expected Ada and Grace")
    }),
    it("user_names_from_result returns the error for a query error", fn() {
      // Arrange
      let result = Error(pog.ConnectionUnavailable)

      // Act
      let names = readme_query_result_helpers.user_names_from_result(result)

      // Assert
      names
      |> should
      |> be_equal(Error("Database error: DatabaseError"))
      |> or_fail_with("Expected Error(Database error: DatabaseError)")
    }),
  ])
}

fn error_handling_tests() {
  group("Error Handling", [
    it("explain_query_error explains NotFound", fn() {
      // Act
      let explanation =
        readme_error_handling.explain_query_error(query.NotFound)

      // Assert
      explanation
      |> should
      |> be_equal("The query returned no rows")
      |> or_fail_with("Expected the NotFound explanation")
    }),
    it("explain_query_error explains DatabaseError", fn() {
      // Act
      let explanation =
        readme_error_handling.explain_query_error(query.DatabaseError)

      // Assert
      explanation
      |> should
      |> be_equal("The query failed")
      |> or_fail_with("Expected the DatabaseError explanation")
    }),
  ])
}
