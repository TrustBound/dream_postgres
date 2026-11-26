//// Tests for `dream_postgres/query`.
////
//// The query helpers take a Pog result value, so these tests build the
//// results by hand and need no database.

import dream_errors.{Failed}
import dream_postgres/query.{
  type QueryError, DatabaseError, all_rows, first_row, to_error,
}
import dream_postgres_client.{ConnectionUnavailable, Returned}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}

pub fn tests() -> TestSuite {
  describe("dream_postgres/query", [
    group("first_row", [
      it("returns the first row when the result has rows", fn() {
        // Arrange
        let result = Ok(Returned(count: 2, rows: [42, 43]))

        // Act
        let row = first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Ok(42))
        |> or_fail_with("Expected the first row, 42")
      }),
      it("returns NotFound when the result has no rows", fn() {
        // Arrange
        let result = Ok(Returned(count: 0, rows: []))

        // Act
        let row: Result(Int, QueryError) = first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Error(query.NotFound))
        |> or_fail_with("Expected Error(NotFound)")
      }),
      it("returns DatabaseError when the query failed", fn() {
        // Arrange
        let result = Error(ConnectionUnavailable)

        // Act
        let row: Result(Int, QueryError) = first_row(result)

        // Assert
        row
        |> should
        |> be_equal(Error(DatabaseError))
        |> or_fail_with("Expected Error(DatabaseError)")
      }),
    ]),
    group("all_rows", [
      it("returns every row when the result has rows", fn() {
        // Arrange
        let result = Ok(Returned(count: 3, rows: [1, 2, 3]))

        // Act
        let rows = all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Ok([1, 2, 3]))
        |> or_fail_with("Expected all three rows")
      }),
      it("returns an empty list when the result has no rows", fn() {
        // Arrange
        let result = Ok(Returned(count: 0, rows: []))

        // Act
        let rows: Result(List(Int), QueryError) = all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Ok([]))
        |> or_fail_with("Expected Ok([])")
      }),
      it("returns DatabaseError when the query failed", fn() {
        // Arrange
        let result = Error(ConnectionUnavailable)

        // Act
        let rows: Result(List(Int), QueryError) = all_rows(result)

        // Assert
        rows
        |> should
        |> be_equal(Error(DatabaseError))
        |> or_fail_with("Expected Error(DatabaseError)")
      }),
    ]),
    group("to_error", [
      it("gives NotFound for NotFound", fn() {
        // Act
        let error = to_error(query.NotFound)

        // Assert
        error
        |> should
        |> be_equal(dream_errors.NotFound("the query returned no rows"))
        |> or_fail_with("Expected the shared NotFound")
      }),
      it("gives Failed with the cause Nil for DatabaseError", fn() {
        // Act
        let error = to_error(DatabaseError)

        // Assert
        error
        |> should
        |> be_equal(Failed("the query failed", Nil))
        |> or_fail_with("Expected the shared Failed")
      }),
    ]),
  ])
}
