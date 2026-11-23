//// Connecting guide: Test your code
////
//// Tests the config that a URL gives, the message for a bad URL, and a pool
//// on a port where no database listens.

import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/erlang/process
import gleam/result
import pog
import snippets/guide_connecting_pool_config.{connect_pool, pool_config}

pub fn tests() -> TestSuite {
  describe("my app's database connection", [
    it("reads the host, the SSL mode and the pool size", fn() {
      // Arrange
      let pool_name = process.new_name("test_database")
      let url = "postgresql://app:secret@db.internal/app?sslmode=verify-full"

      // Act
      let config = pool_config(pool_name, url, 25)

      // Assert
      config
      |> result.map(fn(config) { #(config.host, config.ssl, config.pool_size) })
      |> should
      |> be_equal(Ok(#("db.internal", pog.SslVerified, 25)))
      |> or_fail_with("Expected the host, SSL and pool size")
    }),
    it("explains a URL with a parameter it does not support", fn() {
      // Arrange
      let url = "postgresql://app:secret@db.internal/app?connect_timeout=10"

      // Act
      let connected = connect_pool(url, 25)

      // Assert
      connected
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(
        "DATABASE_URL has the parameter connect_timeout. Remove it.",
      ))
      |> or_fail_with("Expected the unsupported parameter")
    }),
    it("gives ConnectionUnavailable when no database listens", fn() {
      // Arrange
      // Nothing listens on port 1 of this machine
      let assert Ok(db) =
        connect_pool("postgresql://app:secret@127.0.0.1:1/app", 2)

      // Act
      let answer = postgres.check(db)

      // Assert
      answer
      |> should
      |> be_equal(Error(pog.ConnectionUnavailable))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
  ])
}
