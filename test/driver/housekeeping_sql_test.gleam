//// Tests for `dream_postgres/driver/housekeeping_sql`: the exact bytes of
//// each statement of the closed set, in both protocols. So no value has a
//// zero byte, and each fits the length field. A new value of the module
//// joins both lists here.

import dream_postgres/driver/housekeeping_sql.{
  catalog_load, health_check, prepare_and_run_messages, query_message, rollback,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/list.{map}

/// The text of the catalog load, as the protocol must carry it.
const catalog_load_text =
  "SELECT 'type', t.oid, NULL::float8, n.nspname::text, t.typname::text, t.typtype::text, t.typcategory::text, t.typelem::text, t.typbasetype::text, COALESCE(r.rngsubtype, 0)::text, COALESCE(m.rngtypid, 0)::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace LEFT JOIN pg_range r ON r.rngtypid = t.oid LEFT JOIN pg_range m ON m.rngmultitypid = t.oid UNION ALL SELECT 'label', e.enumtypid, e.enumsortorder::float8, e.enumlabel::text, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM pg_enum e UNION ALL SELECT 'field', t.oid, a.attnum::float8, a.attname::text, a.atttypid::text, NULL, NULL, NULL, NULL, NULL, NULL FROM pg_type t JOIN pg_attribute a ON a.attrelid = t.typrelid WHERE t.typtype = 'c' AND a.attnum > 0 AND NOT a.attisdropped ORDER BY 1, 2, 3"

/// The tests of the housekeeping statements.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/housekeeping_sql", [
    it("writes each housekeeping statement as one Query message", fn() {
      // Arrange
      let statements = [catalog_load, health_check, rollback]

      // Act
      let messages = map(statements, query_message)

      // Assert
      messages
      |> should
      |> be_equal([
        <<"Q", 766:32, catalog_load_text:utf8, 0>>,
        <<"Q", 13:32, "SELECT 1":utf8, 0>>,
        <<"Q", 13:32, "ROLLBACK":utf8, 0>>,
      ])
      |> or_fail_with("Expected one Query message for each statement")
    }),
    it(
      "writes each housekeeping statement as Parse, Bind, Describe, Execute and Sync",
      fn() {
        // Arrange
        let statements = [catalog_load, health_check, rollback]

        // Act
        let messages = map(statements, prepare_and_run_messages)

        // Assert
        messages
        |> should
        |> be_equal([
          <<
            "P", 769:32, 0, catalog_load_text:utf8, 0, 0:16, "B", 12:32, 0, 0,
            0:16, 0:16, 0:16, "D", 6:32, "P", 0, "E", 9:32, 0, 0:32, "S", 4:32,
          >>,
          <<
            "P", 16:32, 0, "SELECT 1":utf8, 0, 0:16, "B", 12:32, 0, 0, 0:16,
            0:16, 0:16, "D", 6:32, "P", 0, "E", 9:32, 0, 0:32, "S", 4:32,
          >>,
          <<
            "P", 16:32, 0, "ROLLBACK":utf8, 0, 0:16, "B", 12:32, 0, 0, 0:16,
            0:16, 0:16, "D", 6:32, "P", 0, "E", 9:32, 0, 0:32, "S", 4:32,
          >>,
        ])
        |> or_fail_with("Expected the five messages for each statement")
      },
    ),
  ])
}
