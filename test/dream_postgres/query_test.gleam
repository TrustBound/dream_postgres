//// Queries: the builder, and the check and write of the parameters.

import dream_postgres/codec
import dream_postgres/driver/cell.{Binary, BinaryFormat, Null}
import dream_postgres/error.{
  EncodeFailed, ParameterCountMismatch, ParameterTypeMismatch,
}
import dream_postgres/query/definition.{WrittenParameters}
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/type_catalog
import gleam/option.{None}
import matchers/write_parameters.{write_parameters}

pub fn tests() -> TestSuite {
  describe("queries", [
    group("the builder", [
      it("keeps the SQL", fn() {
        // Arrange
        let subject = definition.query("SELECT 1")

        // Act
        let sql = definition.sql(subject)

        // Assert
        sql
        |> should
        |> be_equal("SELECT 1")
        |> or_fail_with("Expected the SQL that the query was made with")
      }),
      it("has no name until one is given", fn() {
        // Arrange
        let subject = definition.query("SELECT 1")

        // Act
        let name = definition.name(subject)

        // Assert
        name
        |> should
        |> be_none()
        |> or_fail_with("Expected no name for a query that was not named")
      }),
      it("keeps the name", fn() {
        // Arrange
        let subject =
          definition.query("SELECT 1") |> definition.named("post.create")

        // Act
        let name = definition.name(subject)

        // Assert
        name
        |> should
        |> be_some()
        |> be_equal("post.create")
        |> or_fail_with("Expected the name post.create")
      }),
      it("counts the parameters", fn() {
        // Arrange
        let subject =
          definition.query(
            "INSERT INTO posts (user_id, body, score) VALUES ($1, $2, $3)",
          )
          |> definition.parameter(codec.int, 7)
          |> definition.parameter(codec.nullable(codec.text), None)
          |> definition.parameter(codec.numeric, "9.5")

        // Act
        let count = definition.parameter_count(subject)

        // Assert
        count
        |> should
        |> be_equal(3)
        |> or_fail_with("Expected the three parameters of the query")
      }),
    ]),
    group("the parameters", [
      it(
        "writes the parameters in order, each in the format of its bytes",
        fn() {
          // Arrange
          let subject =
            definition.query(
              "INSERT INTO posts (user_id, body, score) VALUES ($1, $2, $3)",
            )
            |> definition.parameter(codec.int, 7)
            |> definition.parameter(codec.nullable(codec.text), None)
            |> definition.parameter(codec.numeric, "9.5")

          // Act and assert
          subject
          |> should
          |> write_parameters([
            type_catalog.int4(),
            type_catalog.text(),
            type_catalog.numeric(),
          ])
          |> be_ok()
          |> be_equal(
            WrittenParameters(
              formats: [BinaryFormat, BinaryFormat, BinaryFormat],
              values: [
                Binary(<<7:size(32)>>),
                Null,
                Binary(<<2:16, 0:16, 0:16, 1:16, 9:16, 5000:16>>),
              ],
            ),
          )
          |> or_fail_with("Expected 7, NULL and 9.5 in binary, in that order")
        },
      ),
      it("refuses fewer parameters than the query has", fn() {
        // Arrange
        let subject = definition.query("SELECT $1, $2")

        // Act and assert
        subject
        |> should
        |> write_parameters([type_catalog.int4(), type_catalog.int4()])
        |> be_error()
        |> be_equal(ParameterCountMismatch(expected: 2, got: 0))
        |> or_fail_with("Expected a count mismatch of 2 expected and 0 given")
      }),
      it("refuses more parameters than the query has", fn() {
        // Arrange
        let subject =
          definition.query(
            "INSERT INTO posts (user_id, body, score) VALUES ($1, $2, $3)",
          )
          |> definition.parameter(codec.int, 7)
          |> definition.parameter(codec.nullable(codec.text), None)
          |> definition.parameter(codec.numeric, "9.5")

        // Act and assert
        subject
        |> should
        |> write_parameters([type_catalog.int4()])
        |> be_error()
        |> be_equal(ParameterCountMismatch(expected: 1, got: 3))
        |> or_fail_with("Expected a count mismatch of 1 expected and 3 given")
      }),
      it("refuses a codec that does not take the parameter's type", fn() {
        // Arrange
        let subject =
          definition.query(
            "INSERT INTO posts (user_id, body, score) VALUES ($1, $2, $3)",
          )
          |> definition.parameter(codec.int, 7)
          |> definition.parameter(codec.nullable(codec.text), None)
          |> definition.parameter(codec.numeric, "9.5")

        // Act and assert
        subject
        |> should
        |> write_parameters([
          type_catalog.int4(),
          type_catalog.int4(),
          type_catalog.numeric(),
        ])
        |> be_error()
        |> be_equal(ParameterTypeMismatch(
          position: 2,
          database_type: "int4",
          codec: "nullable text",
        ))
        |> or_fail_with("Expected nullable text to refuse int4 at position 2")
      }),
      it("refuses a value the codec cannot write", fn() {
        // Arrange
        let subject =
          definition.query("SELECT $1")
          |> definition.parameter(codec.int, 40_000)

        // Act and assert
        subject
        |> should
        |> write_parameters([type_catalog.int2()])
        |> be_error()
        |> be_equal(EncodeFailed(
          position: 1,
          reason: "40000 is out of range for int2",
        ))
        |> or_fail_with("Expected 40000 to be out of range for int2")
      }),
    ]),
  ])
}
