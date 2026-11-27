//// Tests for `dream_postgres/driver/catalog_table`, the pure table of type
//// descriptions, with rows in the shape of the catalog query.

import dream_postgres/driver/catalog_table.{
  type CatalogTable, type RowError, CircularDomain, MissingPart, UnknownTypeKind,
  UnreadableRow, empty, find, find_underlying, from_rows,
}
import dream_postgres/internal/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, Composite, Domain, Enum,
  Multirange, Null, Pseudo, Range, Text, TypeDescription,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array
import gleam/int.{to_string}
import gleam/option.{type Option, None, Some}
import gleam/result

/// The tests of the table of type descriptions.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/catalog_table", [
    group("kinds", kind_tests()),
    group("lookups", lookup_tests()),
    group("errors", error_tests()),
  ])
}

// Rows ------------------------------------------------------------------------

fn text(value: String) -> Cell {
  Text(bit_array.from_string(value))
}

fn number(value: Int) -> Cell {
  text(to_string(value))
}

/// A type row with no element, base, subtype or range.
fn type_row(
  id: Int,
  name: String,
  kind: String,
  category: String,
) -> List(Cell) {
  type_row_with(id, name, kind, category, #(0, 0, 0, 0))
}

/// A type row with its element, base, subtype and range OIDs.
fn type_row_with(
  id: Int,
  name: String,
  kind: String,
  category: String,
  parts: #(Int, Int, Int, Int),
) -> List(Cell) {
  [
    text("type"),
    number(id),
    Null,
    text("pg_catalog"),
    text(name),
    text(kind),
    text(category),
    number(parts.0),
    number(parts.1),
    number(parts.2),
    number(parts.3),
  ]
}

fn label_row(type_id: Int, position: String, label: String) -> List(Cell) {
  [
    text("label"),
    number(type_id),
    text(position),
    text(label),
    Null,
    Null,
    Null,
    Null,
    Null,
    Null,
    Null,
  ]
}

fn field_row(
  type_id: Int,
  position: String,
  name: String,
  field_type_id: Int,
) -> List(Cell) {
  [
    text("field"),
    number(type_id),
    text(position),
    text(name),
    number(field_type_id),
    Null,
    Null,
    Null,
    Null,
    Null,
    Null,
  ]
}

fn int4_row() -> List(Cell) {
  type_row(23, "int4", "b", "N")
}

fn found(
  rows: List(List(Cell)),
  type_id: Int,
) -> Result(Option(TypeDescription), RowError) {
  from_rows(rows) |> result.map(find(_, type_id))
}

fn found_underlying(
  rows: List(List(Cell)),
  type_id: Int,
) -> Result(Option(TypeDescription), RowError) {
  from_rows(rows) |> result.map(find_underlying(_, type_id))
}

fn pg_catalog_type(id: Int, name: String, kind: cell.TypeKind) {
  Ok(Some(TypeDescription(id:, schema: "pg_catalog", name:, kind:)))
}

// Kinds -----------------------------------------------------------------------

fn kind_tests() {
  [
    it("reads a base type", fn() {
      // Arrange
      let rows = [int4_row()]

      // Act
      let description = found(rows, 23)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(23, "int4", Base))
      |> or_fail_with("Expected int4 as a base type")
    }),
    it("reads an array as the array of its element", fn() {
      // Arrange
      let rows = [
        int4_row(),
        type_row_with(1007, "_int4", "b", "A", #(23, 0, 0, 0)),
      ]

      // Act
      let description = found(rows, 1007)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(1007, "_int4", Array(23)))
      |> or_fail_with("Expected _int4 as an array of int4")
    }),
    it(
      "reads a base type with an element outside the category A as a base type",
      fn() {
        // Arrange
        let rows = [
          type_row(701, "float8", "b", "N"),
          type_row_with(600, "point", "b", "G", #(701, 0, 0, 0)),
        ]

        // Act
        let description = found(rows, 600)

        // Assert
        description
        |> should
        |> be_equal(pg_catalog_type(600, "point", Base))
        |> or_fail_with("Expected point as a base type")
      },
    ),
    it("reads a composite with its fields in order", fn() {
      // Arrange
      let rows = [
        type_row(16, "bool", "b", "B"),
        int4_row(),
        type_row(900, "pair", "c", "C"),
        field_row(900, "1", "a", 23),
        field_row(900, "3", "c", 16),
      ]

      // Act
      let description = found(rows, 900)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(
        900,
        "pair",
        Composite([#("a", 23), #("c", 16)]),
      ))
      |> or_fail_with("Expected the fields a and c in order")
    }),
    it("reads a composite with no field", fn() {
      // Arrange
      let rows = [type_row(901, "nothing", "c", "C")]

      // Act
      let description = found(rows, 901)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(901, "nothing", Composite([])))
      |> or_fail_with("Expected a composite with no field")
    }),
    it("reads an enum with its labels in order", fn() {
      // Arrange
      let rows = [
        type_row(902, "mood", "e", "E"),
        label_row(902, "1", "sad"),
        label_row(902, "1.5", "calm"),
        label_row(902, "2", "happy"),
      ]

      // Act
      let description = found(rows, 902)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(902, "mood", Enum(["sad", "calm", "happy"])))
      |> or_fail_with("Expected the labels in order")
    }),
    it("reads a domain with its own base type", fn() {
      // Arrange
      let rows = [
        int4_row(),
        type_row_with(903, "positive", "d", "N", #(0, 23, 0, 0)),
      ]

      // Act
      let description = found(rows, 903)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(903, "positive", Domain(23)))
      |> or_fail_with("Expected a domain over int4")
    }),
    it("reads a range with its subtype", fn() {
      // Arrange
      let rows = [
        int4_row(),
        type_row_with(3904, "int4range", "r", "R", #(0, 0, 23, 0)),
      ]

      // Act
      let description = found(rows, 3904)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(3904, "int4range", Range(23)))
      |> or_fail_with("Expected a range of int4")
    }),
    it("reads a multirange with its range", fn() {
      // Arrange
      let rows = [
        int4_row(),
        type_row_with(3904, "int4range", "r", "R", #(0, 0, 23, 0)),
        type_row_with(4451, "int4multirange", "m", "R", #(0, 0, 0, 3904)),
      ]

      // Act
      let description = found(rows, 4451)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(4451, "int4multirange", Multirange(3904)))
      |> or_fail_with("Expected a multirange of int4range")
    }),
    it("reads a pseudo-type", fn() {
      // Arrange
      let rows = [type_row(2278, "void", "p", "P")]

      // Act
      let description = found(rows, 2278)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(2278, "void", Pseudo))
      |> or_fail_with("Expected void as a pseudo-type")
    }),
  ]
}

