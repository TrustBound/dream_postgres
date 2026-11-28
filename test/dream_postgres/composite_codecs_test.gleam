//// The composite codec against the exact bytes of PostgreSQL's binary
//// record format.

import dream_postgres/codec/codec_type.{Malformed, NullValue}
import dream_postgres/driver/cell.{Base, Binary, Null, TypeDescription}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/address_codec.{Address, address_codec}
import fixtures/label_codec.{label_codec}
import fixtures/type_catalog
import gleam/option.{None, Some}
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("composite codec", [
    it("takes its composite type", fn() {
      // Arrange
      let subject = address_codec()

      // Act and assert
      subject
      |> should
      |> accept_type(type_catalog.address())
      |> be_true()
      |> or_fail_with("Expected the address codec to take address")
    }),
    it("does not take a composite type of another name", fn() {
      // Arrange
      let place =
        type_catalog.composite(90_201, "place", [
          #("street", 25),
          #("city", 25),
        ])

      // Act and assert
      address_codec()
      |> should
      |> accept_type(place)
      |> be_false()
      |> or_fail_with("Expected the address codec to refuse place")
    }),
    it("does not take a base type of its name", fn() {
      // Arrange
      let base_address =
        TypeDescription(
          id: 90_202,
          schema: "public",
          name: "address",
          kind: Base,
        )

      // Act and assert
      address_codec()
      |> should
      |> accept_type(base_address)
      |> be_false()
      |> or_fail_with("Expected the address codec to refuse a base address")
    }),
    it("does not take a type with another number of fields", fn() {
      // Arrange
      let three_fields =
        type_catalog.composite(90_200, "address", [
          #("street", 25),
          #("city", 25),
          #("zip", 25),
        ])

      // Act and assert
      address_codec()
      |> should
      |> accept_type(three_fields)
      |> be_false()
      |> or_fail_with("Expected the address codec to refuse three fields")
    }),
    it("does not take a type with a field of an unknown type", fn() {
      // Arrange
      let unknown_field =
        type_catalog.composite(90_200, "address", [
          #("street", 25),
          #("city", 999),
        ])

      // Act and assert
      address_codec()
      |> should
      |> accept_type(unknown_field)
      |> be_false()
      |> or_fail_with("Expected the address codec to refuse the field type 999")
    }),
    it("does not take a reader with a codec in the text format", fn() {
      // Arrange
      let subject = label_codec()

      // Act and assert
      subject
      |> should
      |> accept_type(type_catalog.label())
      |> be_false()
      |> or_fail_with(
        "Expected the label codec to refuse its text-format field",
      )
    }),
    it("writes a composite value", fn() {
      // Arrange
      let address = Address("1 Main St", Some("Lyon"))

      // Act and assert
      address
      |> should
      |> encode_as(address_codec(), type_catalog.address())
      |> be_ok()
      |> be_equal(Binary(address_codec.main_street_in_lyon_bytes()))
      |> or_fail_with("Expected the record of 1 Main St in Lyon")
    }),
    it("writes a NULL field", fn() {
      // Arrange
      let address = Address("1 Main St", None)

      // Act and assert
      address
      |> should
      |> encode_as(address_codec(), type_catalog.address())
      |> be_ok()
      |> be_equal(Binary(address_codec.main_street_with_no_city_bytes()))
      |> or_fail_with("Expected the record of 1 Main St with a NULL city")
    }),
    it("refuses fields that do not match the type's fields", fn() {
      // Arrange
      let one_field =
        type_catalog.composite(90_200, "address", [#("street", 25)])

      // Act and assert
      Address("1 Main St", None)
      |> should
      |> encode_as(address_codec(), one_field)
      |> be_error()
      |> be_equal("address: the query has 1 parameters, and 2 were given")
      |> or_fail_with("Expected two fields to be refused for a type of one")
    }),
    it("refuses a field in the text format", fn() {
      // Arrange
      let label = #("home", "top.home")

      // Act and assert
      label
      |> should
      |> encode_as(label_codec(), type_catalog.label())
      |> be_error()
      |> be_equal(
        "label: the field path has a codec in the text format, and a composite field needs one in the binary format",
      )
      |> or_fail_with("Expected the text-format field path to be refused")
    }),
    it("refuses to write a type that is not composite", fn() {
      // Arrange
      let base_address =
        TypeDescription(
          id: 90_202,
          schema: "public",
          name: "address",
          kind: Base,
        )

      // Act and assert
      Address("1 Main St", None)
      |> should
      |> encode_as(address_codec(), base_address)
      |> be_error()
      |> be_equal("address: address is not a composite type")
      |> or_fail_with("Expected a base address to be refused")
    }),
    it("reads a composite value", fn() {
      // Arrange
      let cell = Binary(address_codec.main_street_in_lyon_bytes())

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_ok()
      |> be_equal(Address("1 Main St", Some("Lyon")))
      |> or_fail_with("Expected 1 Main St in Lyon")
    }),
    it("reads a NULL field", fn() {
      // Arrange
      let cell = Binary(address_codec.main_street_with_no_city_bytes())

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_ok()
      |> be_equal(Address("1 Main St", None))
      |> or_fail_with("Expected 1 Main St with no city")
    }),
    it("gives NullValue for a NULL value", fn() {
      // Arrange
      let cell = Null

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(NullValue)
      |> or_fail_with("Expected NullValue for NULL")
    }),
    it("refuses a NULL in a field the codec does not take NULL for", fn() {
      // Arrange
      let cell =
        Binary(<<
          2:size(32),
          25:size(32),
          -1:size(32),
          25:size(32),
          4:size(32),
          "Lyon":utf8,
        >>)

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(Malformed(
        "address: column 1 (street) is NULL, and the query reads it as not NULL",
      ))
      |> or_fail_with("Expected a NULL street to be refused")
    }),
    it("refuses a value with fewer fields than the type", fn() {
      // Arrange
      let cell = Binary(<<1:size(32), 25:size(32), 4:size(32), "Lyon":utf8>>)

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(Malformed(
        "address: the server broke the protocol: a row has 1 values, and the result has 2 columns",
      ))
      |> or_fail_with("Expected one field of two to be refused")
    }),
    it("refuses a value that is cut short", fn() {
      // Arrange
      let cell = Binary(<<1>>)

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(Malformed("address: the composite value is cut short"))
      |> or_fail_with("Expected one byte to be cut short")
    }),
    it("refuses bytes after the last field", fn() {
      // Arrange
      let cell = Binary(<<0:size(32), 1>>)

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(Malformed(
        "address: the composite value has bytes after its last field",
      ))
      |> or_fail_with("Expected a byte after the last field to be refused")
    }),
    it("refuses fields that are cut short", fn() {
      // Arrange
      let cell = Binary(<<1:size(32), 25:size(32), 9:size(32), "1":utf8>>)

      // Act and assert
      cell
      |> should
      |> decode_as(address_codec(), type_catalog.address())
      |> be_error()
      |> be_equal(Malformed(
        "address: the fields of the composite value are cut short",
      ))
      |> or_fail_with("Expected a field of 9 bytes with 1 byte to be cut short")
    }),
    it("refuses a type with a field of an unknown type", fn() {
      // Arrange
      let unknown_field =
        type_catalog.composite(90_200, "address", [
          #("street", 25),
          #("city", 999),
        ])

      // Act and assert
      Binary(address_codec.main_street_in_lyon_bytes())
      |> should
      |> decode_as(address_codec(), unknown_field)
      |> be_error()
      |> be_equal(Malformed(
        "address: the type 999 of the field city is not known",
      ))
      |> or_fail_with("Expected the field type 999 to be refused")
    }),
  ])
}
