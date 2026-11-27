//// Tests for `dream_postgres/driver/statement_cache`, the pure cache of
//// named statements of one connection.

import dream_postgres/driver/statement_cache.{
  CachedStatement, forget, insert, lookup, make_room, new, new_name, take_stale,
}
import dream_postgres/internal/cell.{StatementDescription}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/option.{None, Some}

const description = StatementDescription(parameters: [], columns: [])

/// The tests of the statement cache.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/statement_cache", [
    it("finds a statement by its SQL", fn() {
      // Arrange
      let cache = new(2) |> insert("SELECT 1", "s1", description)

      // Act
      let #(_cache, found) = lookup(cache, "SELECT 1")

      // Assert
      found
      |> should
      |> be_equal(Some(CachedStatement("s1", description)))
      |> or_fail_with("Expected the statement s1")
    }),
    it("gives a new name each time", fn() {
      // Arrange
      let #(cache, first) = new_name(new(2))

      // Act
      let #(_cache, second) = new_name(cache)

      // Assert
      #(first, second)
      |> should
      |> be_equal(#("dream_postgres_1", "dream_postgres_2"))
      |> or_fail_with("Expected two names")
    }),
    it("makes room by the least recently used, whichever comes first", fn() {
      // Arrange
      let cache =
        new(3)
        |> insert("a", "s1", description)
        |> insert("b", "s2", description)
        |> insert("c", "s3", description)
      let #(cache, _found) = lookup(cache, "a")
      let #(cache, _found) = lookup(cache, "c")

      // Act
      let #(_cache, closing) = take_stale(make_room(cache))

      // Assert
      closing
      |> should
      |> be_equal(["s2"])
      |> or_fail_with("Expected b, the least recently used, to leave")
    }),
    it("keeps all statements while there is room", fn() {
      // Arrange
      let cache = new(3) |> insert("a", "s1", description)

      // Act
      let #(_cache, closing) = take_stale(make_room(cache))

      // Assert
      closing
      |> should
      |> be_equal([])
      |> or_fail_with("Expected no statement to leave")
    }),
    it("forgets a statement and keeps its name to close", fn() {
      // Arrange
      let cache = new(2) |> insert("a", "s1", description) |> forget("a")

      // Act
      let #(cache, closing) = take_stale(cache)
      let #(_cache, found) = lookup(cache, "a")

      // Assert
      #(closing, found)
      |> should
      |> be_equal(#(["s1"], None))
      |> or_fail_with("Expected the name s1 to close and no statement")
    }),
    it("changes nothing when it forgets SQL that it does not hold", fn() {
      // Arrange
      let cache = new(2) |> forget("missing")

      // Act
      let #(_cache, closing) = take_stale(cache)

      // Assert
      closing
      |> should
      |> be_equal([])
      |> or_fail_with("Expected nothing to close")
    }),
  ])
}
