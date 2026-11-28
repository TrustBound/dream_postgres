//// Each codec against the exact bytes of PostgreSQL's wire formats. These
//// tests need no server; the tests against PostgreSQL 16 to 19 come with
//// the driver.

import dream_postgres/codecs
import dream_postgres/codecs/array
import dream_postgres/codecs/codec_type.{Malformed, NullValue, OutOfRange}
import dream_postgres/codecs/json
import dream_postgres/driver/cell.{
  Array, Base, Binary, BinaryFormat, Composite, Domain, Enum, Multirange, Null,
  Pseudo, Range, Text, TextFormat, TypeDescription,
}
import dream_test/matchers.{
  be_empty, be_equal, be_error, be_false, be_none, be_ok, be_some, be_true,
  or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import dream_uuid
import fixtures/int4_array_bytes
import fixtures/ltree_codec.{ltree_codec}
import fixtures/mood_codec.{Angry, Happy, Sad, mood_codec}
import fixtures/type_catalog
import gleam/json as gleam_json
import gleam/option.{None, Some}
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("codec", [
    group("accessors", [
      it("names a codec", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act
        let name = codec_type.name(subject)

        // Assert
        name
        |> should
        |> be_equal("array of int")
        |> or_fail_with("Expected the name array of int")
      }),
      it("gives the Gleam type", fn() {
        // Arrange
        let subject = codecs.nullable(codecs.text)

        // Act
        let gleam_type = codec_type.gleam_type(subject)

        // Assert
        gleam_type
        |> should
        |> be_equal("Option(String)")
        |> or_fail_with("Expected the Gleam type Option(String)")
      }),
      it("gives the format of a binary codec", fn() {
        // Arrange
        let subject = codecs.int

        // Act
        let format = codec_type.format(subject)

        // Assert
        format
        |> should
        |> be_equal(BinaryFormat)
        |> or_fail_with("Expected int to use the binary format")
      }),
      it("gives the format of a text codec", fn() {
        // Arrange
        let subject = ltree_codec()

        // Act
        let format = codec_type.format(subject)

        // Assert
        format
        |> should
        |> be_equal(TextFormat)
        |> or_fail_with("Expected a custom codec to use the text format")
      }),
      it("gives the placeholder", fn() {
        // Arrange
        let subject = codecs.bool

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_false()
        |> or_fail_with("Expected the bool placeholder False")
      }),
    ]),
    group("domains", [
      it("takes a domain over a type it takes", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.positive_int())
        |> be_true()
        |> or_fail_with("Expected int to take a domain over int4")
      }),
      it("refuses a domain whose base is unknown", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.lost_domain())
        |> be_false()
        |> or_fail_with("Expected int to refuse a domain over an unknown type")
      }),
      it("writes a domain as its base", fn() {
        // Arrange
        let value = 7

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.positive_int())
        |> be_ok()
        |> be_equal(Binary(<<7:size(32)>>))
        |> or_fail_with("Expected 7 as the four bytes of int4")
      }),
      it("reads a domain as its base", fn() {
        // Arrange
        let cell = Binary(<<7:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.positive_int())
        |> be_ok()
        |> be_equal(7)
        |> or_fail_with("Expected 7 from the four bytes of int4")
      }),
    ]),
    group("int", [
      it("takes int2", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int2())
        |> be_true()
        |> or_fail_with("Expected int to take int2")
      }),
      it("takes oid", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.oid())
        |> be_true()
        |> or_fail_with("Expected int to take oid")
      }),
      it("refuses text", fn() {
        // Arrange
        let subject = codecs.int

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.text())
        |> be_false()
        |> or_fail_with("Expected int to refuse text")
      }),
      it("writes int2", fn() {
        // Arrange
        let value = -2

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int2())
        |> be_ok()
        |> be_equal(Binary(<<-2:size(16)>>))
        |> or_fail_with("Expected -2 as two bytes")
      }),
      it("writes int4", fn() {
        // Arrange
        let value = 7

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int4())
        |> be_ok()
        |> be_equal(Binary(<<7:size(32)>>))
        |> or_fail_with("Expected 7 as four bytes")
      }),
      it("writes int8", fn() {
        // Arrange
        let value = 9_223_372_036_854_775_807

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int8())
        |> be_ok()
        |> be_equal(Binary(<<9_223_372_036_854_775_807:size(64)>>))
        |> or_fail_with("Expected the largest int8 as eight bytes")
      }),
      it("writes oid", fn() {
        // Arrange
        let value = 4_294_967_295

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.oid())
        |> be_ok()
        |> be_equal(Binary(<<4_294_967_295:size(32)>>))
        |> or_fail_with("Expected the largest oid as four bytes")
      }),
      it("refuses a value too large for int2", fn() {
        // Arrange
        let value = 32_768

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int2())
        |> be_error()
        |> be_equal("32768 is out of range for int2")
        |> or_fail_with("Expected 32768 to be out of range for int2")
      }),
      it("refuses a value too small for int4", fn() {
        // Arrange
        let value = -2_147_483_649

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int4())
        |> be_error()
        |> be_equal("-2147483649 is out of range for int4")
        |> or_fail_with("Expected -2147483649 to be out of range for int4")
      }),
      it("refuses a negative oid", fn() {
        // Arrange
        let value = -1

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.oid())
        |> be_error()
        |> be_equal("-1 is out of range for oid")
        |> or_fail_with("Expected -1 to be out of range for oid")
      }),
      it("refuses a value too large for int8", fn() {
        // Arrange
        let value = 9_223_372_036_854_775_808

        // Act and assert
        value
        |> should
        |> encode_as(codecs.int, type_catalog.int8())
        |> be_error()
        |> be_equal("9223372036854775808 is out of range for int8")
        |> or_fail_with("Expected 2 to the 63 to be out of range for int8")
      }),
      it("reads int2", fn() {
        // Arrange
        let cell = Binary(<<-2:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.int2())
        |> be_ok()
        |> be_equal(-2)
        |> or_fail_with("Expected -2 from two bytes")
      }),
      it("reads int4", fn() {
        // Arrange
        let cell = Binary(<<-7:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.int4())
        |> be_ok()
        |> be_equal(-7)
        |> or_fail_with("Expected -7 from four bytes")
      }),
      it("reads int8", fn() {
        // Arrange
        let cell = Binary(<<-9:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.int8())
        |> be_ok()
        |> be_equal(-9)
        |> or_fail_with("Expected -9 from eight bytes")
      }),
      it("reads oid as unsigned", fn() {
        // Arrange
        let cell = Binary(<<4_294_967_295:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.oid())
        |> be_ok()
        |> be_equal(4_294_967_295)
        |> or_fail_with("Expected the largest oid, not -1")
      }),
      it("refuses three bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2, 3>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.int4())
        |> be_error()
        |> be_equal(Malformed("3 bytes are not a int4 value"))
        |> or_fail_with("Expected three bytes to be no int4 value")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.int, type_catalog.int4())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected int to give NullValue for NULL")
      }),
    ]),
    group("float", [
      it("takes float4", fn() {
        // Arrange
        let subject = codecs.float

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.float4())
        |> be_true()
        |> or_fail_with("Expected float to take float4")
      }),
      it("writes float4", fn() {
        // Arrange
        let value = 1.5

        // Act and assert
        value
        |> should
        |> encode_as(codecs.float, type_catalog.float4())
        |> be_ok()
        |> be_equal(Binary(<<1.5:float-size(32)>>))
        |> or_fail_with("Expected 1.5 as four bytes")
      }),
      it("writes float8", fn() {
        // Arrange
        let value = 1.5

        // Act and assert
        value
        |> should
        |> encode_as(codecs.float, type_catalog.float8())
        |> be_ok()
        |> be_equal(Binary(<<1.5:float-size(64)>>))
        |> or_fail_with("Expected 1.5 as eight bytes")
      }),
      it("refuses a value too large for float4", fn() {
        // Arrange
        let value = 1.0e39

        // Act and assert
        value
        |> should
        |> encode_as(codecs.float, type_catalog.float4())
        |> be_error()
        |> be_equal("1.0e39 is out of range for float4")
        |> or_fail_with("Expected 1.0e39 to be out of range for float4")
      }),
      it("refuses a value too small for float4", fn() {
        // Arrange
        let value = -1.0e39

        // Act and assert
        value
        |> should
        |> encode_as(codecs.float, type_catalog.float4())
        |> be_error()
        |> be_equal("-1.0e39 is out of range for float4")
        |> or_fail_with("Expected -1.0e39 to be out of range for float4")
      }),
      it("reads float4", fn() {
        // Arrange
        let cell = Binary(<<1.5:float-size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float4())
        |> be_ok()
        |> be_equal(1.5)
        |> or_fail_with("Expected 1.5 from four bytes")
      }),
      it("reads float8", fn() {
        // Arrange
        let cell = Binary(<<1.5:float-size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float8())
        |> be_ok()
        |> be_equal(1.5)
        |> or_fail_with("Expected 1.5 from eight bytes")
      }),
      it("gives OutOfRange for float4 NaN", fn() {
        // Arrange
        let cell = Binary(<<0x7FC00000:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float4())
        |> be_error()
        |> be_equal(OutOfRange("NaN"))
        |> or_fail_with("Expected OutOfRange for the float4 NaN")
      }),
      it("gives OutOfRange for float8 Infinity", fn() {
        // Arrange
        let cell = Binary(<<0x7FF0000000000000:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float8())
        |> be_error()
        |> be_equal(OutOfRange("Infinity"))
        |> or_fail_with("Expected OutOfRange for the float8 Infinity")
      }),
      it("gives OutOfRange for float8 -Infinity", fn() {
        // Arrange
        let cell = Binary(<<0xFFF0000000000000:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float8())
        |> be_error()
        |> be_equal(OutOfRange("-Infinity"))
        |> or_fail_with("Expected OutOfRange for the float8 -Infinity")
      }),
      it("refuses two bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.float, type_catalog.float8())
        |> be_error()
        |> be_equal(Malformed("2 bytes are not a float8 value"))
        |> or_fail_with("Expected two bytes to be no float8 value")
      }),
    ]),
    group("bool", [
      it("writes True", fn() {
        // Arrange
        let value = True

        // Act and assert
        value
        |> should
        |> encode_as(codecs.bool, type_catalog.base_with_id(16, "bool"))
        |> be_ok()
        |> be_equal(Binary(<<1>>))
        |> or_fail_with("Expected True as the byte 1")
      }),
      it("writes False", fn() {
        // Arrange
        let value = False

        // Act and assert
        value
        |> should
        |> encode_as(codecs.bool, type_catalog.base_with_id(16, "bool"))
        |> be_ok()
        |> be_equal(Binary(<<0>>))
        |> or_fail_with("Expected False as the byte 0")
      }),
      it("reads True", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.bool, type_catalog.base_with_id(16, "bool"))
        |> be_ok()
        |> be_true()
        |> or_fail_with("Expected True from the byte 1")
      }),
      it("reads False", fn() {
        // Arrange
        let cell = Binary(<<0>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.bool, type_catalog.base_with_id(16, "bool"))
        |> be_ok()
        |> be_false()
        |> or_fail_with("Expected False from the byte 0")
      }),
      it("refuses the byte 2", fn() {
        // Arrange
        let cell = Binary(<<2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.bool, type_catalog.base_with_id(16, "bool"))
        |> be_error()
        |> be_equal(Malformed("1 bytes are not a bool value"))
        |> or_fail_with("Expected the byte 2 to be no bool value")
      }),
      it("takes bool", fn() {
        // Arrange
        let subject = codecs.bool

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(16, "bool"))
        |> be_true()
        |> or_fail_with("Expected bool to take bool")
      }),
    ]),
    group("text", [
      it("takes citext", fn() {
        // Arrange
        let subject = codecs.text

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(90_010, "citext"))
        |> be_true()
        |> or_fail_with("Expected text to take citext")
      }),
      it("writes UTF-8", fn() {
        // Arrange
        let value = "héllo"

        // Act and assert
        value
        |> should
        |> encode_as(codecs.text, type_catalog.text())
        |> be_ok()
        |> be_equal(Binary(<<"héllo":utf8>>))
        |> or_fail_with("Expected the UTF-8 bytes of héllo")
      }),
      it("reads UTF-8", fn() {
        // Arrange
        let cell = Binary(<<"héllo":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.text, type_catalog.text())
        |> be_ok()
        |> be_equal("héllo")
        |> or_fail_with("Expected héllo from its UTF-8 bytes")
      }),
      it("reads a text cell", fn() {
        // Arrange
        let cell = Text(<<"hi":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.text, type_catalog.text())
        |> be_ok()
        |> be_equal("hi")
        |> or_fail_with("Expected hi from a text cell")
      }),
      it("refuses bytes that are not UTF-8", fn() {
        // Arrange
        let cell = Binary(<<255>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.text, type_catalog.text())
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the byte 255 to be no UTF-8 text")
      }),
    ]),
    group("bytea", [
      it("takes bytea", fn() {
        // Arrange
        let subject = codecs.bytea

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(17, "bytea"))
        |> be_true()
        |> or_fail_with("Expected bytea to take bytea")
      }),
      it("writes bytes", fn() {
        // Arrange
        let value = <<1, 2>>

        // Act and assert
        value
        |> should
        |> encode_as(codecs.bytea, type_catalog.base_with_id(17, "bytea"))
        |> be_ok()
        |> be_equal(Binary(<<1, 2>>))
        |> or_fail_with("Expected the bytes as they are")
      }),
      it("reads bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.bytea, type_catalog.base_with_id(17, "bytea"))
        |> be_ok()
        |> be_equal(<<1, 2>>)
        |> or_fail_with("Expected the bytes as they are")
      }),
    ]),
    group("uuid", [
      it("takes uuid", fn() {
        // Arrange
        let subject = codecs.uuid

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(2950, "uuid"))
        |> be_true()
        |> or_fail_with("Expected uuid to take uuid")
      }),
      it("writes 16 bytes", fn() {
        // Arrange
        let value = dream_uuid.max

        // Act and assert
        value
        |> should
        |> encode_as(codecs.uuid, type_catalog.base_with_id(2950, "uuid"))
        |> be_ok()
        |> be_equal(Binary(dream_uuid.to_bit_array(dream_uuid.max)))
        |> or_fail_with("Expected the 16 bytes of the max UUID")
      }),
      it("reads 16 bytes", fn() {
        // Arrange
        let cell = Binary(dream_uuid.to_bit_array(dream_uuid.max))

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.uuid, type_catalog.base_with_id(2950, "uuid"))
        |> be_ok()
        |> be_equal(dream_uuid.max)
        |> or_fail_with("Expected the max UUID from its 16 bytes")
      }),
      it("refuses 15 bytes", fn() {
        // Arrange
        let cell = Binary(<<0:size(120)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.uuid, type_catalog.base_with_id(2950, "uuid"))
        |> be_error()
        |> be_equal(Malformed("15 bytes are not a uuid value"))
        |> or_fail_with("Expected 15 bytes to be no uuid value")
      }),
      it("has the nil placeholder", fn() {
        // Arrange
        let subject = codecs.uuid

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_equal(dream_uuid.nil)
        |> or_fail_with("Expected the nil UUID as the placeholder")
      }),
    ]),
    group("json and jsonb", [
      it("takes json", fn() {
        // Arrange
        let subject = json.json

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(114, "json"))
        |> be_true()
        |> or_fail_with("Expected json to take json")
      }),
      it("takes jsonb", fn() {
        // Arrange
        let subject = json.jsonb

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base_with_id(3802, "jsonb"))
        |> be_true()
        |> or_fail_with("Expected jsonb to take jsonb")
      }),
      it("writes json as its text", fn() {
        // Arrange
        let document =
          json.from_json(gleam_json.object([#("a", gleam_json.int(1))]))

        // Act and assert
        document
        |> should
        |> encode_as(json.json, type_catalog.base_with_id(114, "json"))
        |> be_ok()
        |> be_equal(Binary(<<"{\"a\":1}":utf8>>))
        |> or_fail_with("Expected the text {\"a\":1}")
      }),
      it("reads json", fn() {
        // Arrange
        let cell = Binary(<<"{\"a\":1}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(json.json, type_catalog.base_with_id(114, "json"))
        |> be_ok()
        |> be_equal(
          json.from_json(gleam_json.object([#("a", gleam_json.int(1))])),
        )
        |> or_fail_with("Expected the document {\"a\":1}")
      }),
      it("refuses text that is not JSON", fn() {
        // Arrange
        let cell = Binary(<<"{":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(json.json, type_catalog.base_with_id(114, "json"))
        |> be_error()
        |> be_equal(Malformed("the server sent text that is not JSON"))
        |> or_fail_with("Expected the text { to be no JSON")
      }),
      it("writes jsonb with its version byte", fn() {
        // Arrange
        let document =
          json.from_json(gleam_json.object([#("a", gleam_json.int(1))]))

        // Act and assert
        document
        |> should
        |> encode_as(json.jsonb, type_catalog.base_with_id(3802, "jsonb"))
        |> be_ok()
        |> be_equal(Binary(<<1, "{\"a\":1}":utf8>>))
        |> or_fail_with("Expected the version byte 1 and the text {\"a\":1}")
      }),
      it("reads jsonb", fn() {
        // Arrange
        let cell = Binary(<<1, "{\"a\":1}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(json.jsonb, type_catalog.base_with_id(3802, "jsonb"))
        |> be_ok()
        |> be_equal(
          json.from_json(gleam_json.object([#("a", gleam_json.int(1))])),
        )
        |> or_fail_with(
          "Expected the document {\"a\":1} after the version byte",
        )
      }),
      it("refuses jsonb of another version", fn() {
        // Arrange
        let cell = Binary(<<2, "{}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(json.jsonb, type_catalog.base_with_id(3802, "jsonb"))
        |> be_error()
        |> be_equal(Malformed("3 bytes are not a jsonb value"))
        |> or_fail_with("Expected the version byte 2 to be refused")
      }),
      it("refuses jsonb text that is not UTF-8", fn() {
        // Arrange
        let cell = Binary(<<1, 255>>)

        // Act and assert
        cell
        |> should
        |> decode_as(json.jsonb, type_catalog.base_with_id(3802, "jsonb"))
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the byte 255 to be no UTF-8 text")
      }),
      it("has the null placeholder", fn() {
        // Arrange
        let subject = json.json

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_equal(json.null)
        |> or_fail_with("Expected the JSON null as the placeholder")
      }),
    ]),
    group("nullable", [
      it("writes Some", fn() {
        // Arrange
        let value = Some(7)

        // Act and assert
        value
        |> should
        |> encode_as(codecs.nullable(codecs.int), type_catalog.int4())
        |> be_ok()
        |> be_equal(Binary(<<7:size(32)>>))
        |> or_fail_with("Expected Some(7) as the four bytes of 7")
      }),
      it("writes None as NULL", fn() {
        // Arrange
        let value = None

        // Act and assert
        value
        |> should
        |> encode_as(codecs.nullable(codecs.int), type_catalog.int4())
        |> be_ok()
        |> be_equal(Null)
        |> or_fail_with("Expected None as NULL")
      }),
      it("reads NULL as None", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.nullable(codecs.int), type_catalog.int4())
        |> be_ok()
        |> be_none()
        |> or_fail_with("Expected None from NULL")
      }),
      it("reads a value as Some", fn() {
        // Arrange
        let cell = Binary(<<7:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codecs.nullable(codecs.int), type_catalog.int4())
        |> be_ok()
        |> be_some()
        |> be_equal(7)
        |> or_fail_with("Expected Some(7) from the four bytes of 7")
      }),
      it("takes what its inner codec takes", fn() {
        // Arrange
        let subject = codecs.nullable(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4())
        |> be_true()
        |> or_fail_with("Expected nullable int to take int4")
      }),
      it("has the placeholder None", fn() {
        // Arrange
        let subject = codecs.nullable(codecs.int)

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_none()
        |> or_fail_with("Expected the placeholder None")
      }),
    ]),
    group("binary arrays", [
      it("writes an int2vector counting from 0", fn() {
        // Arrange
        let value = [1, 2]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int2_vector())
        |> be_ok()
        |> be_equal(
          Binary(<<
            1:size(32),
            0:size(32),
            21:size(32),
            2:size(32),
            0:size(32),
            2:size(32),
            1:size(16),
            2:size(32),
            2:size(16),
          >>),
        )
        |> or_fail_with("Expected an int2vector of 1 and 2 with lower bound 0")
      }),
      it("refuses an empty int2vector", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int2_vector())
        |> be_error()
        |> be_equal("int2vector cannot be empty in the binary format")
        |> or_fail_with("Expected an empty int2vector to be refused")
      }),
      it("refuses a NULL in an int2vector", fn() {
        // Arrange
        let value = [Some(1), None]

        // Act and assert
        value
        |> should
        |> encode_as(
          array.array(codecs.nullable(codecs.int)),
          type_catalog.int2_vector(),
        )
        |> be_error()
        |> be_equal("int2vector cannot hold a NULL element")
        |> or_fail_with("Expected a NULL in an int2vector to be refused")
      }),
      it("takes int4[]", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_array())
        |> be_true()
        |> or_fail_with("Expected an array of int to take int4[]")
      }),
      it("refuses an array of an unknown type", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.lost_array())
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse an unknown element")
      }),
      it("refuses a type that is not an array", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4())
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse int4")
      }),
      it("writes two elements", fn() {
        // Arrange
        let value = [1, 2]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_ok()
        |> be_equal(Binary(int4_array_bytes.one_and_two()))
        |> or_fail_with("Expected the int4[] {1,2}")
      }),
      it("writes an empty array", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_ok()
        |> be_equal(Binary(int4_array_bytes.empty()))
        |> or_fail_with("Expected the empty int4[] with no dimensions")
      }),
      it("writes a NULL element", fn() {
        // Arrange
        let value = [Some(1), None]

        // Act and assert
        value
        |> should
        |> encode_as(
          array.array(codecs.nullable(codecs.int)),
          type_catalog.int4_array(),
        )
        |> be_ok()
        |> be_equal(Binary(int4_array_bytes.one_and_null()))
        |> or_fail_with("Expected the int4[] {1,NULL}")
      }),
      it("refuses an element out of range", fn() {
        // Arrange
        let value = [1, 9_999_999_999]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal("9999999999 is out of range for int4")
        |> or_fail_with("Expected the element 9999999999 to be refused")
      }),
      it("refuses a parameter type that is not an array", fn() {
        // Arrange
        let value = [1]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.int4())
        |> be_error()
        |> be_equal("int4 is not an array type")
        |> or_fail_with("Expected int4 to be refused as an array type")
      }),
      it("refuses an unknown element type", fn() {
        // Arrange
        let value = [1]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(codecs.int), type_catalog.lost_array())
        |> be_error()
        |> be_equal("the element type 99999 is unknown")
        |> or_fail_with("Expected the element type 99999 to be unknown")
      }),
      it("reads two elements", fn() {
        // Arrange
        let cell = Binary(int4_array_bytes.one_and_two())

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_ok()
        |> be_equal([1, 2])
        |> or_fail_with("Expected [1, 2] from the int4[] {1,2}")
      }),
      it("reads an empty array", fn() {
        // Arrange
        let cell = Binary(int4_array_bytes.empty())

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_ok()
        |> be_empty()
        |> or_fail_with("Expected [] from the empty int4[]")
      }),
      it("reads a NULL element", fn() {
        // Arrange
        let cell = Binary(int4_array_bytes.one_and_null())

        // Act and assert
        cell
        |> should
        |> decode_as(
          array.array(codecs.nullable(codecs.int)),
          type_catalog.int4_array(),
        )
        |> be_ok()
        |> be_equal([Some(1), None])
        |> or_fail_with("Expected [Some(1), None] from the int4[] {1,NULL}")
      }),
      it("refuses a NULL element for a codec that takes no NULL", fn() {
        // Arrange
        let cell = Binary(int4_array_bytes.one_and_null())

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NullValue for the NULL element")
      }),
      it("refuses a NULL array", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NullValue for a NULL array")
      }),
      it("refuses two dimensions", fn() {
        // Arrange
        let cell = Binary(<<2:size(32), 0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(Malformed(
          "the array has 2 dimensions, and a List holds one",
        ))
        |> or_fail_with("Expected an array of two dimensions to be refused")
      }),
      it("refuses a header that is cut short", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(Malformed("the array's header is cut short"))
        |> or_fail_with("Expected a header of one byte to be cut short")
      }),
      it("refuses bytes after the last element", fn() {
        // Arrange
        let cell = Binary(<<int4_array_bytes.one_and_two():bits, 9>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(Malformed("the array has bytes after its last element"))
        |> or_fail_with("Expected a byte after the last element to be refused")
      }),
      it("refuses elements that are cut short", fn() {
        // Arrange
        let cell =
          Binary(<<
            1:size(32), 0:size(32), 23:size(32), 2:size(32), 1:size(32),
            4:size(32), 1:size(32),
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.int4_array())
        |> be_error()
        |> be_equal(Malformed("the array's elements are cut short"))
        |> or_fail_with("Expected one element of two to be cut short")
      }),
      it("refuses an unknown element type when reading", fn() {
        // Arrange
        let cell = Binary(int4_array_bytes.one_and_two())

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(codecs.int), type_catalog.lost_array())
        |> be_error()
        |> be_equal(Malformed("the element type 99999 is unknown"))
        |> or_fail_with("Expected the element type 99999 to be unknown")
      }),
      it("has the placeholder []", fn() {
        // Arrange
        let subject = array.array(codecs.int)

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_empty()
        |> or_fail_with("Expected the placeholder []")
      }),
    ]),
    group("text arrays", [
      it("takes ltree[]", fn() {
        // Arrange
        let subject = array.array(ltree_codec())

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.ltree_array())
        |> be_true()
        |> or_fail_with("Expected an array of ltree to take ltree[]")
      }),
      it("writes quoted elements with escapes", fn() {
        // Arrange
        let value = ["a.b", "q\"x\\y"]

        // Act and assert
        value
        |> should
        |> encode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_ok()
        |> be_equal(Text(<<"{\"a.b\",\"q\\\"x\\\\y\"}":utf8>>))
        |> or_fail_with("Expected each element quoted, with \" and \\ escaped")
      }),
      it("writes NULL", fn() {
        // Arrange
        let value = [Some("a"), None]

        // Act and assert
        value
        |> should
        |> encode_as(
          array.array(codecs.nullable(ltree_codec())),
          type_catalog.ltree_array(),
        )
        |> be_ok()
        |> be_equal(Text(<<"{\"a\",NULL}":utf8>>))
        |> or_fail_with("Expected the text {\"a\",NULL}")
      }),
      it("writes an empty array", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_ok()
        |> be_equal(Text(<<"{}":utf8>>))
        |> or_fail_with("Expected the text {}")
      }),
      it("reads an empty array", fn() {
        // Arrange
        let cell = Text(<<"{}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_ok()
        |> be_empty()
        |> or_fail_with("Expected [] from the text {}")
      }),
      it("reads unquoted and quoted elements", fn() {
        // Arrange
        let cell = Text(<<"{a.b,\"c \\\"d\\\"\",e\\,f}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_ok()
        |> be_equal(["a.b", "c \"d\"", "e,f"])
        |> or_fail_with("Expected a.b, c \"d\" and e,f with the escapes read")
      }),
      it("reads NULL as None", fn() {
        // Arrange
        let cell = Text(<<"{a,NULL}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          array.array(codecs.nullable(ltree_codec())),
          type_catalog.ltree_array(),
        )
        |> be_ok()
        |> be_equal([Some("a"), None])
        |> or_fail_with("Expected [Some(\"a\"), None] from the text {a,NULL}")
      }),
      it("passes an element's own error on", fn() {
        // Arrange
        let cell = Text(<<"{bad}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed("not an ltree"))
        |> or_fail_with("Expected the ltree parser's error for bad")
      }),
      it("refuses two dimensions", fn() {
        // Arrange
        let cell = Text(<<"{{a},{b}}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed(
          "the array has more than one dimension, and a List holds one",
        ))
        |> or_fail_with("Expected the text {{a},{b}} to be refused")
      }),
      it("refuses a missing closing brace", fn() {
        // Arrange
        let cell = Text(<<"{a":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed("the array text has no closing brace"))
        |> or_fail_with("Expected the text {a to be refused")
      }),
      it("refuses text with no opening brace", fn() {
        // Arrange
        let cell = Text(<<"a}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed("the array text does not start with a brace"))
        |> or_fail_with("Expected the text a} to be refused")
      }),
      it("refuses a character after a quoted element", fn() {
        // Arrange
        let cell = Text(<<"{\"a\"b}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed(
          "the array text has a character after a quoted element",
        ))
        |> or_fail_with("Expected the text {\"a\"b} to be refused")
      }),
      it("refuses a quote that does not close", fn() {
        // Arrange
        let cell = Text(<<"{\"a}":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed("the array text has a quote that does not close"))
        |> or_fail_with("Expected the text {\"a} to be refused")
      }),
      it("refuses text that is not UTF-8", fn() {
        // Arrange
        let cell = Text(<<255>>)

        // Act and assert
        cell
        |> should
        |> decode_as(array.array(ltree_codec()), type_catalog.ltree_array())
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the byte 255 to be no UTF-8 text")
      }),
    ]),
    group("enum", [
      it("takes the enum with the same labels", fn() {
        // Arrange
        let subject = mood_codec()

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.mood())
        |> be_true()
        |> or_fail_with("Expected the mood codec to take mood")
      }),
      it("refuses the enum with another label", fn() {
        // Arrange
        let other_labels =
          TypeDescription(
            ..type_catalog.mood(),
            kind: Enum(["happy", "sad", "ok"]),
          )

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(other_labels)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse the label ok")
      }),
      it("refuses an enum of another name", fn() {
        // Arrange
        let feeling = TypeDescription(..type_catalog.mood(), name: "feeling")

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(feeling)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse feeling")
      }),
      it("refuses a base type", fn() {
        // Arrange
        let subject = mood_codec()

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.text())
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse text")
      }),
      it("writes a label", fn() {
        // Arrange
        let value = Sad

        // Act and assert
        value
        |> should
        |> encode_as(mood_codec(), type_catalog.mood())
        |> be_ok()
        |> be_equal(Binary(<<"sad":utf8>>))
        |> or_fail_with("Expected Sad as the label sad")
      }),
      it("refuses a value with no label", fn() {
        // Arrange
        let value = Angry

        // Act and assert
        value
        |> should
        |> encode_as(mood_codec(), type_catalog.mood())
        |> be_error()
        |> be_equal("the value is not one of the labels of mood")
        |> or_fail_with("Expected Angry to have no label")
      }),
      it("reads a label", fn() {
        // Arrange
        let cell = Binary(<<"happy":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(mood_codec(), type_catalog.mood())
        |> be_ok()
        |> be_equal(Happy)
        |> or_fail_with("Expected Happy from the label happy")
      }),
      it("refuses a label the codec does not have", fn() {
        // Arrange
        let cell = Binary(<<"ok":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(mood_codec(), type_catalog.mood())
        |> be_error()
        |> be_equal(Malformed("the label ok is not a label of the codec"))
        |> or_fail_with("Expected the label ok to be refused")
      }),
      it("has the first value as its placeholder", fn() {
        // Arrange
        let subject = mood_codec()

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_equal(Happy)
        |> or_fail_with("Expected the placeholder Happy")
      }),
      it("is named for its type", fn() {
        // Arrange
        let subject = mood_codec()

        // Act
        let name = codec_type.name(subject)

        // Assert
        name
        |> should
        |> be_equal("enum mood")
        |> or_fail_with("Expected the name enum mood")
      }),
    ]),
    group("custom", [
      it("takes its type", fn() {
        // Arrange
        let subject = ltree_codec()

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.ltree())
        |> be_true()
        |> or_fail_with("Expected the ltree codec to take ltree")
      }),
      it("refuses another type", fn() {
        // Arrange
        let subject = ltree_codec()

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.text())
        |> be_false()
        |> or_fail_with("Expected the ltree codec to refuse text")
      }),
      it("writes text", fn() {
        // Arrange
        let value = "a.b"

        // Act and assert
        value
        |> should
        |> encode_as(ltree_codec(), type_catalog.ltree())
        |> be_ok()
        |> be_equal(Text(<<"a.b":utf8>>))
        |> or_fail_with("Expected the text a.b")
      }),
      it("reads text", fn() {
        // Arrange
        let cell = Text(<<"a.b":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(ltree_codec(), type_catalog.ltree())
        |> be_ok()
        |> be_equal("a.b")
        |> or_fail_with("Expected a.b from its text")
      }),
      it("gives its parser's error", fn() {
        // Arrange
        let cell = Text(<<"bad":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(ltree_codec(), type_catalog.ltree())
        |> be_error()
        |> be_equal(Malformed("not an ltree"))
        |> or_fail_with("Expected the ltree parser's error for bad")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(ltree_codec(), type_catalog.ltree())
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected the ltree codec to give NullValue for NULL")
      }),
    ]),
    group("accepts each kind", [
      it("int refuses an enum", fn() {
        // Arrange
        let description = TypeDescription(1, "pg_catalog", "int4", Enum(["a"]))

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse an enum named int4")
      }),
      it("int refuses a composite", fn() {
        // Arrange
        let description =
          TypeDescription(1, "pg_catalog", "int4", Composite([#("x", 23)]))

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse a composite named int4")
      }),
      it("int refuses a range", fn() {
        // Arrange
        let description = TypeDescription(1, "pg_catalog", "int4", Range(23))

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse a range named int4")
      }),
      it("int refuses a multirange", fn() {
        // Arrange
        let description =
          TypeDescription(1, "pg_catalog", "int4", Multirange(3904))

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse a multirange named int4")
      }),
      it("int refuses an array", fn() {
        // Arrange
        let description = TypeDescription(1, "pg_catalog", "int4", Array(23))

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse an array named int4")
      }),
      it("int refuses a pseudo-type", fn() {
        // Arrange
        let description = TypeDescription(1, "pg_catalog", "int4", Pseudo)

        // Act and assert
        codecs.int
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected int to refuse a pseudo-type named int4")
      }),
      it("an array refuses a base type", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Base)

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a base type")
      }),
      it("an array refuses an enum", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Enum(["a"]))

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse an enum")
      }),
      it("an array refuses a composite", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Composite([]))

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a composite")
      }),
      it("an array refuses a domain", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Domain(99_999))

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a lost domain")
      }),
      it("an array refuses a range", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Range(23))

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a range")
      }),
      it("an array refuses a multirange", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Multirange(3904))

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a multirange")
      }),
      it("an array refuses a pseudo-type", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "x", Pseudo)

        // Act and assert
        array.array(codecs.int)
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected an array of int to refuse a pseudo-type")
      }),
      it("an enum refuses a composite", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "mood", Composite([]))

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse a composite")
      }),
      it("an enum refuses a range", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "mood", Range(23))

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse a range")
      }),
      it("an enum refuses a multirange", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "mood", Multirange(3904))

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse a multirange")
      }),
      it("an enum refuses an array", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "mood", Array(23))

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse an array")
      }),
      it("an enum refuses a pseudo-type", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "mood", Pseudo)

        // Act and assert
        mood_codec()
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected the mood codec to refuse a pseudo-type")
      }),
      it("a domain resolve leaves an enum as it is", fn() {
        // Arrange
        let subject = codecs.text

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.mood())
        |> be_false()
        |> or_fail_with("Expected text to refuse the enum mood")
      }),
      it("a domain resolve leaves a composite as it is", fn() {
        // Arrange
        let description = TypeDescription(1, "public", "pair", Composite([]))

        // Act and assert
        codecs.text
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected text to refuse the composite pair")
      }),
      it("a domain resolve leaves a range as it is", fn() {
        // Arrange
        let description =
          TypeDescription(1, "pg_catalog", "int4range", Range(23))

        // Act and assert
        codecs.text
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected text to refuse the range int4range")
      }),
      it("a domain resolve leaves a multirange as it is", fn() {
        // Arrange
        let description =
          TypeDescription(1, "pg_catalog", "int4multirange", Multirange(3904))

        // Act and assert
        codecs.text
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected text to refuse the multirange int4multirange")
      }),
      it("a domain resolve leaves an array as it is", fn() {
        // Arrange
        let subject = codecs.text

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.int4_array())
        |> be_false()
        |> or_fail_with("Expected text to refuse the array int4[]")
      }),
      it("a domain resolve leaves a pseudo-type as it is", fn() {
        // Arrange
        let description = TypeDescription(1, "pg_catalog", "void", Pseudo)

        // Act and assert
        codecs.text
        |> should
        |> accept_type(description)
        |> be_false()
        |> or_fail_with("Expected text to refuse the pseudo-type void")
      }),
    ]),
  ])
}
