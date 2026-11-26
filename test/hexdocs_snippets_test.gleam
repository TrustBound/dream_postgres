//// Tests for the code examples in the hexdocs of `dream_postgres/client`
//// and `dream_postgres/query`.
////
//// The `connect` example starts a pool for localhost:5432. The pool
//// connects in the background, so the test needs no database.

import dream_errors.{NotFound}
import dream_postgres/client as postgres
import dream_postgres_client.{Returned}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_url
import fixtures/test_database
import gleam/erlang/process
import gleam/option.{Some}
import gleam/result
import snippets/client_check
import snippets/client_connect
import snippets/client_database
import snippets/client_from_url
import snippets/client_host
import snippets/client_new
import snippets/client_parse_config
import snippets/client_password
import snippets/client_pool_size
import snippets/client_port
import snippets/client_user
import snippets/query_all_rows
import snippets/query_first_row
import snippets/query_to_error.{find_name}

pub fn tests() -> TestSuite {
  describe("hexdocs snippets", [client_tests(), query_tests()])
}

fn client_tests() {
  group("dream_postgres/client", [
    it("client_new.create_config keeps the default port", fn() {
      // Act
      let config = client_new.create_config()

      // Assert
      config.port
      |> should
      |> be_equal(5432)
      |> or_fail_with("Expected the default port 5432")
    }),
    it("client_host.use_local_host sets the host", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_host.use_local_host(config)

      // Assert
      updated.host
      |> should
      |> be_equal("localhost")
      |> or_fail_with("Expected the host localhost")
    }),
    it("client_port.use_default_port sets the port", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_port.use_default_port(config)

      // Assert
      updated.port
      |> should
      |> be_equal(5432)
      |> or_fail_with("Expected the port 5432")
    }),
    it("client_database.use_production_database sets the database", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_database.use_production_database(config)

      // Assert
      updated.database
      |> should
      |> be_equal("myapp_prod")
      |> or_fail_with("Expected the database myapp_prod")
    }),
    it("client_user.use_postgres_user sets the user", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_user.use_postgres_user(config)

      // Assert
      updated.user
      |> should
      |> be_equal("postgres")
      |> or_fail_with("Expected the user postgres")
    }),
    it("client_password.use_password sets the password", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_password.use_password(config)

      // Assert
      updated.password
      |> should
      |> be_equal(Some("secret123"))
      |> or_fail_with("Expected the password Some(secret123)")
    }),
    it("client_pool_size.allow_twenty_connections sets the pool size", fn() {
      // Arrange
      let config = postgres.new(process.new_name("hexdocs_test_pool"))

      // Act
      let updated = client_pool_size.allow_twenty_connections(config)

      // Assert
      updated.pool_size
      |> should
      |> be_equal(20)
      |> or_fail_with("Expected the pool size 20")
    }),
    it(
      "client_connect.connect_database returns a connection to the named pool",
      fn() {
        // Arrange
        let pool_name = process.new_name("hexdocs_test_pool")

        // Act
        let result = client_connect.connect_database(pool_name)

        // Assert
        result
        |> should
        |> be_equal(Ok(dream_postgres_client.named_connection(pool_name)))
        |> or_fail_with("Expected a connection to the named pool")
      },
    ),
    it("client_parse_config.read_database_url reads every value", fn() {
      // Arrange
      let pool_name = process.new_name("hexdocs_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> postgres.user("user")
        |> postgres.password("pass")

      // Act
      let config = client_parse_config.read_database_url(pool_name)

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected every value of the URL")
    }),
    it("client_from_url.describe_connection says the pool started", fn() {
      // Arrange
      let url = database_url.unused_database_url()

      // Act
      let description = client_from_url.describe_connection(url)

      // Assert
      description
      |> should
      |> be_equal("The pool started")
      |> or_fail_with("Expected The pool started")
    }),
    it("client_from_url.describe_connection describes an invalid URL", fn() {
      // Act
      let description =
        client_from_url.describe_connection("postgresql://localhost")

      // Assert
      description
      |> should
      |> be_equal("Invalid URL: MissingDatabase")
      |> or_fail_with("Expected Invalid URL: MissingDatabase")
    }),
    it("client_check.describe_database says the database answers", fn() {
      // Act
      let description = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url())
        |> result.map(client_check.describe_database)
      }

      // Assert
      description
      |> should
      |> be_equal(Ok("The database answers"))
      |> or_fail_with("Expected The database answers")
    }),
    it(
      "client_check.describe_database gives ConnectionUnavailable when no database listens",
      fn() {
        // Act
        let description = {
          use <- test_database.with_own_pools()
          postgres.from_url(database_url.unused_database_url())
          |> result.map(client_check.describe_database)
        }

        // Assert
        description
        |> should
        |> be_equal(Ok("The database did not answer: ConnectionUnavailable"))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
  ])
}

fn query_tests() {
  group("dream_postgres/query", [
    it("query_first_row.find_name returns the first name", fn() {
      // Arrange
      let result =
        Ok(dream_postgres_client.Returned(count: 2, rows: ["Ada", "Grace"]))

      // Act
      let name = query_first_row.find_name(result)

      // Assert
      name
      |> should
      |> be_equal(Ok("Ada"))
      |> or_fail_with("Expected Ok(Ada)")
    }),
    it("query_first_row.find_name returns User not found for no rows", fn() {
      // Arrange
      let result = Ok(dream_postgres_client.Returned(count: 0, rows: []))

      // Act
      let name = query_first_row.find_name(result)

      // Assert
      name
      |> should
      |> be_equal(Error("User not found"))
      |> or_fail_with("Expected Error(User not found)")
    }),
    it(
      "query_first_row.find_name returns Database error for a query error",
      fn() {
        // Arrange
        let result = Error(dream_postgres_client.ConnectionUnavailable)

        // Act
        let name = query_first_row.find_name(result)

        // Assert
        name
        |> should
        |> be_equal(Error("Database error"))
        |> or_fail_with("Expected Error(Database error)")
      },
    ),
    it("query_all_rows.find_names returns every name", fn() {
      // Arrange
      let result =
        Ok(dream_postgres_client.Returned(count: 2, rows: ["Ada", "Grace"]))

      // Act
      let names = query_all_rows.find_names(result)

      // Assert
      names
      |> should
      |> be_equal(Ok(["Ada", "Grace"]))
      |> or_fail_with("Expected Ada and Grace")
    }),
    it("query_all_rows.find_names returns the error for a query error", fn() {
      // Arrange
      let result = Error(dream_postgres_client.ConnectionUnavailable)

      // Act
      let names = query_all_rows.find_names(result)

      // Assert
      names
      |> should
      |> be_equal(Error("Database error: DatabaseError"))
      |> or_fail_with("Expected Error(Database error: DatabaseError)")
    }),
    it("query_to_error.find_name returns the first name", fn() {
      // Arrange
      let result = Ok(Returned(count: 1, rows: ["Ada"]))

      // Act
      let name = find_name(result)

      // Assert
      name
      |> should
      |> be_equal(Ok("Ada"))
      |> or_fail_with("Expected Ok(Ada)")
    }),
    it("query_to_error.find_name gives NotFound for no rows", fn() {
      // Arrange
      let result = Ok(Returned(count: 0, rows: []))

      // Act
      let name = find_name(result)

      // Assert
      name
      |> should
      |> be_equal(Error(NotFound("the query returned no rows")))
      |> or_fail_with("Expected the shared NotFound")
    }),
  ])
}
