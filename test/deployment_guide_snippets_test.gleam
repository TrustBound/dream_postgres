//// Tests for the connection pool snippet in Dream's
//// docs/guides/deployment.md.
////
//// The test needs no database: it checks the config that the snippet
//// makes.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/deployment_guide_postgres

pub fn tests() -> TestSuite(Nil) {
  describe("deployment guide snippets", [
    it("create_database_config sets pool size 15", fn() {
      // Act
      let config = deployment_guide_postgres.create_database_config()

      // Assert
      config.pool_size
      |> should
      |> be_equal(15)
      |> or_fail_with("Expected pool size 15")
    }),
  ])
}
