//// Row readers: the check of a reader against the columns of a result,
//// and the read of a row.

import dream_postgres/codec
import dream_postgres/driver/cell.{Binary, BinaryFormat, Null, TextFormat}
import dream_postgres/error.{
  AmbiguousColumnName, ColumnCountMismatch, ColumnReadTwice, ColumnTypeMismatch,
  DecodeFailed, MixedColumnReaders, NoColumnAtPosition, NoColumnNamed,
  ProtocolViolation, ReaderDependsOnValue, UnexpectedNull, ValueOutOfRange,
}
import dream_postgres/row/reader.{column, column_at, column_named, row, single}
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/described_column
import fixtures/type_catalog
import fixtures/user_rows
import fixtures/value_dependent_readers
import gleam/option.{Some}
import matchers/check_row.{check_row}
import matchers/read_row.{read_row}

pub fn tests() -> TestSuite {
  describe("row readers", [
    group("the check", [
      it("gives each column the format of its codec", fn() {
        // Arrange
        let reader = user_rows.reader()

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_ok()
        |> be_equal([BinaryFormat, BinaryFormat, BinaryFormat])
        |> or_fail_with(
          "Expected the binary format for each of the three columns",
        )
      }),
      it("gives text to the columns a reader leaves unread", fn() {
        // Arrange
        let reader = user_rows.score_and_id_reader()

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_ok()
        |> be_equal([BinaryFormat, TextFormat, BinaryFormat])
        |> or_fail_with("Expected the text format for the unread name column")
      }),
      it("refuses a reader of fewer columns than the result", fn() {
        // Arrange
        let reader = single(codec.int)

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(ColumnCountMismatch(expected: 1, got: 3))
        |> or_fail_with("Expected a count mismatch of 1 read and 3 columns")
      }),
      it("refuses a reader of more columns than the result", fn() {
        // Arrange
        let reader = user_rows.reader()

        // Act and assert
        reader
        |> should
        |> check_row([described_column.new("id", type_catalog.int4())])
        |> be_error()
        |> be_equal(ColumnCountMismatch(expected: 3, got: 1))
        |> or_fail_with("Expected a count mismatch of 3 reads and 1 column")
      }),
      it("refuses a codec that does not take the column's type", fn() {
        // Arrange
        let reader = {
          use id <- column(codec.int)
          use name <- column(codec.int)
          use score <- column(codec.numeric)
          row(#(id, name, score))
        }

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(ColumnTypeMismatch(
          position: 2,
          name: "name",
          database_type: "text",
          codec: "int",
        ))
        |> or_fail_with("Expected a type mismatch of the text column 2 and int")
      }),
      it("refuses a position past the last column", fn() {
        // Arrange
        let reader = column_at(4, codec.int, row)

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(NoColumnAtPosition(position: 4, columns: 3))
        |> or_fail_with("Expected no column at the position 4 of 3 columns")
      }),
      it("refuses the position 0", fn() {
        // Arrange
        let reader = column_at(0, codec.int, row)

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(NoColumnAtPosition(position: 0, columns: 3))
        |> or_fail_with("Expected no column at the position 0 of 3 columns")
      }),
      it("refuses a name that no column has", fn() {
        // Arrange
        let reader = column_named("email", codec.text, row)

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(NoColumnNamed("email"))
        |> or_fail_with("Expected no column named email")
      }),
      it("refuses a name that two columns have", fn() {
        // Arrange
        let reader = column_named("id", codec.int, row)

        // Act and assert
        reader
        |> should
        |> check_row([
          described_column.new("id", type_catalog.int4()),
          described_column.new("id", type_catalog.int4()),
        ])
        |> be_error()
        |> be_equal(AmbiguousColumnName(name: "id", count: 2))
        |> or_fail_with("Expected the name id of two columns to be ambiguous")
      }),
      it("refuses a column read two times", fn() {
        // Arrange
        let reader = {
          use first <- column_at(1, codec.int)
          use second <- column_named("id", codec.int)
          row(#(first, second))
        }

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(ColumnReadTwice(position: 1, name: "id"))
        |> or_fail_with("Expected the column 1 (id) to be read two times")
      }),
      it("refuses a reader that mixes column with column_at", fn() {
        // Arrange
        let reader = {
          use id <- column(codec.int)
          use name <- column_at(2, codec.text)
          row(#(id, name))
        }

        // Act and assert
        reader
        |> should
        |> check_row(user_rows.columns())
        |> be_error()
        |> be_equal(MixedColumnReaders)
        |> or_fail_with("Expected MixedColumnReaders for column with column_at")
      }),
    ]),
    group("the read", [
      it("reads every column in order", fn() {
        // Arrange
        let reader = user_rows.reader()

        // Act and assert
        reader
        |> should
        |> read_row(user_rows.columns(), user_rows.cells())
        |> be_ok()
        |> be_equal(#(7, "Ada", "9.5"))
        |> or_fail_with("Expected the row 7, Ada, 9.5")
      }),
      it("reads columns by position and by name", fn() {
        // Arrange
        let reader = user_rows.score_and_id_reader()

        // Act and assert
        reader
        |> should
        |> read_row(user_rows.columns(), user_rows.cells())
        |> be_ok()
        |> be_equal(#("9.5", 7))
        |> or_fail_with(
          "Expected the score 9.5 by position and the id 7 by name",
        )
      }),
      it("reads a single column", fn() {
        // Arrange
        let reader = single(codec.int)

        // Act and assert
        reader
        |> should
        |> read_row([described_column.new("count", type_catalog.int8())], [
          Binary(<<42:size(64)>>),
        ])
        |> be_ok()
        |> be_equal(42)
        |> or_fail_with("Expected the int8 value 42")
      }),
      it("gives UnexpectedNull for a NULL the codec does not take", fn() {
        // Arrange
        let reader = user_rows.reader()

        // Act and assert
        reader
        |> should
        |> read_row(user_rows.columns(), [
          Null,
          Binary(<<"Ada":utf8>>),
          Binary(<<2:16, 0:16, 0:16, 1:16, 9:16, 5000:16>>),
        ])
        |> be_error()
        |> be_equal(UnexpectedNull(position: 1, name: "id"))
        |> or_fail_with("Expected UnexpectedNull for the NULL id in column 1")
      }),
      it("reads a NULL with a nullable codec", fn() {
        // Arrange
        let reader = single(codec.nullable(codec.text))

        // Act and assert
        reader
        |> should
        |> read_row([described_column.new("note", type_catalog.text())], [Null])
        |> be_ok()
        |> be_none()
        |> or_fail_with("Expected None for the NULL note")
      }),
      it("gives ValueOutOfRange for a value the codec cannot hold", fn() {
        // Arrange
        let reader = single(codec.float)

        // Act and assert
        reader
        |> should
        |> read_row([described_column.new("ratio", type_catalog.float8())], [
          Binary(<<0x7FF8000000000000:size(64)>>),
        ])
        |> be_error()
        |> be_equal(ValueOutOfRange(position: 1, name: "ratio", value: "NaN"))
        |> or_fail_with("Expected ValueOutOfRange for the float8 NaN")
      }),
      it("gives DecodeFailed for bytes the codec cannot read", fn() {
        // Arrange
        let reader = single(codec.int)

        // Act and assert
        reader
        |> should
        |> read_row([described_column.new("id", type_catalog.int4())], [
          Binary(<<1, 2, 3>>),
        ])
        |> be_error()
        |> be_equal(DecodeFailed(
          position: 1,
          name: "id",
          reason: "3 bytes are not a int4 value",
        ))
        |> or_fail_with("Expected DecodeFailed for 3 bytes of an int4")
      }),
      it("refuses a row with fewer values than the result has columns", fn() {
        // Arrange
        let reader = user_rows.reader()

        // Act and assert
        reader
        |> should
        |> read_row(user_rows.columns(), [Binary(<<7:size(32)>>)])
        |> be_error()
        |> be_equal(ProtocolViolation(
          "a row has 1 values, and the result has 3 columns",
        ))
        |> or_fail_with(
          "Expected a protocol violation for 1 value of 3 columns",
        )
      }),
      it("reads a branching reader on the branch its check saw", fn() {
        // Arrange
        let reader = value_dependent_readers.branching()

        // Act and assert
        reader
        |> should
        |> read_row(
          [
            described_column.new("kind", type_catalog.int4()),
            described_column.new("name", type_catalog.text()),
          ],
          [Binary(<<0:size(32)>>), Binary(<<"Ada":utf8>>)],
        )
        |> be_ok()
        |> be_equal(#(0, Some("Ada")))
        |> or_fail_with("Expected the kind 0 and the name Ada")
      }),
      it("refuses a reader that stops early for a value", fn() {
        // Arrange
        let reader = value_dependent_readers.branching()

        // Act and assert
        reader
        |> should
        |> read_row(
          [
            described_column.new("kind", type_catalog.int4()),
            described_column.new("name", type_catalog.text()),
          ],
          [Binary(<<1:size(32)>>), Binary(<<"Ada":utf8>>)],
        )
        |> be_error()
        |> be_equal(ReaderDependsOnValue(read: 2))
        |> or_fail_with(
          "Expected ReaderDependsOnValue at read 2 for the kind 1",
        )
      }),
      it("refuses a reader that changes its codec for a value", fn() {
        // Arrange
        let reader = value_dependent_readers.switching()

        // Act and assert
        reader
        |> should
        |> read_row(
          [
            described_column.new("kind", type_catalog.int4()),
            described_column.new("name", type_catalog.text()),
          ],
          [Binary(<<1:size(32)>>), Binary(<<"Ada":utf8>>)],
        )
        |> be_error()
        |> be_equal(ReaderDependsOnValue(read: 2))
        |> or_fail_with(
          "Expected ReaderDependsOnValue at read 2 for a new codec",
        )
      }),
    ]),
  ])
}
