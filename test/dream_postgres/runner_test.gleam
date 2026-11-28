//// The runners against a fake executor: the prepare, the checks, the run
//// and the read of the rows.

import dream_postgres/codec
import dream_postgres/driver/cell.{
  Binary, BinaryFormat, ParameterDescription, StatementDescription, TextFormat,
}
import dream_postgres/error.{
  ColumnCountMismatch, DecodeFailed, ParameterCountMismatch, PostgresError,
  QueryTimeout, StatementChangedDuringRun, TooManyRows,
}
import dream_postgres/query/definition
import dream_postgres/query/runner.{RunFailed, StatementChanged}
import dream_postgres/row/reader.{single}
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/column_description
import fixtures/fake_executor
import fixtures/posts
import gleam/option.{None, Some}

pub fn tests() -> TestSuite {
  describe("runners", [
    it("reads every row", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [
          posts.cells(1, "First"),
          posts.cells(2, "Second"),
        ])

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal([#(1, "First"), #(2, "Second")])
      |> or_fail_with("Expected the posts First and Second")
    }),
    it("sends the written parameters and the formats of the reader", fn() {
      // Arrange
      let executor =
        fake_executor.returning_for(
          posts.statement(),
          [Binary(<<7:size(32)>>)],
          [BinaryFormat, BinaryFormat],
          [posts.cells(1, "First")],
        )

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal([#(1, "First")])
      |> or_fail_with(
        "Expected the post First for the int4 parameter 7 and two binary columns",
      )
    }),
    it("gives the name of the query to the prepare and the run", fn() {
      // Arrange
      let executor =
        fake_executor.returning_for_name(posts.statement(), Some("post.find"), [
          posts.cells(1, "First"),
        ])

      // Act
      let found =
        runner.all(
          posts.query() |> definition.named("post.find"),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal([#(1, "First")])
      |> or_fail_with("Expected the post First for the query named post.find")
    }),
    it("reads the one row", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [posts.cells(1, "First")])

      // Act
      let found =
        runner.one(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal(#(1, "First"))
      |> or_fail_with("Expected the post First")
    }),
    it("gives NotFound with the query's name when one finds no row", fn() {
      // Arrange
      let subject = posts.query() |> definition.named("post.find")
      let executor = fake_executor.returning(posts.statement(), [])

      // Act
      let found =
        runner.one(subject, posts.reader(), runner.DatabaseLayer(executor), [])

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(error.no_rows_error(Some("post.find")))
      |> or_fail_with("Expected NotFound with the name post.find")
    }),
    it("gives None when maybe_one finds no row", fn() {
      // Arrange
      let executor = fake_executor.returning(posts.statement(), [])

      // Act
      let found =
        runner.maybe_one(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_none()
      |> or_fail_with("Expected None for no row")
    }),
    it("gives the row when maybe_one finds one", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [posts.cells(1, "First")])

      // Act
      let found =
        runner.maybe_one(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_some()
      |> be_equal(#(1, "First"))
      |> or_fail_with("Expected Some of the post First")
    }),
    it("refuses more than one row for maybe_one", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [
          posts.cells(1, "First"),
          posts.cells(2, "Second"),
        ])

      // Act
      let found =
        runner.maybe_one(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: TooManyRows(2),
        )),
      )
      |> or_fail_with("Expected TooManyRows(2) for two rows")
    }),
    it("gives the row count of a command", fn() {
      // Arrange
      let subject =
        definition.query("UPDATE posts SET title = title WHERE user_id = $1")
        |> definition.parameter(codec.int, 7)
      let executor =
        fake_executor.returning(
          StatementDescription(
            parameters: [ParameterDescription(23)],
            columns: [],
          ),
          [[], [], []],
        )

      // Act
      let found = runner.affected(subject, runner.DatabaseLayer(executor), [])

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal(3)
      |> or_fail_with("Expected the row count 3")
    }),
    it(
      "asks for text for each column of a command, and describes every part of each type",
      fn() {
        // Arrange
        let subject = definition.query("SELECT ...")
        let executor =
          fake_executor.returning_for(
            StatementDescription(parameters: [], columns: [
              column_description.new("numbers", 1007),
              column_description.new("amount", 90_005),
              column_description.new("span", 4451),
              column_description.new("pair", 90_301),
              column_description.new("id", 23),
            ]),
            [],
            [TextFormat, TextFormat, TextFormat, TextFormat, TextFormat],
            [[]],
          )

        // Act
        let found = runner.affected(subject, runner.DatabaseLayer(executor), [])

        // Assert
        found
        |> should
        |> be_ok()
        |> be_equal(1)
        |> or_fail_with(
          "Expected the row count 1 for the text format of all five columns",
        )
      },
    ),
    it("gives the failure of the prepare", fn() {
      // Arrange
      let executor =
        fake_executor.failing_prepare(QueryTimeout(stopped_on_server: True))

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: QueryTimeout(stopped_on_server: True),
        )),
      )
      |> or_fail_with(
        "Expected the QueryTimeout(stopped_on_server: True) of the prepare",
      )
    }),
    it("gives the failure of a type description", fn() {
      // Arrange
      let subject = definition.query("SELECT 1")
      let executor =
        fake_executor.returning(
          StatementDescription(parameters: [], columns: [
            column_description.new("x", 999),
          ]),
          [],
        )

      // Act
      let found =
        runner.all(
          subject,
          single(codec.int),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some("SELECT 1"),
          reason: QueryTimeout(stopped_on_server: True),
        )),
      )
      |> or_fail_with(
        "Expected the QueryTimeout(stopped_on_server: True) of the description of type 999",
      )
    }),
    it("refuses parameters that do not fit the statement, before the run", fn() {
      // Arrange
      let subject = definition.query(posts.sql())
      let executor =
        fake_executor.returning(posts.statement(), [posts.cells(1, "First")])

      // Act
      let found =
        runner.all(subject, posts.reader(), runner.DatabaseLayer(executor), [])

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: ParameterCountMismatch(expected: 1, got: 0),
        )),
      )
      |> or_fail_with("Expected a count mismatch of 1 expected and 0 given")
    }),
    it("refuses a reader that does not fit the statement, before the run", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [posts.cells(1, "First")])

      // Act
      let found =
        runner.all(
          posts.query(),
          single(codec.int),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: ColumnCountMismatch(expected: 1, got: 2),
        )),
      )
      |> or_fail_with("Expected a count mismatch of 1 read and 2 columns")
    }),
    it("gives the failure of the run", fn() {
      // Arrange
      let executor =
        fake_executor.failing_run(
          posts.statement(),
          RunFailed(QueryTimeout(stopped_on_server: True)),
        )

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: QueryTimeout(stopped_on_server: True),
        )),
      )
      |> or_fail_with(
        "Expected the QueryTimeout(stopped_on_server: True) of the run",
      )
    }),
    it("runs again with the changed description", fn() {
      // Arrange
      let changed_statement =
        StatementDescription(parameters: [ParameterDescription(20)], columns: [
          column_description.new("id", 23),
        ])
      let executor =
        fake_executor.failing_for_parameters(
          StatementDescription(parameters: [ParameterDescription(23)], columns: [
            column_description.new("id", 23),
          ]),
          [Binary(<<7:size(32)>>)],
          StatementChanged(changed_statement),
          [[Binary(<<1:size(32)>>)]],
        )

      // Act
      let found =
        runner.all(
          posts.query(),
          single(codec.int),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_ok()
      |> be_equal([1])
      |> or_fail_with("Expected the row 1 from the run with the int8 parameter")
    }),
    it("asks for a retry when the statement changes two times", fn() {
      // Arrange
      let executor =
        fake_executor.failing_run(
          posts.statement(),
          StatementChanged(posts.statement()),
        )

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: StatementChangedDuringRun,
        )),
      )
      |> or_fail_with("Expected StatementChangedDuringRun after two changes")
    }),
    it("gives the failure of a row read", fn() {
      // Arrange
      let executor =
        fake_executor.returning(posts.statement(), [
          [Binary(<<1>>), Binary(<<"x":utf8>>)],
        ])

      // Act
      let found =
        runner.all(
          posts.query(),
          posts.reader(),
          runner.DatabaseLayer(executor),
          [],
        )

      // Assert
      found
      |> should
      |> be_error()
      |> be_equal(
        error.postgres_error_to_dream_error(PostgresError(
          query_name: None,
          sql: Some(posts.sql()),
          reason: DecodeFailed(
            position: 1,
            name: "id",
            reason: "1 bytes are not a int4 value",
          ),
        )),
      )
      |> or_fail_with("Expected DecodeFailed for 1 byte of the int4 id")
    }),
  ])
}
