//// The keys of a recorder, on requests with cells that are written
//// already, with no database.

import dream_postgres/interceptor.{CopyTo, Request, Sql}
import dream_postgres/internal/cell.{Binary, Null, Text}
import dream_postgres/recorder/match
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/normalize_inputs
import gleam/option.{None}

/// The key tests, with no database.
pub fn tests() -> TestSuite {
  describe("match", [
    it("sql_and_parameters keys a binary parameter by its type and bytes", fn() {
      // Act and assert
      normalize_inputs.statement("SELECT $1", [
        normalize_inputs.written("int4", Binary(<<1:32>>)),
      ])
      |> match.sql_and_parameters
      |> should
      |> be_equal("statement\nSELECT $1\n$1 int4 binary 00000001")
      |> or_fail_with("Expected the type and the hex of the cell")
    }),
    it("sql_and_parameters keys a text parameter by its type and bytes", fn() {
      // Act and assert
      normalize_inputs.statement("SELECT $1", [
        normalize_inputs.written("text", Text(<<"ab":utf8>>)),
      ])
      |> match.sql_and_parameters
      |> should
      |> be_equal("statement\nSELECT $1\n$1 text text 6162")
      |> or_fail_with("Expected the type and the hex of the text cell")
    }),
    it("sql_and_parameters keys a NULL parameter by its type", fn() {
      // Act and assert
      normalize_inputs.statement("SELECT $1", [
        normalize_inputs.written("int4", Null),
      ])
      |> match.sql_and_parameters
      |> should
      |> be_equal("statement\nSELECT $1\n$1 int4 null")
      |> or_fail_with("Expected the NULL")
    }),
    it("sql_and_parameters keys a secret parameter by its codec only", fn() {
      // Act and assert
      normalize_inputs.statement("SELECT $1", normalize_inputs.written_secret())
      |> match.sql_and_parameters
      |> should
      |> be_equal("statement\nSELECT $1\n$1 secret text")
      |> or_fail_with("Expected the codec of the secret and no value")
    }),
    it("sql_and_parameters keys each written row of a COPY FROM", fn() {
      // Act and assert
      normalize_inputs.copy_from([
        [normalize_inputs.written("int4", Binary(<<1:32>>))],
        [normalize_inputs.written("int4", Null)],
      ])
      |> match.sql_and_parameters
      |> should
      |> be_equal(
        "copy_from\nCOPY items FROM STDIN\nrow 1 int4 binary 00000001\nrow 2 int4 null",
      )
      |> or_fail_with("Expected a line for each row")
    }),
    it("sql_only keys a statement by its SQL alone", fn() {
      // Act and assert
      normalize_inputs.statement("SELECT $1", [
        normalize_inputs.written("int4", Binary(<<1:32>>)),
      ])
      |> match.sql_only
      |> should
      |> be_equal("statement\nSELECT $1")
      |> or_fail_with("Expected the kind and the SQL")
    }),
    it("sql_only keys a `run_sql` call by its kind and SQL", fn() {
      // Act and assert
      Request(sql: "SELECT 1", name: None, parameters: [], kind: Sql)
      |> match.sql_only
      |> should
      |> be_equal("sql\nSELECT 1")
      |> or_fail_with("Expected the kind sql")
    }),
    it("sql_only keys a COPY TO by its kind and SQL", fn() {
      // Act and assert
      Request(sql: "SELECT 1", name: None, parameters: [], kind: CopyTo)
      |> match.sql_only
      |> should
      |> be_equal("copy_to\nSELECT 1")
      |> or_fail_with("Expected the kind copy_to")
    }),
  ])
}
