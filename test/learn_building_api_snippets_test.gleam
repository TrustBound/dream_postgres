//// Tests for the dream_postgres snippet in Dream's
//// docs/learn/02-building-api.md.
////
//// These tests need no database: they check the config that the snippet
//// builds and that initialize_services starts the pool. The pool connects
//// in the background, so pool start returns Ok with no database.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/option.{Some}
import gleam/result
import snippets/learn_building_api_services

pub fn tests() -> TestSuite(Nil) {
  describe("learn: building an API snippets", [
    it("create_database_config sets the host", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.host
      |> should
      |> be_equal("localhost")
      |> or_fail_with("Expected host localhost")
    }),
    it("create_database_config sets the port", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.port
      |> should
      |> be_equal(5432)
      |> or_fail_with("Expected port 5432")
    }),
    it("create_database_config sets the database", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.database
      |> should
      |> be_equal("myapp")
      |> or_fail_with("Expected database myapp")
    }),
    it("create_database_config sets the user", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.user
      |> should
      |> be_equal("postgres")
      |> or_fail_with("Expected user postgres")
    }),
    it("create_database_config sets the password", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.password
      |> should
      |> be_equal(Some("postgres"))
      |> or_fail_with("Expected password postgres")
    }),
    it("create_database_config sets the pool size", fn() {
      // Act
      let config = learn_building_api_services.create_database_config()

      // Assert
      config.pool_size
      |> should
      |> be_equal(10)
      |> or_fail_with("Expected pool size 10")
    }),
    it("initialize_services starts the pool", fn() {
      // Act
      let result = learn_building_api_services.initialize_services()

      // Assert
      result
      |> result.replace(Nil)
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the services to start")
    }),
  ])
}
