//// Tests for `dream_postgres/query`.
////
//// The query helpers take a Pog result value, so these tests build the
//// results by hand and need no database.

import dream_postgres/query
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import pog

pub fn tests() -> TestSuite {
  describe("dream_postgres/query", [
    group("first_row", [
      it("returns the first row when the result has rows", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 2, rows: [42, 43]))

        // Act
        let row = query.first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Ok(42))
        |> or_fail_with("Expected the first row, 42")
      }),
      it("returns NotFound when the result has no rows", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 0, rows: []))

        // Act
        let row: Result(Int, query.QueryError) = query.first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Error(query.NotFound))
        |> or_fail_with("Expected Error(NotFound)")
      }),
      it("returns DatabaseError when the query failed", fn() {
        // Arrange
        let result = Error(pog.ConnectionUnavailable)

        // Act
        let row: Result(Int, query.QueryError) = query.first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Error(query.DatabaseError))
        |> or_fail_with("Expected Error(DatabaseError)")
      }),
    ]),
    group("all_rows", [
      it("returns every row when the result has rows", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 3, rows: [1, 2, 3]))

        // Act
        let rows = query.all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Ok([1, 2, 3]))
        |> or_fail_with("Expected all three rows")
      }),
      it("returns an empty list when the result has no rows", fn() {
        // Arrange
        let result = Ok(pog.Returned(count: 0, rows: []))

        // Act
        let rows: Result(List(Int), query.QueryError) = query.all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Ok([]))
        |> or_fail_with("Expected Ok([])")
      }),
      it("returns DatabaseError when the query failed", fn() {
        // Arrange
        let result = Error(pog.ConnectionUnavailable)

        // Act
        let rows: Result(List(Int), query.QueryError) = query.all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Error(query.DatabaseError))
        |> or_fail_with("Expected Error(DatabaseError)")
      }),
    ]),
  ])
}