// Lookups ---------------------------------------------------------------------

fn domain_chain_rows() -> List(List(Cell)) {
  [
    int4_row(),
    type_row_with(3904, "int4range", "r", "R", #(0, 0, 23, 0)),
    type_row_with(910, "inner_domain", "d", "R", #(0, 3904, 0, 0)),
    type_row_with(911, "outer_domain", "d", "R", #(0, 910, 0, 0)),
  ]
}

fn lookup_tests() {
  [
    it("finds no type in an empty table", fn() {
      // Arrange
      let table: CatalogTable = empty()

      // Act
      let description = find(table, 23)

      // Assert
      description
      |> should
      |> be_equal(None)
      |> or_fail_with("Expected no type")
    }),
    it("finds no type for an OID that the rows do not have", fn() {
      // Act
      let description = found([int4_row()], 25)

      // Assert
      description
      |> should
      |> be_equal(Ok(None))
      |> or_fail_with("Expected no type for 25")
    }),
    it("follows a chain of domains to the range at its end", fn() {
      // Act
      let description = found_underlying(domain_chain_rows(), 911)

      // Assert
      description
      |> should
      |> be_equal(pg_catalog_type(3904, "int4range", Range(23)))
      |> or_fail_with("Expected int4range at the end of the chain")
    }),
    it(
      "gives the type itself as the underlying type of a type that is not a domain",
      fn() {
        // Act
        let description = found_underlying(domain_chain_rows(), 23)

        // Assert
        description
        |> should
        |> be_equal(pg_catalog_type(23, "int4", Base))
        |> or_fail_with("Expected int4 itself")
      },
    ),
    it("finds no underlying type for an OID that the rows do not have", fn() {
      // Act
      let description = found_underlying(domain_chain_rows(), 25)

      // Assert
      description
      |> should
      |> be_equal(Ok(None))
      |> or_fail_with("Expected no type for 25")
    }),
  ]
}

// Errors ----------------------------------------------------------------------

fn error_of(rows: List(List(Cell))) -> Result(Nil, RowError) {
  from_rows(rows) |> result.replace(Nil)
}

fn error_tests() {
  [
    it("refuses a row of another shape", fn() {
      // Arrange
      let row = [text("type"), number(23)]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a binary cell", fn() {
      // Arrange
      let row = [Binary(<<"type">>), number(23)]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a type OID that is not a number", fn() {
      // Arrange
      let row = [
        text("type"),
        text("twenty-three"),
        Null,
        text("pg_catalog"),
        text("int4"),
        text("b"),
        text("N"),
        number(0),
        number(0),
        number(0),
        number(0),
      ]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a name that is not UTF-8", fn() {
      // Arrange
      let row = [
        text("type"),
        number(23),
        Null,
        text("pg_catalog"),
        Text(<<255>>),
        text("b"),
        text("N"),
        number(0),
        number(0),
        number(0),
        number(0),
      ]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a label row with more facts", fn() {
      // Arrange
      let row = [
        text("label"),
        number(902),
        text("1"),
        text("sad"),
        text("more"),
        Null,
        Null,
        Null,
        Null,
        Null,
        Null,
      ]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a field row whose field type is not a number", fn() {
      // Arrange
      let row = [
        text("field"),
        number(900),
        text("1"),
        text("a"),
        text("int4"),
        Null,
        Null,
        Null,
        Null,
        Null,
        Null,
      ]

      // Act
      let outcome = error_of([row])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnreadableRow(row)))
      |> or_fail_with("Expected the row back in the error")
    }),
    it("refuses a type kind that PostgreSQL does not have", fn() {
      // Act
      let outcome = error_of([type_row(920, "strange", "x", "X")])

      // Assert
      outcome
      |> should
      |> be_equal(Error(UnknownTypeKind(920, "x")))
      |> or_fail_with("Expected the kind x back in the error")
    }),
    it("refuses a part that is not a type of the rows", fn() {
      // Act
      let outcome =
        error_of([type_row_with(1007, "_int4", "b", "A", #(23, 0, 0, 0))])

      // Assert
      outcome
      |> should
      |> be_equal(Error(MissingPart(type_id: 1007, part_type_id: 23)))
      |> or_fail_with("Expected the missing element int4")
    }),
    it("refuses a composite field of a type that the rows do not have", fn() {
      // Act
      let outcome =
        error_of([type_row(900, "pair", "c", "C"), field_row(900, "1", "a", 23)])

      // Assert
      outcome
      |> should
      |> be_equal(Error(MissingPart(type_id: 900, part_type_id: 23)))
      |> or_fail_with("Expected the missing field type int4")
    }),
    it("refuses domains whose chain comes back to itself", fn() {
      // Arrange
      let rows = [
        type_row_with(930, "first", "d", "N", #(0, 931, 0, 0)),
        type_row_with(931, "second", "d", "N", #(0, 930, 0, 0)),
      ]

      // Act
      let outcome = error_of(rows)

      // Assert
      outcome
      |> should
      |> be_equal(Error(CircularDomain(930)))
      |> or_fail_with("Expected the first domain of the circle")
    }),
  ]
}
