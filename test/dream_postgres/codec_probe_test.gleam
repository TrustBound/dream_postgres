//// Each codec against PostgreSQL 16 to 19. A probe writes a Gleam value
//// as `$1` and compares the server's text of it with the expected text,
//// then reads that text back and compares the value.

import dream_postgres/codec
import dream_postgres/codec/codec_type.{OutOfRange}
import dream_postgres/geometry.{
  Box, Circle, Line, LineSegment, Path, Point, Polygon,
}
import dream_postgres/json
import dream_postgres/network.{IpNetwork, Ipv4, Ipv6}
import dream_postgres/range.{EmptyRange, Exclusive, Inclusive, Unbounded}
import dream_postgres/text_search.{
  And, Lexeme, Not, Or, Phrase, Term, WeightA, WeightB, WeightD,
}
import dream_postgres/tid.{Tid}
import dream_postgres/time.{
  Finite, Interval, NegativeInfinity, PositiveInfinity, TimeWithOffset,
}
import dream_postgres/vector
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{before_all, describe, group, it}
import dream_uuid
import fixtures/probe_sessions.{ReadDecodeFailed}
import fixtures/probe_types.{Address, Happy, LineItem, Okay, Order, Sad}
import fixtures/server_versions
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{Date, February, January, March, TimeOfDay}
import gleam/time/duration
import gleam/time/timestamp
import matchers/have_each_vector_floats.{have_each_vector_floats}
import matchers/have_half_vector_floats.{have_half_vector_floats}
import matchers/have_json_text.{have_json_text}
import matchers/have_mac_address_text.{have_mac_address_text}
import matchers/have_sparse_vector_parts.{have_sparse_vector_parts}
import matchers/have_uuid_text.{have_uuid_text}
import matchers/have_vector_floats.{have_vector_floats}
import matchers/read_expression_on_server.{read_expression_on_server}
import matchers/read_on_server.{read_on_server}
import matchers/write_on_server.{write_on_server}

/// The probes of each codec on each driver server.
pub fn tests() -> TestSuite {
  describe(
    "codec probes on PostgreSQL 16 to 19",
    context.setup(probe_sessions.start, teardown: probe_sessions.stop),
    list.append(
      list.map(server_versions.all(), fn(version) {
        group(server_versions.group_name(version), [
          before_all(probe_sessions.choose_version(version)),
          // The integers, booleans and numerics.
          it("writes int2 -32768", fn(sessions) {
            // Act and assert
            -32_768
            |> should
            |> write_on_server(sessions, codec.int, "int2")
            |> be_ok()
            |> be_some()
            |> be_equal("-32768")
            |> or_fail_with("Expected the server text -32768 of int2")
          }),
          it("reads int2 -32768", fn(sessions) {
            // Act and assert
            Some("-32768")
            |> should
            |> read_on_server(sessions, codec.int, "int2")
            |> be_ok()
            |> be_equal(-32_768)
            |> or_fail_with(
              "Expected the int2 -32768 to read as its Gleam value",
            )
          }),
          it("writes int2 32767", fn(sessions) {
            // Act and assert
            32_767
            |> should
            |> write_on_server(sessions, codec.int, "int2")
            |> be_ok()
            |> be_some()
            |> be_equal("32767")
            |> or_fail_with("Expected the server text 32767 of int2")
          }),
          it("reads int2 32767", fn(sessions) {
            // Act and assert
            Some("32767")
            |> should
            |> read_on_server(sessions, codec.int, "int2")
            |> be_ok()
            |> be_equal(32_767)
            |> or_fail_with(
              "Expected the int2 32767 to read as its Gleam value",
            )
          }),
          it("writes int4 0", fn(sessions) {
            // Act and assert
            0
            |> should
            |> write_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_some()
            |> be_equal("0")
            |> or_fail_with("Expected the server text 0 of int4")
          }),
          it("reads int4 0", fn(sessions) {
            // Act and assert
            Some("0")
            |> should
            |> read_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_equal(0)
            |> or_fail_with("Expected the int4 0 to read as its Gleam value")
          }),
          it("writes int4 -2147483648", fn(sessions) {
            // Act and assert
            -2_147_483_648
            |> should
            |> write_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_some()
            |> be_equal("-2147483648")
            |> or_fail_with("Expected the server text -2147483648 of int4")
          }),
          it("reads int4 -2147483648", fn(sessions) {
            // Act and assert
            Some("-2147483648")
            |> should
            |> read_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_equal(-2_147_483_648)
            |> or_fail_with(
              "Expected the int4 -2147483648 to read as its Gleam value",
            )
          }),
          it("writes int4 2147483647", fn(sessions) {
            // Act and assert
            2_147_483_647
            |> should
            |> write_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_some()
            |> be_equal("2147483647")
            |> or_fail_with("Expected the server text 2147483647 of int4")
          }),
          it("reads int4 2147483647", fn(sessions) {
            // Act and assert
            Some("2147483647")
            |> should
            |> read_on_server(sessions, codec.int, "int4")
            |> be_ok()
            |> be_equal(2_147_483_647)
            |> or_fail_with(
              "Expected the int4 2147483647 to read as its Gleam value",
            )
          }),
          it("writes int8 -9223372036854775808", fn(sessions) {
            // Act and assert
            -9_223_372_036_854_775_808
            |> should
            |> write_on_server(sessions, codec.int, "int8")
            |> be_ok()
            |> be_some()
            |> be_equal("-9223372036854775808")
            |> or_fail_with(
              "Expected the server text -9223372036854775808 of int8",
            )
          }),
          it("reads int8 -9223372036854775808", fn(sessions) {
            // Act and assert
            Some("-9223372036854775808")
            |> should
            |> read_on_server(sessions, codec.int, "int8")
            |> be_ok()
            |> be_equal(-9_223_372_036_854_775_808)
            |> or_fail_with(
              "Expected the int8 -9223372036854775808 to read as its Gleam value",
            )
          }),
          it("writes int8 9223372036854775807", fn(sessions) {
            // Act and assert
            9_223_372_036_854_775_807
            |> should
            |> write_on_server(sessions, codec.int, "int8")
            |> be_ok()
            |> be_some()
            |> be_equal("9223372036854775807")
            |> or_fail_with(
              "Expected the server text 9223372036854775807 of int8",
            )
          }),
          it("reads int8 9223372036854775807", fn(sessions) {
            // Act and assert
            Some("9223372036854775807")
            |> should
            |> read_on_server(sessions, codec.int, "int8")
            |> be_ok()
            |> be_equal(9_223_372_036_854_775_807)
            |> or_fail_with(
              "Expected the int8 9223372036854775807 to read as its Gleam value",
            )
          }),
          it("writes oid 0", fn(sessions) {
            // Act and assert
            0
            |> should
            |> write_on_server(sessions, codec.int, "oid")
            |> be_ok()
            |> be_some()
            |> be_equal("0")
            |> or_fail_with("Expected the server text 0 of oid")
          }),
          it("reads oid 0", fn(sessions) {
            // Act and assert
            Some("0")
            |> should
            |> read_on_server(sessions, codec.int, "oid")
            |> be_ok()
            |> be_equal(0)
            |> or_fail_with("Expected the oid 0 to read as its Gleam value")
          }),
          it("writes oid 4294967295", fn(sessions) {
            // Act and assert
            4_294_967_295
            |> should
            |> write_on_server(sessions, codec.int, "oid")
            |> be_ok()
            |> be_some()
            |> be_equal("4294967295")
            |> or_fail_with("Expected the server text 4294967295 of oid")
          }),
          it("reads oid 4294967295", fn(sessions) {
            // Act and assert
            Some("4294967295")
            |> should
            |> read_on_server(sessions, codec.int, "oid")
            |> be_ok()
            |> be_equal(4_294_967_295)
            |> or_fail_with(
              "Expected the oid 4294967295 to read as its Gleam value",
            )
          }),
          it("writes int4 NULL", fn(sessions) {
            // Act and assert
            None
            |> should
            |> write_on_server(sessions, codec.nullable(codec.int), "int4")
            |> be_ok()
            |> be_none()
            |> or_fail_with("Expected the server text NULL of int4")
          }),
          it("reads int4 NULL", fn(sessions) {
            // Act and assert
            None
            |> should
            |> read_on_server(sessions, codec.nullable(codec.int), "int4")
            |> be_ok()
            |> be_equal(None)
            |> or_fail_with("Expected the int4 NULL to read as its Gleam value")
          }),
          it("writes int4 7", fn(sessions) {
            // Act and assert
            Some(7)
            |> should
            |> write_on_server(sessions, codec.nullable(codec.int), "int4")
            |> be_ok()
            |> be_some()
            |> be_equal("7")
            |> or_fail_with("Expected the server text 7 of int4")
          }),
          it("reads int4 7", fn(sessions) {
            // Act and assert
            Some("7")
            |> should
            |> read_on_server(sessions, codec.nullable(codec.int), "int4")
            |> be_ok()
            |> be_equal(Some(7))
            |> or_fail_with("Expected the int4 7 to read as its Gleam value")
          }),
          it("writes bool true", fn(sessions) {
            // Act and assert
            True
            |> should
            |> write_on_server(sessions, codec.bool, "bool")
            |> be_ok()
            |> be_some()
            |> be_equal("true")
            |> or_fail_with("Expected the server text true of bool")
          }),
          it("reads bool true", fn(sessions) {
            // Act and assert
            Some("true")
            |> should
            |> read_on_server(sessions, codec.bool, "bool")
            |> be_ok()
            |> be_equal(True)
            |> or_fail_with("Expected the bool true to read as its Gleam value")
          }),
          it("writes bool false", fn(sessions) {
            // Act and assert
            False
            |> should
            |> write_on_server(sessions, codec.bool, "bool")
            |> be_ok()
            |> be_some()
            |> be_equal("false")
            |> or_fail_with("Expected the server text false of bool")
          }),
          it("reads bool false", fn(sessions) {
            // Act and assert
            Some("false")
            |> should
            |> read_on_server(sessions, codec.bool, "bool")
            |> be_ok()
            |> be_equal(False)
            |> or_fail_with(
              "Expected the bool false to read as its Gleam value",
            )
          }),
          it("writes numeric 0", fn(sessions) {
            // Act and assert
            "0"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("0")
            |> or_fail_with("Expected the server text 0 of numeric")
          }),
          it("reads numeric 0", fn(sessions) {
            // Act and assert
            Some("0")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("0")
            |> or_fail_with("Expected the numeric 0 to read as its Gleam value")
          }),
          it("writes numeric 1234.5600", fn(sessions) {
            // Act and assert
            "1234.5600"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("1234.5600")
            |> or_fail_with("Expected the server text 1234.5600 of numeric")
          }),
          it("reads numeric 1234.5600", fn(sessions) {
            // Act and assert
            Some("1234.5600")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("1234.5600")
            |> or_fail_with(
              "Expected the numeric 1234.5600 to read as its Gleam value",
            )
          }),
          it("writes numeric -0.001", fn(sessions) {
            // Act and assert
            "-0.001"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("-0.001")
            |> or_fail_with("Expected the server text -0.001 of numeric")
          }),
          it("reads numeric -0.001", fn(sessions) {
            // Act and assert
            Some("-0.001")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("-0.001")
            |> or_fail_with(
              "Expected the numeric -0.001 to read as its Gleam value",
            )
          }),
          it("writes numeric 0.0000000001", fn(sessions) {
            // Act and assert
            "0.0000000001"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("0.0000000001")
            |> or_fail_with("Expected the server text 0.0000000001 of numeric")
          }),
          it("reads numeric 0.0000000001", fn(sessions) {
            // Act and assert
            Some("0.0000000001")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("0.0000000001")
            |> or_fail_with(
              "Expected the numeric 0.0000000001 to read as its Gleam value",
            )
          }),
          it(
            "writes numeric 123456789012345678901234567890.123456789",
            fn(sessions) {
              // Act and assert
              "123456789012345678901234567890.123456789"
              |> should
              |> write_on_server(sessions, codec.numeric, "numeric")
              |> be_ok()
              |> be_some()
              |> be_equal("123456789012345678901234567890.123456789")
              |> or_fail_with(
                "Expected the server text 123456789012345678901234567890.123456789 of numeric",
              )
            },
          ),
          it(
            "reads numeric 123456789012345678901234567890.123456789",
            fn(sessions) {
              // Act and assert
              Some("123456789012345678901234567890.123456789")
              |> should
              |> read_on_server(sessions, codec.numeric, "numeric")
              |> be_ok()
              |> be_equal("123456789012345678901234567890.123456789")
              |> or_fail_with(
                "Expected the numeric 123456789012345678901234567890.123456789 to read as its Gleam value",
              )
            },
          ),
          it("writes numeric 10000", fn(sessions) {
            // Act and assert
            "10000"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("10000")
            |> or_fail_with("Expected the server text 10000 of numeric")
          }),
          it("reads numeric 10000", fn(sessions) {
            // Act and assert
            Some("10000")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("10000")
            |> or_fail_with(
              "Expected the numeric 10000 to read as its Gleam value",
            )
          }),
          it("writes numeric NaN", fn(sessions) {
            // Act and assert
            "NaN"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("NaN")
            |> or_fail_with("Expected the server text NaN of numeric")
          }),
          it("reads numeric NaN", fn(sessions) {
            // Act and assert
            Some("NaN")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("NaN")
            |> or_fail_with(
              "Expected the numeric NaN to read as its Gleam value",
            )
          }),
          it("writes numeric Infinity", fn(sessions) {
            // Act and assert
            "Infinity"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("Infinity")
            |> or_fail_with("Expected the server text Infinity of numeric")
          }),
          it("reads numeric Infinity", fn(sessions) {
            // Act and assert
            Some("Infinity")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("Infinity")
            |> or_fail_with(
              "Expected the numeric Infinity to read as its Gleam value",
            )
          }),
          it("writes numeric -Infinity", fn(sessions) {
            // Act and assert
            "-Infinity"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_some()
            |> be_equal("-Infinity")
            |> or_fail_with("Expected the server text -Infinity of numeric")
          }),
          it("reads numeric -Infinity", fn(sessions) {
            // Act and assert
            Some("-Infinity")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric")
            |> be_ok()
            |> be_equal("-Infinity")
            |> or_fail_with(
              "Expected the numeric -Infinity to read as its Gleam value",
            )
          }),
          it("writes numeric(10,2) 3.10", fn(sessions) {
            // Act and assert
            "3.10"
            |> should
            |> write_on_server(sessions, codec.numeric, "numeric(10,2)")
            |> be_ok()
            |> be_some()
            |> be_equal("3.10")
            |> or_fail_with("Expected the server text 3.10 of numeric(10,2)")
          }),
          it("reads numeric(10,2) 3.10", fn(sessions) {
            // Act and assert
            Some("3.10")
            |> should
            |> read_on_server(sessions, codec.numeric, "numeric(10,2)")
            |> be_ok()
            |> be_equal("3.10")
            |> or_fail_with(
              "Expected the numeric(10,2) 3.10 to read as its Gleam value",
            )
          }),
          // The floats, with the values that the codec refuses to read.
          it("writes float4 1.5", fn(sessions) {
            // Act and assert
            1.5
            |> should
            |> write_on_server(sessions, codec.float, "float4")
            |> be_ok()
            |> be_some()
            |> be_equal("1.5")
            |> or_fail_with("Expected the server text 1.5 of float4")
          }),
          it("reads float4 1.5", fn(sessions) {
            // Act and assert
            Some("1.5")
            |> should
            |> read_on_server(sessions, codec.float, "float4")
            |> be_ok()
            |> be_equal(1.5)
            |> or_fail_with(
              "Expected the float4 1.5 to read as its Gleam value",
            )
          }),
          it("writes float4 0.1", fn(sessions) {
            // Act and assert
            0.1
            |> should
            |> write_on_server(sessions, codec.float, "float4")
            |> be_ok()
            |> be_some()
            |> be_equal("0.1")
            |> or_fail_with("Expected the server text 0.1 of float4")
          }),
          it("reads float4 0.1", fn(sessions) {
            // Act and assert
            Some("0.1")
            |> should
            |> read_on_server(sessions, codec.float, "float4")
            |> be_ok()
            |> be_equal(0.10000000149011612)
            |> or_fail_with(
              "Expected the float4 0.1 to read as its Gleam value",
            )
          }),
          it("writes float8 0.1", fn(sessions) {
            // Act and assert
            0.1
            |> should
            |> write_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_some()
            |> be_equal("0.1")
            |> or_fail_with("Expected the server text 0.1 of float8")
          }),
          it("reads float8 0.1", fn(sessions) {
            // Act and assert
            Some("0.1")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_equal(0.1)
            |> or_fail_with(
              "Expected the float8 0.1 to read as its Gleam value",
            )
          }),
          it("writes float8 -0", fn(sessions) {
            // Act and assert
            -0.0
            |> should
            |> write_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_some()
            |> be_equal("-0")
            |> or_fail_with("Expected the server text -0 of float8")
          }),
          it("reads float8 -0", fn(sessions) {
            // Act and assert
            Some("-0")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_equal(-0.0)
            |> or_fail_with("Expected the float8 -0 to read as its Gleam value")
          }),
          it("writes float8 1e+300", fn(sessions) {
            // Act and assert
            1.0e300
            |> should
            |> write_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_some()
            |> be_equal("1e+300")
            |> or_fail_with("Expected the server text 1e+300 of float8")
          }),
          it("reads float8 1e+300", fn(sessions) {
            // Act and assert
            Some("1e+300")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_equal(1.0e300)
            |> or_fail_with(
              "Expected the float8 1e+300 to read as its Gleam value",
            )
          }),
          it("writes float8 -2.5e-300", fn(sessions) {
            // Act and assert
            -2.5e-300
            |> should
            |> write_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_some()
            |> be_equal("-2.5e-300")
            |> or_fail_with("Expected the server text -2.5e-300 of float8")
          }),
          it("reads float8 -2.5e-300", fn(sessions) {
            // Act and assert
            Some("-2.5e-300")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_ok()
            |> be_equal(-2.5e-300)
            |> or_fail_with(
              "Expected the float8 -2.5e-300 to read as its Gleam value",
            )
          }),
          it("refuses to read float8 NaN", fn(sessions) {
            // Act and assert
            Some("NaN")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_error()
            |> be_equal(ReadDecodeFailed(OutOfRange("NaN")))
            |> or_fail_with("Expected the codec to refuse the float8 NaN")
          }),
          it("refuses to read float8 -Infinity", fn(sessions) {
            // Act and assert
            Some("-Infinity")
            |> should
            |> read_on_server(sessions, codec.float, "float8")
            |> be_error()
            |> be_equal(ReadDecodeFailed(OutOfRange("-Infinity")))
            |> or_fail_with("Expected the codec to refuse the float8 -Infinity")
          }),
          it("refuses to read float4 Infinity", fn(sessions) {
            // Act and assert
            Some("Infinity")
            |> should
            |> read_on_server(sessions, codec.float, "float4")
            |> be_error()
            |> be_equal(ReadDecodeFailed(OutOfRange("Infinity")))
            |> or_fail_with("Expected the codec to refuse the float4 Infinity")
          }),
          // The texts, bytes, UUIDs, JSON, hstore and ltree.
          it("writes text hello", fn(sessions) {
            // Act and assert
            "hello"
            |> should
            |> write_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_some()
            |> be_equal("hello")
            |> or_fail_with("Expected the server text hello of text")
          }),
          it("reads text hello", fn(sessions) {
            // Act and assert
            Some("hello")
            |> should
            |> read_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_equal("hello")
            |> or_fail_with(
              "Expected the text hello to read as its Gleam value",
            )
          }),
          it("writes text ", fn(sessions) {
            // Act and assert
            ""
            |> should
            |> write_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_some()
            |> be_equal("")
            |> or_fail_with("Expected an empty server text of text")
          }),
          it("reads text ", fn(sessions) {
            // Act and assert
            Some("")
            |> should
            |> read_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_equal("")
            |> or_fail_with("Expected an empty text to read as its Gleam value")
          }),
          it("writes text Grüße ✓ 日本", fn(sessions) {
            // Act and assert
            "Grüße ✓ 日本"
            |> should
            |> write_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_some()
            |> be_equal("Grüße ✓ 日本")
            |> or_fail_with("Expected the server text Grüße ✓ 日本 of text")
          }),
          it("reads text Grüße ✓ 日本", fn(sessions) {
            // Act and assert
            Some("Grüße ✓ 日本")
            |> should
            |> read_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_equal("Grüße ✓ 日本")
            |> or_fail_with(
              "Expected the text Grüße ✓ 日本 to read as its Gleam value",
            )
          }),
          it("writes text a'b\\c\"d", fn(sessions) {
            // Act and assert
            "a'b\\c\"d"
            |> should
            |> write_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_some()
            |> be_equal("a'b\\c\"d")
            |> or_fail_with("Expected the server text a'b\\c\"d of text")
          }),
          it("reads text a'b\\c\"d", fn(sessions) {
            // Act and assert
            Some("a'b\\c\"d")
            |> should
            |> read_on_server(sessions, codec.text, "text")
            |> be_ok()
            |> be_equal("a'b\\c\"d")
            |> or_fail_with(
              "Expected the text a'b\\c\"d to read as its Gleam value",
            )
          }),
          it("writes varchar(5) abc", fn(sessions) {
            // Act and assert
            "abc"
            |> should
            |> write_on_server(sessions, codec.text, "varchar(5)")
            |> be_ok()
            |> be_some()
            |> be_equal("abc")
            |> or_fail_with("Expected the server text abc of varchar(5)")
          }),
          it("reads varchar(5) abc", fn(sessions) {
            // Act and assert
            Some("abc")
            |> should
            |> read_on_server(sessions, codec.text, "varchar(5)")
            |> be_ok()
            |> be_equal("abc")
            |> or_fail_with(
              "Expected the varchar(5) abc to read as its Gleam value",
            )
          }),
          // The cast of char to text drops the padding.
          it("writes char(3) ab", fn(sessions) {
            // Act and assert
            "ab "
            |> should
            |> write_on_server(sessions, codec.text, "char(3)")
            |> be_ok()
            |> be_some()
            |> be_equal("ab")
            |> or_fail_with("Expected the server text ab of char(3)")
          }),
          it("reads char(3) ab", fn(sessions) {
            // Act and assert
            Some("ab")
            |> should
            |> read_on_server(sessions, codec.text, "char(3)")
            |> be_ok()
            |> be_equal("ab ")
            |> or_fail_with(
              "Expected the char(3) ab to read as its Gleam value",
            )
          }),
          it("writes name probe_name", fn(sessions) {
            // Act and assert
            "probe_name"
            |> should
            |> write_on_server(sessions, codec.text, "name")
            |> be_ok()
            |> be_some()
            |> be_equal("probe_name")
            |> or_fail_with("Expected the server text probe_name of name")
          }),
          it("reads name probe_name", fn(sessions) {
            // Act and assert
            Some("probe_name")
            |> should
            |> read_on_server(sessions, codec.text, "name")
            |> be_ok()
            |> be_equal("probe_name")
            |> or_fail_with(
              "Expected the name probe_name to read as its Gleam value",
            )
          }),
          it("writes citext MiXeD", fn(sessions) {
            // Act and assert
            "MiXeD"
            |> should
            |> write_on_server(sessions, codec.text, "citext")
            |> be_ok()
            |> be_some()
            |> be_equal("MiXeD")
            |> or_fail_with("Expected the server text MiXeD of citext")
          }),
          it("reads citext MiXeD", fn(sessions) {
            // Act and assert
            Some("MiXeD")
            |> should
            |> read_on_server(sessions, codec.text, "citext")
            |> be_ok()
            |> be_equal("MiXeD")
            |> or_fail_with(
              "Expected the citext MiXeD to read as its Gleam value",
            )
          }),
          it("writes bytea \\x0001ff", fn(sessions) {
            // Act and assert
            <<0, 1, 255>>
            |> should
            |> write_on_server(sessions, codec.bytea, "bytea")
            |> be_ok()
            |> be_some()
            |> be_equal("\\x0001ff")
            |> or_fail_with("Expected the server text \\x0001ff of bytea")
          }),
          it("reads bytea \\x0001ff", fn(sessions) {
            // Act and assert
            Some("\\x0001ff")
            |> should
            |> read_on_server(sessions, codec.bytea, "bytea")
            |> be_ok()
            |> be_equal(<<0, 1, 255>>)
            |> or_fail_with(
              "Expected the bytea \\x0001ff to read as its Gleam value",
            )
          }),
          it("writes bytea \\x", fn(sessions) {
            // Act and assert
            <<>>
            |> should
            |> write_on_server(sessions, codec.bytea, "bytea")
            |> be_ok()
            |> be_some()
            |> be_equal("\\x")
            |> or_fail_with("Expected the server text \\x of bytea")
          }),
          it("reads bytea \\x", fn(sessions) {
            // Act and assert
            Some("\\x")
            |> should
            |> read_on_server(sessions, codec.bytea, "bytea")
            |> be_ok()
            |> be_equal(<<>>)
            |> or_fail_with("Expected the bytea \\x to read as its Gleam value")
          }),
          it("writes uuid a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", fn(sessions) {
            // Act and assert
            dream_uuid.from_string("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.uuid, "uuid")
            |> be_ok()
            |> be_some()
            |> be_equal("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
            |> or_fail_with(
              "Expected the server text a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11 of uuid",
            )
          }),
          it("reads uuid a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", fn(sessions) {
            // Act and assert
            Some("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
            |> should
            |> read_on_server(sessions, codec.uuid, "uuid")
            |> be_ok()
            |> have_uuid_text()
            |> be_equal("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
            |> or_fail_with(
              "Expected the uuid a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11 to read as its Gleam value",
            )
          }),
          it("writes uuid 00000000-0000-0000-0000-000000000000", fn(sessions) {
            // Act and assert
            dream_uuid.from_string("00000000-0000-0000-0000-000000000000")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.uuid, "uuid")
            |> be_ok()
            |> be_some()
            |> be_equal("00000000-0000-0000-0000-000000000000")
            |> or_fail_with(
              "Expected the server text 00000000-0000-0000-0000-000000000000 of uuid",
            )
          }),
          it("reads uuid 00000000-0000-0000-0000-000000000000", fn(sessions) {
            // Act and assert
            Some("00000000-0000-0000-0000-000000000000")
            |> should
            |> read_on_server(sessions, codec.uuid, "uuid")
            |> be_ok()
            |> have_uuid_text()
            |> be_equal("00000000-0000-0000-0000-000000000000")
            |> or_fail_with(
              "Expected the uuid 00000000-0000-0000-0000-000000000000 to read as its Gleam value",
            )
          }),
          it("writes json {\"b\":1,  \"a\":[1,2]}", fn(sessions) {
            // Act and assert
            json.parse_json("{\"b\":1,  \"a\":[1,2]}")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> be_some()
            |> be_equal("{\"b\":1,  \"a\":[1,2]}")
            |> or_fail_with(
              "Expected the server text {\"b\":1,  \"a\":[1,2]} of json",
            )
          }),
          it("reads json {\"b\":1,  \"a\":[1,2]}", fn(sessions) {
            // Act and assert
            Some("{\"b\":1,  \"a\":[1,2]}")
            |> should
            |> read_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> have_json_text()
            |> be_equal("{\"b\":1,  \"a\":[1,2]}")
            |> or_fail_with(
              "Expected the json {\"b\":1,  \"a\":[1,2]} to read as its Gleam value",
            )
          }),
          it("writes json \"text\"", fn(sessions) {
            // Act and assert
            json.parse_json("\"text\"")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> be_some()
            |> be_equal("\"text\"")
            |> or_fail_with("Expected the server text \"text\" of json")
          }),
          it("reads json \"text\"", fn(sessions) {
            // Act and assert
            Some("\"text\"")
            |> should
            |> read_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> have_json_text()
            |> be_equal("\"text\"")
            |> or_fail_with(
              "Expected the json \"text\" to read as its Gleam value",
            )
          }),
          it("writes json null", fn(sessions) {
            // Act and assert
            json.parse_json("null")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> be_some()
            |> be_equal("null")
            |> or_fail_with("Expected the server text null of json")
          }),
          it("reads json null", fn(sessions) {
            // Act and assert
            Some("null")
            |> should
            |> read_on_server(sessions, codec.json, "json")
            |> be_ok()
            |> have_json_text()
            |> be_equal("null")
            |> or_fail_with("Expected the json null to read as its Gleam value")
          }),
          it(
            "writes jsonb {\"a\": 1, \"b\": [true, null, \"é\"]}",
            fn(sessions) {
              // Act and assert
              json.parse_json("{\"a\": 1, \"b\": [true, null, \"é\"]}")
              |> should
              |> be_ok()
              |> write_on_server(sessions, codec.jsonb, "jsonb")
              |> be_ok()
              |> be_some()
              |> be_equal("{\"a\": 1, \"b\": [true, null, \"é\"]}")
              |> or_fail_with(
                "Expected the server text {\"a\": 1, \"b\": [true, null, \"é\"]} of jsonb",
              )
            },
          ),
          it("reads jsonb {\"a\": 1, \"b\": [true, null, \"é\"]}", fn(sessions) {
            // Act and assert
            Some("{\"a\": 1, \"b\": [true, null, \"é\"]}")
            |> should
            |> read_on_server(sessions, codec.jsonb, "jsonb")
            |> be_ok()
            |> have_json_text()
            |> be_equal("{\"a\": 1, \"b\": [true, null, \"é\"]}")
            |> or_fail_with(
              "Expected the jsonb {\"a\": 1, \"b\": [true, null, \"é\"]} to read as its Gleam value",
            )
          }),
          it("writes jsonb {\"a\": 1, \"b\": 2}", fn(sessions) {
            // Act and assert
            json.parse_json("{\"b\":2,\"a\":1}")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.jsonb, "jsonb")
            |> be_ok()
            |> be_some()
            |> be_equal("{\"a\": 1, \"b\": 2}")
            |> or_fail_with(
              "Expected the server text {\"a\": 1, \"b\": 2} of jsonb",
            )
          }),
          it("reads jsonb {\"a\": 1, \"b\": 2}", fn(sessions) {
            // Act and assert
            Some("{\"a\": 1, \"b\": 2}")
            |> should
            |> read_on_server(sessions, codec.jsonb, "jsonb")
            |> be_ok()
            |> have_json_text()
            |> be_equal("{\"a\": 1, \"b\": 2}")
            |> or_fail_with(
              "Expected the jsonb {\"a\": 1, \"b\": 2} to read as its Gleam value",
            )
          }),
          it("writes jsonb 12.50", fn(sessions) {
            // Act and assert
            json.parse_json("12.50")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.jsonb, "jsonb")
            |> be_ok()
            |> be_some()
            |> be_equal("12.50")
            |> or_fail_with("Expected the server text 12.50 of jsonb")
          }),
          it("reads jsonb 12.50", fn(sessions) {
            // Act and assert
            Some("12.50")
            |> should
            |> read_on_server(sessions, codec.jsonb, "jsonb")
            |> be_ok()
            |> have_json_text()
            |> be_equal("12.50")
            |> or_fail_with(
              "Expected the jsonb 12.50 to read as its Gleam value",
            )
          }),
          it("writes hstore \"a\"=>\"1\", \"b\"=>NULL", fn(sessions) {
            // Act and assert
            dict.from_list([#("a", Some("1")), #("b", None)])
            |> should
            |> write_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_some()
            |> be_equal("\"a\"=>\"1\", \"b\"=>NULL")
            |> or_fail_with(
              "Expected the server text \"a\"=>\"1\", \"b\"=>NULL of hstore",
            )
          }),
          it("reads hstore \"a\"=>\"1\", \"b\"=>NULL", fn(sessions) {
            // Act and assert
            Some("\"a\"=>\"1\", \"b\"=>NULL")
            |> should
            |> read_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_equal(dict.from_list([#("a", Some("1")), #("b", None)]))
            |> or_fail_with(
              "Expected the hstore \"a\"=>\"1\", \"b\"=>NULL to read as its Gleam value",
            )
          }),
          it("writes hstore \"x\\\"y\"=>\"back\\\\slash\"", fn(sessions) {
            // Act and assert
            dict.from_list([#("x\"y", Some("back\\slash"))])
            |> should
            |> write_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_some()
            |> be_equal("\"x\\\"y\"=>\"back\\\\slash\"")
            |> or_fail_with(
              "Expected the server text \"x\\\"y\"=>\"back\\\\slash\" of hstore",
            )
          }),
          it("reads hstore \"x\\\"y\"=>\"back\\\\slash\"", fn(sessions) {
            // Act and assert
            Some("\"x\\\"y\"=>\"back\\\\slash\"")
            |> should
            |> read_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_equal(dict.from_list([#("x\"y", Some("back\\slash"))]))
            |> or_fail_with(
              "Expected the hstore \"x\\\"y\"=>\"back\\\\slash\" to read as its Gleam value",
            )
          }),
          it("writes hstore ", fn(sessions) {
            // Act and assert
            dict.new()
            |> should
            |> write_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_some()
            |> be_equal("")
            |> or_fail_with("Expected an empty server text of hstore")
          }),
          it("reads hstore ", fn(sessions) {
            // Act and assert
            Some("")
            |> should
            |> read_on_server(sessions, codec.hstore(), "hstore")
            |> be_ok()
            |> be_equal(dict.new())
            |> or_fail_with(
              "Expected an empty hstore to read as its Gleam value",
            )
          }),
          it("writes ltree top.science.astronomy", fn(sessions) {
            // Act and assert
            "top.science.astronomy"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("ltree"),
              "ltree",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("top.science.astronomy")
            |> or_fail_with(
              "Expected the server text top.science.astronomy of ltree",
            )
          }),
          it("reads ltree top.science.astronomy", fn(sessions) {
            // Act and assert
            Some("top.science.astronomy")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("ltree"),
              "ltree",
            )
            |> be_ok()
            |> be_equal("top.science.astronomy")
            |> or_fail_with(
              "Expected the ltree top.science.astronomy to read as its Gleam value",
            )
          }),
          // The dates, times, timestamps and intervals.
          it("writes date 2024-02-29", fn(sessions) {
            // Act and assert
            Date(2024, February, 29)
            |> should
            |> write_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("2024-02-29")
            |> or_fail_with("Expected the server text 2024-02-29 of date")
          }),
          it("reads date 2024-02-29", fn(sessions) {
            // Act and assert
            Some("2024-02-29")
            |> should
            |> read_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_equal(Date(2024, February, 29))
            |> or_fail_with(
              "Expected the date 2024-02-29 to read as its Gleam value",
            )
          }),
          it("writes date 0001-01-01", fn(sessions) {
            // Act and assert
            Date(1, January, 1)
            |> should
            |> write_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("0001-01-01")
            |> or_fail_with("Expected the server text 0001-01-01 of date")
          }),
          it("reads date 0001-01-01", fn(sessions) {
            // Act and assert
            Some("0001-01-01")
            |> should
            |> read_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_equal(Date(1, January, 1))
            |> or_fail_with(
              "Expected the date 0001-01-01 to read as its Gleam value",
            )
          }),
          it("writes date 0044-03-15 BC", fn(sessions) {
            // Act and assert
            Date(-43, March, 15)
            |> should
            |> write_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("0044-03-15 BC")
            |> or_fail_with("Expected the server text 0044-03-15 BC of date")
          }),
          it("reads date 0044-03-15 BC", fn(sessions) {
            // Act and assert
            Some("0044-03-15 BC")
            |> should
            |> read_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_equal(Date(-43, March, 15))
            |> or_fail_with(
              "Expected the date 0044-03-15 BC to read as its Gleam value",
            )
          }),
          it("writes date 10000-01-01", fn(sessions) {
            // Act and assert
            Date(10_000, January, 1)
            |> should
            |> write_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("10000-01-01")
            |> or_fail_with("Expected the server text 10000-01-01 of date")
          }),
          it("reads date 10000-01-01", fn(sessions) {
            // Act and assert
            Some("10000-01-01")
            |> should
            |> read_on_server(sessions, codec.date, "date")
            |> be_ok()
            |> be_equal(Date(10_000, January, 1))
            |> or_fail_with(
              "Expected the date 10000-01-01 to read as its Gleam value",
            )
          }),
          it("refuses to read date infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(sessions, codec.date, "date")
            |> be_error()
            |> be_equal(ReadDecodeFailed(OutOfRange("infinity")))
            |> or_fail_with("Expected the codec to refuse the date infinity")
          }),
          it("writes date 2000-01-01", fn(sessions) {
            // Act and assert
            Finite(Date(2000, January, 1))
            |> should
            |> write_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("2000-01-01")
            |> or_fail_with("Expected the server text 2000-01-01 of date")
          }),
          it("reads date 2000-01-01", fn(sessions) {
            // Act and assert
            Some("2000-01-01")
            |> should
            |> read_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_equal(Finite(Date(2000, January, 1)))
            |> or_fail_with(
              "Expected the date 2000-01-01 to read as its Gleam value",
            )
          }),
          it("writes date infinity", fn(sessions) {
            // Act and assert
            PositiveInfinity
            |> should
            |> write_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("infinity")
            |> or_fail_with("Expected the server text infinity of date")
          }),
          it("reads date infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_equal(PositiveInfinity)
            |> or_fail_with(
              "Expected the date infinity to read as its Gleam value",
            )
          }),
          it("writes date -infinity", fn(sessions) {
            // Act and assert
            NegativeInfinity
            |> should
            |> write_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_some()
            |> be_equal("-infinity")
            |> or_fail_with("Expected the server text -infinity of date")
          }),
          it("reads date -infinity", fn(sessions) {
            // Act and assert
            Some("-infinity")
            |> should
            |> read_on_server(sessions, codec.date_or_infinite, "date")
            |> be_ok()
            |> be_equal(NegativeInfinity)
            |> or_fail_with(
              "Expected the date -infinity to read as its Gleam value",
            )
          }),
          it("writes time 13:45:30.123456", fn(sessions) {
            // Act and assert
            TimeOfDay(13, 45, 30, 123_456_000)
            |> should
            |> write_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_some()
            |> be_equal("13:45:30.123456")
            |> or_fail_with("Expected the server text 13:45:30.123456 of time")
          }),
          it("reads time 13:45:30.123456", fn(sessions) {
            // Act and assert
            Some("13:45:30.123456")
            |> should
            |> read_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_equal(TimeOfDay(13, 45, 30, 123_456_000))
            |> or_fail_with(
              "Expected the time 13:45:30.123456 to read as its Gleam value",
            )
          }),
          it("writes time 00:00:00", fn(sessions) {
            // Act and assert
            TimeOfDay(0, 0, 0, 0)
            |> should
            |> write_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_some()
            |> be_equal("00:00:00")
            |> or_fail_with("Expected the server text 00:00:00 of time")
          }),
          it("reads time 00:00:00", fn(sessions) {
            // Act and assert
            Some("00:00:00")
            |> should
            |> read_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_equal(TimeOfDay(0, 0, 0, 0))
            |> or_fail_with(
              "Expected the time 00:00:00 to read as its Gleam value",
            )
          }),
          it("writes time 23:59:59.999999", fn(sessions) {
            // Act and assert
            TimeOfDay(23, 59, 59, 999_999_000)
            |> should
            |> write_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_some()
            |> be_equal("23:59:59.999999")
            |> or_fail_with("Expected the server text 23:59:59.999999 of time")
          }),
          it("reads time 23:59:59.999999", fn(sessions) {
            // Act and assert
            Some("23:59:59.999999")
            |> should
            |> read_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_equal(TimeOfDay(23, 59, 59, 999_999_000))
            |> or_fail_with(
              "Expected the time 23:59:59.999999 to read as its Gleam value",
            )
          }),
          it("writes time 24:00:00", fn(sessions) {
            // Act and assert
            TimeOfDay(24, 0, 0, 0)
            |> should
            |> write_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_some()
            |> be_equal("24:00:00")
            |> or_fail_with("Expected the server text 24:00:00 of time")
          }),
          it("reads time 24:00:00", fn(sessions) {
            // Act and assert
            Some("24:00:00")
            |> should
            |> read_on_server(sessions, codec.time, "time")
            |> be_ok()
            |> be_equal(TimeOfDay(24, 0, 0, 0))
            |> or_fail_with(
              "Expected the time 24:00:00 to read as its Gleam value",
            )
          }),
          it("writes timetz 13:45:30+02", fn(sessions) {
            // Act and assert
            TimeWithOffset(TimeOfDay(13, 45, 30, 0), 7200)
            |> should
            |> write_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_some()
            |> be_equal("13:45:30+02")
            |> or_fail_with("Expected the server text 13:45:30+02 of timetz")
          }),
          it("reads timetz 13:45:30+02", fn(sessions) {
            // Act and assert
            Some("13:45:30+02")
            |> should
            |> read_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_equal(TimeWithOffset(TimeOfDay(13, 45, 30, 0), 7200))
            |> or_fail_with(
              "Expected the timetz 13:45:30+02 to read as its Gleam value",
            )
          }),
          it("writes timetz 01:02:03.000004-05:30", fn(sessions) {
            // Act and assert
            TimeWithOffset(TimeOfDay(1, 2, 3, 4000), -19_800)
            |> should
            |> write_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_some()
            |> be_equal("01:02:03.000004-05:30")
            |> or_fail_with(
              "Expected the server text 01:02:03.000004-05:30 of timetz",
            )
          }),
          it("reads timetz 01:02:03.000004-05:30", fn(sessions) {
            // Act and assert
            Some("01:02:03.000004-05:30")
            |> should
            |> read_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_equal(TimeWithOffset(TimeOfDay(1, 2, 3, 4000), -19_800))
            |> or_fail_with(
              "Expected the timetz 01:02:03.000004-05:30 to read as its Gleam value",
            )
          }),
          it("writes timestamp 2024-02-29 13:45:30.123456", fn(sessions) {
            // Act and assert
            timestamp.from_calendar(
              date: Date(2024, February, 29),
              time: TimeOfDay(13, 45, 30, 123_456_000),
              offset: duration.seconds(0),
            )
            |> should
            |> write_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_some()
            |> be_equal("2024-02-29 13:45:30.123456")
            |> or_fail_with(
              "Expected the server text 2024-02-29 13:45:30.123456 of timestamp",
            )
          }),
          it("reads timestamp 2024-02-29 13:45:30.123456", fn(sessions) {
            // Act and assert
            Some("2024-02-29 13:45:30.123456")
            |> should
            |> read_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_equal(timestamp.from_calendar(
              date: Date(2024, February, 29),
              time: TimeOfDay(13, 45, 30, 123_456_000),
              offset: duration.seconds(0),
            ))
            |> or_fail_with(
              "Expected the timestamp 2024-02-29 13:45:30.123456 to read as its Gleam value",
            )
          }),
          it("writes timestamp 1970-01-01 00:00:00", fn(sessions) {
            // Act and assert
            timestamp.from_calendar(
              date: Date(1970, January, 1),
              time: TimeOfDay(0, 0, 0, 0),
              offset: duration.seconds(0),
            )
            |> should
            |> write_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_some()
            |> be_equal("1970-01-01 00:00:00")
            |> or_fail_with(
              "Expected the server text 1970-01-01 00:00:00 of timestamp",
            )
          }),
          it("reads timestamp 1970-01-01 00:00:00", fn(sessions) {
            // Act and assert
            Some("1970-01-01 00:00:00")
            |> should
            |> read_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_equal(timestamp.from_calendar(
              date: Date(1970, January, 1),
              time: TimeOfDay(0, 0, 0, 0),
              offset: duration.seconds(0),
            ))
            |> or_fail_with(
              "Expected the timestamp 1970-01-01 00:00:00 to read as its Gleam value",
            )
          }),
          it("writes timestamp 1900-01-01 00:00:00.000001", fn(sessions) {
            // Act and assert
            timestamp.from_calendar(
              date: Date(1900, January, 1),
              time: TimeOfDay(0, 0, 0, 1000),
              offset: duration.seconds(0),
            )
            |> should
            |> write_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_some()
            |> be_equal("1900-01-01 00:00:00.000001")
            |> or_fail_with(
              "Expected the server text 1900-01-01 00:00:00.000001 of timestamp",
            )
          }),
          it("reads timestamp 1900-01-01 00:00:00.000001", fn(sessions) {
            // Act and assert
            Some("1900-01-01 00:00:00.000001")
            |> should
            |> read_on_server(sessions, codec.timestamp, "timestamp")
            |> be_ok()
            |> be_equal(timestamp.from_calendar(
              date: Date(1900, January, 1),
              time: TimeOfDay(0, 0, 0, 1000),
              offset: duration.seconds(0),
            ))
            |> or_fail_with(
              "Expected the timestamp 1900-01-01 00:00:00.000001 to read as its Gleam value",
            )
          }),
          it("writes timestamp infinity", fn(sessions) {
            // Act and assert
            PositiveInfinity
            |> should
            |> write_on_server(
              sessions,
              codec.timestamp_or_infinite,
              "timestamp",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("infinity")
            |> or_fail_with("Expected the server text infinity of timestamp")
          }),
          it("reads timestamp infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(
              sessions,
              codec.timestamp_or_infinite,
              "timestamp",
            )
            |> be_ok()
            |> be_equal(PositiveInfinity)
            |> or_fail_with(
              "Expected the timestamp infinity to read as its Gleam value",
            )
          }),
          it("writes timestamp -infinity", fn(sessions) {
            // Act and assert
            NegativeInfinity
            |> should
            |> write_on_server(
              sessions,
              codec.timestamp_or_infinite,
              "timestamp",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("-infinity")
            |> or_fail_with("Expected the server text -infinity of timestamp")
          }),
          it("reads timestamp -infinity", fn(sessions) {
            // Act and assert
            Some("-infinity")
            |> should
            |> read_on_server(
              sessions,
              codec.timestamp_or_infinite,
              "timestamp",
            )
            |> be_ok()
            |> be_equal(NegativeInfinity)
            |> or_fail_with(
              "Expected the timestamp -infinity to read as its Gleam value",
            )
          }),
          it("writes timestamptz 2024-02-29 13:45:30.123456+00", fn(sessions) {
            // Act and assert
            timestamp.from_calendar(
              date: Date(2024, February, 29),
              time: TimeOfDay(13, 45, 30, 123_456_000),
              offset: duration.seconds(0),
            )
            |> should
            |> write_on_server(
              sessions,
              codec.timestamp_with_time_zone,
              "timestamptz",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("2024-02-29 13:45:30.123456+00")
            |> or_fail_with(
              "Expected the server text 2024-02-29 13:45:30.123456+00 of timestamptz",
            )
          }),
          it("reads timestamptz 2024-02-29 13:45:30.123456+00", fn(sessions) {
            // Act and assert
            Some("2024-02-29 13:45:30.123456+00")
            |> should
            |> read_on_server(
              sessions,
              codec.timestamp_with_time_zone,
              "timestamptz",
            )
            |> be_ok()
            |> be_equal(timestamp.from_calendar(
              date: Date(2024, February, 29),
              time: TimeOfDay(13, 45, 30, 123_456_000),
              offset: duration.seconds(0),
            ))
            |> or_fail_with(
              "Expected the timestamptz 2024-02-29 13:45:30.123456+00 to read as its Gleam value",
            )
          }),
          it("writes timestamptz infinity", fn(sessions) {
            // Act and assert
            PositiveInfinity
            |> should
            |> write_on_server(
              sessions,
              codec.timestamp_with_time_zone_or_infinite,
              "timestamptz",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("infinity")
            |> or_fail_with("Expected the server text infinity of timestamptz")
          }),
          it("reads timestamptz infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(
              sessions,
              codec.timestamp_with_time_zone_or_infinite,
              "timestamptz",
            )
            |> be_ok()
            |> be_equal(PositiveInfinity)
            |> or_fail_with(
              "Expected the timestamptz infinity to read as its Gleam value",
            )
          }),
          it(
            "writes interval 1 year 2 mons 3 days 01:02:03.000004",
            fn(sessions) {
              // Act and assert
              Interval(14, 3, 3_723_000_004)
              |> should
              |> write_on_server(sessions, codec.interval, "interval")
              |> be_ok()
              |> be_some()
              |> be_equal("1 year 2 mons 3 days 01:02:03.000004")
              |> or_fail_with(
                "Expected the server text 1 year 2 mons 3 days 01:02:03.000004 of interval",
              )
            },
          ),
          it(
            "reads interval 1 year 2 mons 3 days 01:02:03.000004",
            fn(sessions) {
              // Act and assert
              Some("1 year 2 mons 3 days 01:02:03.000004")
              |> should
              |> read_on_server(sessions, codec.interval, "interval")
              |> be_ok()
              |> be_equal(Interval(14, 3, 3_723_000_004))
              |> or_fail_with(
                "Expected the interval 1 year 2 mons 3 days 01:02:03.000004 to read as its Gleam value",
              )
            },
          ),
          it("writes interval -1 mons -2 days -00:00:03", fn(sessions) {
            // Act and assert
            Interval(-1, -2, -3_000_000)
            |> should
            |> write_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_some()
            |> be_equal("-1 mons -2 days -00:00:03")
            |> or_fail_with(
              "Expected the server text -1 mons -2 days -00:00:03 of interval",
            )
          }),
          it("reads interval -1 mons -2 days -00:00:03", fn(sessions) {
            // Act and assert
            Some("-1 mons -2 days -00:00:03")
            |> should
            |> read_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_equal(Interval(-1, -2, -3_000_000))
            |> or_fail_with(
              "Expected the interval -1 mons -2 days -00:00:03 to read as its Gleam value",
            )
          }),
          it("writes interval 00:00:00", fn(sessions) {
            // Act and assert
            Interval(0, 0, 0)
            |> should
            |> write_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_some()
            |> be_equal("00:00:00")
            |> or_fail_with("Expected the server text 00:00:00 of interval")
          }),
          it("reads interval 00:00:00", fn(sessions) {
            // Act and assert
            Some("00:00:00")
            |> should
            |> read_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_equal(Interval(0, 0, 0))
            |> or_fail_with(
              "Expected the interval 00:00:00 to read as its Gleam value",
            )
          }),
          it(
            "writes interval 1 year 2 mons 3 days 01:02:03.000004",
            fn(sessions) {
              // Act and assert
              Finite(Interval(14, 3, 3_723_000_004))
              |> should
              |> write_on_server(
                sessions,
                codec.interval_or_infinite,
                "interval",
              )
              |> be_ok()
              |> be_some()
              |> be_equal("1 year 2 mons 3 days 01:02:03.000004")
              |> or_fail_with(
                "Expected the server text 1 year 2 mons 3 days 01:02:03.000004 of interval",
              )
            },
          ),
          it(
            "reads interval 1 year 2 mons 3 days 01:02:03.000004",
            fn(sessions) {
              // Act and assert
              Some("1 year 2 mons 3 days 01:02:03.000004")
              |> should
              |> read_on_server(
                sessions,
                codec.interval_or_infinite,
                "interval",
              )
              |> be_ok()
              |> be_equal(Finite(Interval(14, 3, 3_723_000_004)))
              |> or_fail_with(
                "Expected the interval 1 year 2 mons 3 days 01:02:03.000004 to read as its Gleam value",
              )
            },
          ),
          // The addresses, bit strings and tuple ids.
          it("writes inet 192.168.0.1/32", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv4(192, 168, 0, 1), 32)
            |> should
            |> write_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_some()
            |> be_equal("192.168.0.1/32")
            |> or_fail_with("Expected the server text 192.168.0.1/32 of inet")
          }),
          it("reads inet 192.168.0.1/32", fn(sessions) {
            // Act and assert
            Some("192.168.0.1/32")
            |> should
            |> read_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv4(192, 168, 0, 1), 32))
            |> or_fail_with(
              "Expected the inet 192.168.0.1/32 to read as its Gleam value",
            )
          }),
          it("writes inet 10.1.2.3/8", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv4(10, 1, 2, 3), 8)
            |> should
            |> write_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_some()
            |> be_equal("10.1.2.3/8")
            |> or_fail_with("Expected the server text 10.1.2.3/8 of inet")
          }),
          it("reads inet 10.1.2.3/8", fn(sessions) {
            // Act and assert
            Some("10.1.2.3/8")
            |> should
            |> read_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv4(10, 1, 2, 3), 8))
            |> or_fail_with(
              "Expected the inet 10.1.2.3/8 to read as its Gleam value",
            )
          }),
          it("writes inet ::1/128", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv6(0, 0, 0, 0, 0, 0, 0, 1), 128)
            |> should
            |> write_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_some()
            |> be_equal("::1/128")
            |> or_fail_with("Expected the server text ::1/128 of inet")
          }),
          it("reads inet ::1/128", fn(sessions) {
            // Act and assert
            Some("::1/128")
            |> should
            |> read_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv6(0, 0, 0, 0, 0, 0, 0, 1), 128))
            |> or_fail_with(
              "Expected the inet ::1/128 to read as its Gleam value",
            )
          }),
          it("writes inet 2001:db8::1/64", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 64)
            |> should
            |> write_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_some()
            |> be_equal("2001:db8::1/64")
            |> or_fail_with("Expected the server text 2001:db8::1/64 of inet")
          }),
          it("reads inet 2001:db8::1/64", fn(sessions) {
            // Act and assert
            Some("2001:db8::1/64")
            |> should
            |> read_on_server(sessions, codec.ip_network, "inet")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 64))
            |> or_fail_with(
              "Expected the inet 2001:db8::1/64 to read as its Gleam value",
            )
          }),
          it("writes cidr 10.0.0.0/8", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv4(10, 0, 0, 0), 8)
            |> should
            |> write_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_some()
            |> be_equal("10.0.0.0/8")
            |> or_fail_with("Expected the server text 10.0.0.0/8 of cidr")
          }),
          it("reads cidr 10.0.0.0/8", fn(sessions) {
            // Act and assert
            Some("10.0.0.0/8")
            |> should
            |> read_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv4(10, 0, 0, 0), 8))
            |> or_fail_with(
              "Expected the cidr 10.0.0.0/8 to read as its Gleam value",
            )
          }),
          it("writes cidr 192.168.0.1/32", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv4(192, 168, 0, 1), 32)
            |> should
            |> write_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_some()
            |> be_equal("192.168.0.1/32")
            |> or_fail_with("Expected the server text 192.168.0.1/32 of cidr")
          }),
          it("reads cidr 192.168.0.1/32", fn(sessions) {
            // Act and assert
            Some("192.168.0.1/32")
            |> should
            |> read_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv4(192, 168, 0, 1), 32))
            |> or_fail_with(
              "Expected the cidr 192.168.0.1/32 to read as its Gleam value",
            )
          }),
          it("writes cidr 2001:db8::/32", fn(sessions) {
            // Act and assert
            IpNetwork(Ipv6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0), 32)
            |> should
            |> write_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_some()
            |> be_equal("2001:db8::/32")
            |> or_fail_with("Expected the server text 2001:db8::/32 of cidr")
          }),
          it("reads cidr 2001:db8::/32", fn(sessions) {
            // Act and assert
            Some("2001:db8::/32")
            |> should
            |> read_on_server(sessions, codec.ip_network, "cidr")
            |> be_ok()
            |> be_equal(IpNetwork(Ipv6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0), 32))
            |> or_fail_with(
              "Expected the cidr 2001:db8::/32 to read as its Gleam value",
            )
          }),
          it("writes macaddr 08:00:2b:01:02:03", fn(sessions) {
            // Act and assert
            network.parse_mac_address("08:00:2b:01:02:03")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.mac_address, "macaddr")
            |> be_ok()
            |> be_some()
            |> be_equal("08:00:2b:01:02:03")
            |> or_fail_with(
              "Expected the server text 08:00:2b:01:02:03 of macaddr",
            )
          }),
          it("reads macaddr 08:00:2b:01:02:03", fn(sessions) {
            // Act and assert
            Some("08:00:2b:01:02:03")
            |> should
            |> read_on_server(sessions, codec.mac_address, "macaddr")
            |> be_ok()
            |> have_mac_address_text()
            |> be_equal("08:00:2b:01:02:03")
            |> or_fail_with(
              "Expected the macaddr 08:00:2b:01:02:03 to read as its Gleam value",
            )
          }),
          it("writes macaddr8 08:00:2b:01:02:03:04:05", fn(sessions) {
            // Act and assert
            network.parse_mac_address("08:00:2b:01:02:03:04:05")
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.mac_address, "macaddr8")
            |> be_ok()
            |> be_some()
            |> be_equal("08:00:2b:01:02:03:04:05")
            |> or_fail_with(
              "Expected the server text 08:00:2b:01:02:03:04:05 of macaddr8",
            )
          }),
          it("reads macaddr8 08:00:2b:01:02:03:04:05", fn(sessions) {
            // Act and assert
            Some("08:00:2b:01:02:03:04:05")
            |> should
            |> read_on_server(sessions, codec.mac_address, "macaddr8")
            |> be_ok()
            |> have_mac_address_text()
            |> be_equal("08:00:2b:01:02:03:04:05")
            |> or_fail_with(
              "Expected the macaddr8 08:00:2b:01:02:03:04:05 to read as its Gleam value",
            )
          }),
          it("writes bit(8) 10101010", fn(sessions) {
            // Act and assert
            <<0b10101010>>
            |> should
            |> write_on_server(sessions, codec.bit_string, "bit(8)")
            |> be_ok()
            |> be_some()
            |> be_equal("10101010")
            |> or_fail_with("Expected the server text 10101010 of bit(8)")
          }),
          it("reads bit(8) 10101010", fn(sessions) {
            // Act and assert
            Some("10101010")
            |> should
            |> read_on_server(sessions, codec.bit_string, "bit(8)")
            |> be_ok()
            |> be_equal(<<0b10101010>>)
            |> or_fail_with(
              "Expected the bit(8) 10101010 to read as its Gleam value",
            )
          }),
          it("writes bit(3) 101", fn(sessions) {
            // Act and assert
            <<5:size(3)>>
            |> should
            |> write_on_server(sessions, codec.bit_string, "bit(3)")
            |> be_ok()
            |> be_some()
            |> be_equal("101")
            |> or_fail_with("Expected the server text 101 of bit(3)")
          }),
          it("reads bit(3) 101", fn(sessions) {
            // Act and assert
            Some("101")
            |> should
            |> read_on_server(sessions, codec.bit_string, "bit(3)")
            |> be_ok()
            |> be_equal(<<5:size(3)>>)
            |> or_fail_with(
              "Expected the bit(3) 101 to read as its Gleam value",
            )
          }),
          it("writes varbit 10000000000", fn(sessions) {
            // Act and assert
            <<1:size(1), 0:size(10)>>
            |> should
            |> write_on_server(sessions, codec.bit_string, "varbit")
            |> be_ok()
            |> be_some()
            |> be_equal("10000000000")
            |> or_fail_with("Expected the server text 10000000000 of varbit")
          }),
          it("reads varbit 10000000000", fn(sessions) {
            // Act and assert
            Some("10000000000")
            |> should
            |> read_on_server(sessions, codec.bit_string, "varbit")
            |> be_ok()
            |> be_equal(<<1:size(1), 0:size(10)>>)
            |> or_fail_with(
              "Expected the varbit 10000000000 to read as its Gleam value",
            )
          }),
          it("writes varbit ", fn(sessions) {
            // Act and assert
            <<>>
            |> should
            |> write_on_server(sessions, codec.bit_string, "varbit")
            |> be_ok()
            |> be_some()
            |> be_equal("")
            |> or_fail_with("Expected an empty server text of varbit")
          }),
          it("reads varbit ", fn(sessions) {
            // Act and assert
            Some("")
            |> should
            |> read_on_server(sessions, codec.bit_string, "varbit")
            |> be_ok()
            |> be_equal(<<>>)
            |> or_fail_with(
              "Expected an empty varbit to read as its Gleam value",
            )
          }),
          it("writes tid (0,1)", fn(sessions) {
            // Act and assert
            Tid(0, 1)
            |> should
            |> write_on_server(sessions, codec.tid, "tid")
            |> be_ok()
            |> be_some()
            |> be_equal("(0,1)")
            |> or_fail_with("Expected the server text (0,1) of tid")
          }),
          it("reads tid (0,1)", fn(sessions) {
            // Act and assert
            Some("(0,1)")
            |> should
            |> read_on_server(sessions, codec.tid, "tid")
            |> be_ok()
            |> be_equal(Tid(0, 1))
            |> or_fail_with("Expected the tid (0,1) to read as its Gleam value")
          }),
          it("writes tid (4294967295,65535)", fn(sessions) {
            // Act and assert
            Tid(4_294_967_295, 65_535)
            |> should
            |> write_on_server(sessions, codec.tid, "tid")
            |> be_ok()
            |> be_some()
            |> be_equal("(4294967295,65535)")
            |> or_fail_with(
              "Expected the server text (4294967295,65535) of tid",
            )
          }),
          it("reads tid (4294967295,65535)", fn(sessions) {
            // Act and assert
            Some("(4294967295,65535)")
            |> should
            |> read_on_server(sessions, codec.tid, "tid")
            |> be_ok()
            |> be_equal(Tid(4_294_967_295, 65_535))
            |> or_fail_with(
              "Expected the tid (4294967295,65535) to read as its Gleam value",
            )
          }),
          // The geometric types.
          it("writes point (1.5,-2)", fn(sessions) {
            // Act and assert
            Point(1.5, -2.0)
            |> should
            |> write_on_server(sessions, codec.point, "point")
            |> be_ok()
            |> be_some()
            |> be_equal("(1.5,-2)")
            |> or_fail_with("Expected the server text (1.5,-2) of point")
          }),
          it("reads point (1.5,-2)", fn(sessions) {
            // Act and assert
            Some("(1.5,-2)")
            |> should
            |> read_on_server(sessions, codec.point, "point")
            |> be_ok()
            |> be_equal(Point(1.5, -2.0))
            |> or_fail_with(
              "Expected the point (1.5,-2) to read as its Gleam value",
            )
          }),
          it("writes line {1,-1,0}", fn(sessions) {
            // Act and assert
            Line(1.0, -1.0, 0.0)
            |> should
            |> write_on_server(sessions, codec.line, "line")
            |> be_ok()
            |> be_some()
            |> be_equal("{1,-1,0}")
            |> or_fail_with("Expected the server text {1,-1,0} of line")
          }),
          it("reads line {1,-1,0}", fn(sessions) {
            // Act and assert
            Some("{1,-1,0}")
            |> should
            |> read_on_server(sessions, codec.line, "line")
            |> be_ok()
            |> be_equal(Line(1.0, -1.0, 0.0))
            |> or_fail_with(
              "Expected the line {1,-1,0} to read as its Gleam value",
            )
          }),
          it("writes lseg [(0,0),(1,1)]", fn(sessions) {
            // Act and assert
            LineSegment(Point(0.0, 0.0), Point(1.0, 1.0))
            |> should
            |> write_on_server(sessions, codec.line_segment, "lseg")
            |> be_ok()
            |> be_some()
            |> be_equal("[(0,0),(1,1)]")
            |> or_fail_with("Expected the server text [(0,0),(1,1)] of lseg")
          }),
          it("reads lseg [(0,0),(1,1)]", fn(sessions) {
            // Act and assert
            Some("[(0,0),(1,1)]")
            |> should
            |> read_on_server(sessions, codec.line_segment, "lseg")
            |> be_ok()
            |> be_equal(LineSegment(Point(0.0, 0.0), Point(1.0, 1.0)))
            |> or_fail_with(
              "Expected the lseg [(0,0),(1,1)] to read as its Gleam value",
            )
          }),
          it("writes box (2,3),(0,1)", fn(sessions) {
            // Act and assert
            Box(Point(2.0, 3.0), Point(0.0, 1.0))
            |> should
            |> write_on_server(sessions, codec.box, "box")
            |> be_ok()
            |> be_some()
            |> be_equal("(2,3),(0,1)")
            |> or_fail_with("Expected the server text (2,3),(0,1) of box")
          }),
          it("reads box (2,3),(0,1)", fn(sessions) {
            // Act and assert
            Some("(2,3),(0,1)")
            |> should
            |> read_on_server(sessions, codec.box, "box")
            |> be_ok()
            |> be_equal(Box(Point(2.0, 3.0), Point(0.0, 1.0)))
            |> or_fail_with(
              "Expected the box (2,3),(0,1) to read as its Gleam value",
            )
          }),
          it("writes box (2,3),(0,1)", fn(sessions) {
            // Act and assert
            Box(Point(0.0, 1.0), Point(2.0, 3.0))
            |> should
            |> write_on_server(sessions, codec.box, "box")
            |> be_ok()
            |> be_some()
            |> be_equal("(2,3),(0,1)")
            |> or_fail_with("Expected the server text (2,3),(0,1) of box")
          }),
          it("reads box (2,3),(0,1)", fn(sessions) {
            // Act and assert
            Some("(2,3),(0,1)")
            |> should
            |> read_on_server(sessions, codec.box, "box")
            |> be_ok()
            |> be_equal(Box(Point(2.0, 3.0), Point(0.0, 1.0)))
            |> or_fail_with(
              "Expected the box (2,3),(0,1) to read as its Gleam value",
            )
          }),
          it("writes path [(0,0),(1,1),(2,0)]", fn(sessions) {
            // Act and assert
            Path(True, [Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 0.0)])
            |> should
            |> write_on_server(sessions, codec.path, "path")
            |> be_ok()
            |> be_some()
            |> be_equal("[(0,0),(1,1),(2,0)]")
            |> or_fail_with(
              "Expected the server text [(0,0),(1,1),(2,0)] of path",
            )
          }),
          it("reads path [(0,0),(1,1),(2,0)]", fn(sessions) {
            // Act and assert
            Some("[(0,0),(1,1),(2,0)]")
            |> should
            |> read_on_server(sessions, codec.path, "path")
            |> be_ok()
            |> be_equal(
              Path(True, [Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 0.0)]),
            )
            |> or_fail_with(
              "Expected the path [(0,0),(1,1),(2,0)] to read as its Gleam value",
            )
          }),
          it("writes path ((0,0),(1,1),(2,0))", fn(sessions) {
            // Act and assert
            Path(False, [Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 0.0)])
            |> should
            |> write_on_server(sessions, codec.path, "path")
            |> be_ok()
            |> be_some()
            |> be_equal("((0,0),(1,1),(2,0))")
            |> or_fail_with(
              "Expected the server text ((0,0),(1,1),(2,0)) of path",
            )
          }),
          it("reads path ((0,0),(1,1),(2,0))", fn(sessions) {
            // Act and assert
            Some("((0,0),(1,1),(2,0))")
            |> should
            |> read_on_server(sessions, codec.path, "path")
            |> be_ok()
            |> be_equal(
              Path(False, [Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 0.0)]),
            )
            |> or_fail_with(
              "Expected the path ((0,0),(1,1),(2,0)) to read as its Gleam value",
            )
          }),
          it("writes polygon ((0,0),(1,1),(1,0))", fn(sessions) {
            // Act and assert
            Polygon([Point(0.0, 0.0), Point(1.0, 1.0), Point(1.0, 0.0)])
            |> should
            |> write_on_server(sessions, codec.polygon, "polygon")
            |> be_ok()
            |> be_some()
            |> be_equal("((0,0),(1,1),(1,0))")
            |> or_fail_with(
              "Expected the server text ((0,0),(1,1),(1,0)) of polygon",
            )
          }),
          it("reads polygon ((0,0),(1,1),(1,0))", fn(sessions) {
            // Act and assert
            Some("((0,0),(1,1),(1,0))")
            |> should
            |> read_on_server(sessions, codec.polygon, "polygon")
            |> be_ok()
            |> be_equal(
              Polygon([Point(0.0, 0.0), Point(1.0, 1.0), Point(1.0, 0.0)]),
            )
            |> or_fail_with(
              "Expected the polygon ((0,0),(1,1),(1,0)) to read as its Gleam value",
            )
          }),
          it("writes circle <(0.5,0),1.5>", fn(sessions) {
            // Act and assert
            Circle(Point(0.5, 0.0), 1.5)
            |> should
            |> write_on_server(sessions, codec.circle, "circle")
            |> be_ok()
            |> be_some()
            |> be_equal("<(0.5,0),1.5>")
            |> or_fail_with("Expected the server text <(0.5,0),1.5> of circle")
          }),
          it("reads circle <(0.5,0),1.5>", fn(sessions) {
            // Act and assert
            Some("<(0.5,0),1.5>")
            |> should
            |> read_on_server(sessions, codec.circle, "circle")
            |> be_ok()
            |> be_equal(Circle(Point(0.5, 0.0), 1.5))
            |> or_fail_with(
              "Expected the circle <(0.5,0),1.5> to read as its Gleam value",
            )
          }),
          // The ranges and multiranges.
          it("writes int4range [1,10)", fn(sessions) {
            // Act and assert
            range.Range(Inclusive(1), Exclusive(10))
            |> should
            |> write_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_some()
            |> be_equal("[1,10)")
            |> or_fail_with("Expected the server text [1,10) of int4range")
          }),
          it("reads int4range [1,10)", fn(sessions) {
            // Act and assert
            Some("[1,10)")
            |> should
            |> read_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_equal(range.Range(Inclusive(1), Exclusive(10)))
            |> or_fail_with(
              "Expected the int4range [1,10) to read as its Gleam value",
            )
          }),
          it("writes int4range [1,6)", fn(sessions) {
            // Act and assert
            range.Range(Exclusive(0), Inclusive(5))
            |> should
            |> write_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_some()
            |> be_equal("[1,6)")
            |> or_fail_with("Expected the server text [1,6) of int4range")
          }),
          it("reads int4range [1,6)", fn(sessions) {
            // Act and assert
            Some("[1,6)")
            |> should
            |> read_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_equal(range.Range(Inclusive(1), Exclusive(6)))
            |> or_fail_with(
              "Expected the int4range [1,6) to read as its Gleam value",
            )
          }),
          it("writes int4range (,5)", fn(sessions) {
            // Act and assert
            range.Range(Unbounded, Exclusive(5))
            |> should
            |> write_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_some()
            |> be_equal("(,5)")
            |> or_fail_with("Expected the server text (,5) of int4range")
          }),
          it("reads int4range (,5)", fn(sessions) {
            // Act and assert
            Some("(,5)")
            |> should
            |> read_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_equal(range.Range(Unbounded, Exclusive(5)))
            |> or_fail_with(
              "Expected the int4range (,5) to read as its Gleam value",
            )
          }),
          it("writes int8range [-3,)", fn(sessions) {
            // Act and assert
            range.Range(Inclusive(-3), Unbounded)
            |> should
            |> write_on_server(sessions, codec.range(codec.int), "int8range")
            |> be_ok()
            |> be_some()
            |> be_equal("[-3,)")
            |> or_fail_with("Expected the server text [-3,) of int8range")
          }),
          it("reads int8range [-3,)", fn(sessions) {
            // Act and assert
            Some("[-3,)")
            |> should
            |> read_on_server(sessions, codec.range(codec.int), "int8range")
            |> be_ok()
            |> be_equal(range.Range(Inclusive(-3), Unbounded))
            |> or_fail_with(
              "Expected the int8range [-3,) to read as its Gleam value",
            )
          }),
          it("writes int4range empty", fn(sessions) {
            // Act and assert
            EmptyRange
            |> should
            |> write_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_some()
            |> be_equal("empty")
            |> or_fail_with("Expected the server text empty of int4range")
          }),
          it("reads int4range empty", fn(sessions) {
            // Act and assert
            Some("empty")
            |> should
            |> read_on_server(sessions, codec.range(codec.int), "int4range")
            |> be_ok()
            |> be_equal(EmptyRange)
            |> or_fail_with(
              "Expected the int4range empty to read as its Gleam value",
            )
          }),
          it("writes numrange [1.5,2.50]", fn(sessions) {
            // Act and assert
            range.Range(Inclusive("1.5"), Inclusive("2.50"))
            |> should
            |> write_on_server(sessions, codec.range(codec.numeric), "numrange")
            |> be_ok()
            |> be_some()
            |> be_equal("[1.5,2.50]")
            |> or_fail_with("Expected the server text [1.5,2.50] of numrange")
          }),
          it("reads numrange [1.5,2.50]", fn(sessions) {
            // Act and assert
            Some("[1.5,2.50]")
            |> should
            |> read_on_server(sessions, codec.range(codec.numeric), "numrange")
            |> be_ok()
            |> be_equal(range.Range(Inclusive("1.5"), Inclusive("2.50")))
            |> or_fail_with(
              "Expected the numrange [1.5,2.50] to read as its Gleam value",
            )
          }),
          it(
            "writes tsrange [\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\")",
            fn(sessions) {
              // Act and assert
              range.Range(
                Inclusive(timestamp.from_calendar(
                  date: Date(2024, January, 1),
                  time: TimeOfDay(0, 0, 0, 0),
                  offset: duration.seconds(0),
                )),
                Exclusive(timestamp.from_calendar(
                  date: Date(2024, January, 2),
                  time: TimeOfDay(12, 0, 0, 0),
                  offset: duration.seconds(0),
                )),
              )
              |> should
              |> write_on_server(
                sessions,
                codec.range(codec.timestamp),
                "tsrange",
              )
              |> be_ok()
              |> be_some()
              |> be_equal("[\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\")")
              |> or_fail_with(
                "Expected the server text [\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\") of tsrange",
              )
            },
          ),
          it(
            "reads tsrange [\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\")",
            fn(sessions) {
              // Act and assert
              Some("[\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\")")
              |> should
              |> read_on_server(
                sessions,
                codec.range(codec.timestamp),
                "tsrange",
              )
              |> be_ok()
              |> be_equal(range.Range(
                Inclusive(timestamp.from_calendar(
                  date: Date(2024, January, 1),
                  time: TimeOfDay(0, 0, 0, 0),
                  offset: duration.seconds(0),
                )),
                Exclusive(timestamp.from_calendar(
                  date: Date(2024, January, 2),
                  time: TimeOfDay(12, 0, 0, 0),
                  offset: duration.seconds(0),
                )),
              ))
              |> or_fail_with(
                "Expected the tsrange [\"2024-01-01 00:00:00\",\"2024-01-02 12:00:00\") to read as its Gleam value",
              )
            },
          ),
          it("writes tstzrange [\"2024-01-01 00:00:00+00\",)", fn(sessions) {
            // Act and assert
            range.Range(
              Inclusive(timestamp.from_calendar(
                date: Date(2024, January, 1),
                time: TimeOfDay(0, 0, 0, 0),
                offset: duration.seconds(0),
              )),
              Unbounded,
            )
            |> should
            |> write_on_server(
              sessions,
              codec.range(codec.timestamp_with_time_zone),
              "tstzrange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("[\"2024-01-01 00:00:00+00\",)")
            |> or_fail_with(
              "Expected the server text [\"2024-01-01 00:00:00+00\",) of tstzrange",
            )
          }),
          it("reads tstzrange [\"2024-01-01 00:00:00+00\",)", fn(sessions) {
            // Act and assert
            Some("[\"2024-01-01 00:00:00+00\",)")
            |> should
            |> read_on_server(
              sessions,
              codec.range(codec.timestamp_with_time_zone),
              "tstzrange",
            )
            |> be_ok()
            |> be_equal(range.Range(
              Inclusive(timestamp.from_calendar(
                date: Date(2024, January, 1),
                time: TimeOfDay(0, 0, 0, 0),
                offset: duration.seconds(0),
              )),
              Unbounded,
            ))
            |> or_fail_with(
              "Expected the tstzrange [\"2024-01-01 00:00:00+00\",) to read as its Gleam value",
            )
          }),
          it("writes daterange [2024-01-01,2024-02-01)", fn(sessions) {
            // Act and assert
            range.Range(
              Inclusive(Date(2024, January, 1)),
              Exclusive(Date(2024, February, 1)),
            )
            |> should
            |> write_on_server(sessions, codec.range(codec.date), "daterange")
            |> be_ok()
            |> be_some()
            |> be_equal("[2024-01-01,2024-02-01)")
            |> or_fail_with(
              "Expected the server text [2024-01-01,2024-02-01) of daterange",
            )
          }),
          it("reads daterange [2024-01-01,2024-02-01)", fn(sessions) {
            // Act and assert
            Some("[2024-01-01,2024-02-01)")
            |> should
            |> read_on_server(sessions, codec.range(codec.date), "daterange")
            |> be_ok()
            |> be_equal(range.Range(
              Inclusive(Date(2024, January, 1)),
              Exclusive(Date(2024, February, 1)),
            ))
            |> or_fail_with(
              "Expected the daterange [2024-01-01,2024-02-01) to read as its Gleam value",
            )
          }),
          it("writes int4multirange {[1,3),[5,7)}", fn(sessions) {
            // Act and assert
            [
              range.Range(Inclusive(1), Exclusive(3)),
              range.Range(Inclusive(5), Exclusive(7)),
            ]
            |> should
            |> write_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{[1,3),[5,7)}")
            |> or_fail_with(
              "Expected the server text {[1,3),[5,7)} of int4multirange",
            )
          }),
          it("reads int4multirange {[1,3),[5,7)}", fn(sessions) {
            // Act and assert
            Some("{[1,3),[5,7)}")
            |> should
            |> read_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_equal([
              range.Range(Inclusive(1), Exclusive(3)),
              range.Range(Inclusive(5), Exclusive(7)),
            ])
            |> or_fail_with(
              "Expected the int4multirange {[1,3),[5,7)} to read as its Gleam value",
            )
          }),
          it("writes int4multirange {[1,7)}", fn(sessions) {
            // Act and assert
            [
              range.Range(Inclusive(5), Exclusive(7)),
              range.Range(Inclusive(1), Exclusive(5)),
            ]
            |> should
            |> write_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{[1,7)}")
            |> or_fail_with(
              "Expected the server text {[1,7)} of int4multirange",
            )
          }),
          it("reads int4multirange {[1,7)}", fn(sessions) {
            // Act and assert
            Some("{[1,7)}")
            |> should
            |> read_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_equal([range.Range(Inclusive(1), Exclusive(7))])
            |> or_fail_with(
              "Expected the int4multirange {[1,7)} to read as its Gleam value",
            )
          }),
          it("writes int4multirange {}", fn(sessions) {
            // Act and assert
            []
            |> should
            |> write_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{}")
            |> or_fail_with("Expected the server text {} of int4multirange")
          }),
          it("reads int4multirange {}", fn(sessions) {
            // Act and assert
            Some("{}")
            |> should
            |> read_on_server(
              sessions,
              codec.multirange(codec.int),
              "int4multirange",
            )
            |> be_ok()
            |> be_equal([])
            |> or_fail_with(
              "Expected the int4multirange {} to read as its Gleam value",
            )
          }),
          it("writes datemultirange {[2024-01-01,2024-01-05)}", fn(sessions) {
            // Act and assert
            [
              range.Range(
                Inclusive(Date(2024, January, 1)),
                Exclusive(Date(2024, January, 5)),
              ),
            ]
            |> should
            |> write_on_server(
              sessions,
              codec.multirange(codec.date),
              "datemultirange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{[2024-01-01,2024-01-05)}")
            |> or_fail_with(
              "Expected the server text {[2024-01-01,2024-01-05)} of datemultirange",
            )
          }),
          it("reads datemultirange {[2024-01-01,2024-01-05)}", fn(sessions) {
            // Act and assert
            Some("{[2024-01-01,2024-01-05)}")
            |> should
            |> read_on_server(
              sessions,
              codec.multirange(codec.date),
              "datemultirange",
            )
            |> be_ok()
            |> be_equal([
              range.Range(
                Inclusive(Date(2024, January, 1)),
                Exclusive(Date(2024, January, 5)),
              ),
            ])
            |> or_fail_with(
              "Expected the datemultirange {[2024-01-01,2024-01-05)} to read as its Gleam value",
            )
          }),
          // The text search types and the vectors.
          it("writes tsvector 'a':1A 'cat' 'fat':2,3", fn(sessions) {
            // Act and assert
            [
              Lexeme("a", [#(1, WeightA)]),
              Lexeme("cat", []),
              Lexeme("fat", [#(2, WeightD), #(3, WeightD)]),
            ]
            |> should
            |> write_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_some()
            |> be_equal("'a':1A 'cat' 'fat':2,3")
            |> or_fail_with(
              "Expected the server text 'a':1A 'cat' 'fat':2,3 of tsvector",
            )
          }),
          it("reads tsvector 'a':1A 'cat' 'fat':2,3", fn(sessions) {
            // Act and assert
            Some("'a':1A 'cat' 'fat':2,3")
            |> should
            |> read_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_equal([
              Lexeme("a", [#(1, WeightA)]),
              Lexeme("cat", []),
              Lexeme("fat", [#(2, WeightD), #(3, WeightD)]),
            ])
            |> or_fail_with(
              "Expected the tsvector 'a':1A 'cat' 'fat':2,3 to read as its Gleam value",
            )
          }),
          it("writes tsvector 'it''s':16383B", fn(sessions) {
            // Act and assert
            [Lexeme("it's", [#(16_383, WeightB)])]
            |> should
            |> write_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_some()
            |> be_equal("'it''s':16383B")
            |> or_fail_with(
              "Expected the server text 'it''s':16383B of tsvector",
            )
          }),
          it("reads tsvector 'it''s':16383B", fn(sessions) {
            // Act and assert
            Some("'it''s':16383B")
            |> should
            |> read_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_equal([Lexeme("it's", [#(16_383, WeightB)])])
            |> or_fail_with(
              "Expected the tsvector 'it''s':16383B to read as its Gleam value",
            )
          }),
          it("writes tsvector ", fn(sessions) {
            // Act and assert
            []
            |> should
            |> write_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_some()
            |> be_equal("")
            |> or_fail_with("Expected an empty server text of tsvector")
          }),
          it("reads tsvector ", fn(sessions) {
            // Act and assert
            Some("")
            |> should
            |> read_on_server(sessions, codec.text_search_vector, "tsvector")
            |> be_ok()
            |> be_equal([])
            |> or_fail_with(
              "Expected an empty tsvector to read as its Gleam value",
            )
          }),
          it("writes tsquery 'fat' & ( 'rat' | 'cat' )", fn(sessions) {
            // Act and assert
            And(
              Term("fat", [], False),
              Or(Term("rat", [], False), Term("cat", [], False)),
            )
            |> should
            |> write_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_some()
            |> be_equal("'fat' & ( 'rat' | 'cat' )")
            |> or_fail_with(
              "Expected the server text 'fat' & ( 'rat' | 'cat' ) of tsquery",
            )
          }),
          it("reads tsquery 'fat' & ( 'rat' | 'cat' )", fn(sessions) {
            // Act and assert
            Some("'fat' & ( 'rat' | 'cat' )")
            |> should
            |> read_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_equal(And(
              Term("fat", [], False),
              Or(Term("rat", [], False), Term("cat", [], False)),
            ))
            |> or_fail_with(
              "Expected the tsquery 'fat' & ( 'rat' | 'cat' ) to read as its Gleam value",
            )
          }),
          it("writes tsquery 'sup':*AB", fn(sessions) {
            // Act and assert
            Term("sup", [WeightA, WeightB], True)
            |> should
            |> write_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_some()
            |> be_equal("'sup':*AB")
            |> or_fail_with("Expected the server text 'sup':*AB of tsquery")
          }),
          it("reads tsquery 'sup':*AB", fn(sessions) {
            // Act and assert
            Some("'sup':*AB")
            |> should
            |> read_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_equal(Term("sup", [WeightA, WeightB], True))
            |> or_fail_with(
              "Expected the tsquery 'sup':*AB to read as its Gleam value",
            )
          }),
          it("writes tsquery !'a'", fn(sessions) {
            // Act and assert
            Not(Term("a", [], False))
            |> should
            |> write_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_some()
            |> be_equal("!'a'")
            |> or_fail_with("Expected the server text !'a' of tsquery")
          }),
          it("reads tsquery !'a'", fn(sessions) {
            // Act and assert
            Some("!'a'")
            |> should
            |> read_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_equal(Not(Term("a", [], False)))
            |> or_fail_with(
              "Expected the tsquery !'a' to read as its Gleam value",
            )
          }),
          it("writes tsquery 'a' <-> 'b'", fn(sessions) {
            // Act and assert
            Phrase(1, Term("a", [], False), Term("b", [], False))
            |> should
            |> write_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_some()
            |> be_equal("'a' <-> 'b'")
            |> or_fail_with("Expected the server text 'a' <-> 'b' of tsquery")
          }),
          it("reads tsquery 'a' <-> 'b'", fn(sessions) {
            // Act and assert
            Some("'a' <-> 'b'")
            |> should
            |> read_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_equal(Phrase(1, Term("a", [], False), Term("b", [], False)))
            |> or_fail_with(
              "Expected the tsquery 'a' <-> 'b' to read as its Gleam value",
            )
          }),
          it("writes tsquery 'a' <3> 'b'", fn(sessions) {
            // Act and assert
            Phrase(3, Term("a", [], False), Term("b", [], False))
            |> should
            |> write_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_some()
            |> be_equal("'a' <3> 'b'")
            |> or_fail_with("Expected the server text 'a' <3> 'b' of tsquery")
          }),
          it("reads tsquery 'a' <3> 'b'", fn(sessions) {
            // Act and assert
            Some("'a' <3> 'b'")
            |> should
            |> read_on_server(sessions, codec.text_search_query, "tsquery")
            |> be_ok()
            |> be_equal(Phrase(3, Term("a", [], False), Term("b", [], False)))
            |> or_fail_with(
              "Expected the tsquery 'a' <3> 'b' to read as its Gleam value",
            )
          }),
          it("writes vector [1,2.5,-3]", fn(sessions) {
            // Act and assert
            vector.list_to_vector([1.0, 2.5, -3.0])
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.vector, "vector")
            |> be_ok()
            |> be_some()
            |> be_equal("[1,2.5,-3]")
            |> or_fail_with("Expected the server text [1,2.5,-3] of vector")
          }),
          it("reads vector [1,2.5,-3]", fn(sessions) {
            // Act and assert
            Some("[1,2.5,-3]")
            |> should
            |> read_on_server(sessions, codec.vector, "vector")
            |> be_ok()
            |> have_vector_floats()
            |> be_equal([1.0, 2.5, -3.0])
            |> or_fail_with(
              "Expected the vector [1,2.5,-3] to read as its Gleam value",
            )
          }),
          it("writes vector [0.1]", fn(sessions) {
            // Act and assert
            vector.list_to_vector([0.1])
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.vector, "vector")
            |> be_ok()
            |> be_some()
            |> be_equal("[0.1]")
            |> or_fail_with("Expected the server text [0.1] of vector")
          }),
          it("reads vector [0.1]", fn(sessions) {
            // Act and assert
            Some("[0.1]")
            |> should
            |> read_on_server(sessions, codec.vector, "vector")
            |> be_ok()
            |> have_vector_floats()
            |> be_equal([0.10000000149011612])
            |> or_fail_with(
              "Expected the vector [0.1] to read as its Gleam value",
            )
          }),
          it("writes halfvec [1,2.5,-3]", fn(sessions) {
            // Act and assert
            vector.list_to_half_vector([1.0, 2.5, -3.0])
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.half_vector, "halfvec")
            |> be_ok()
            |> be_some()
            |> be_equal("[1,2.5,-3]")
            |> or_fail_with("Expected the server text [1,2.5,-3] of halfvec")
          }),
          it("reads halfvec [1,2.5,-3]", fn(sessions) {
            // Act and assert
            Some("[1,2.5,-3]")
            |> should
            |> read_on_server(sessions, codec.half_vector, "halfvec")
            |> be_ok()
            |> have_half_vector_floats()
            |> be_equal([1.0, 2.5, -3.0])
            |> or_fail_with(
              "Expected the halfvec [1,2.5,-3] to read as its Gleam value",
            )
          }),
          it("writes halfvec [65504]", fn(sessions) {
            // Act and assert
            vector.list_to_half_vector([65_504.0])
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.half_vector, "halfvec")
            |> be_ok()
            |> be_some()
            |> be_equal("[65504]")
            |> or_fail_with("Expected the server text [65504] of halfvec")
          }),
          it("reads halfvec [65504]", fn(sessions) {
            // Act and assert
            Some("[65504]")
            |> should
            |> read_on_server(sessions, codec.half_vector, "halfvec")
            |> be_ok()
            |> have_half_vector_floats()
            |> be_equal([65_504.0])
            |> or_fail_with(
              "Expected the halfvec [65504] to read as its Gleam value",
            )
          }),
          it("writes sparsevec {1:1.5,3:-2}/5", fn(sessions) {
            // Act and assert
            vector.dict_to_sparse_vector(
              5,
              dict.from_list([#(0, 1.5), #(2, -2.0)]),
            )
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.sparse_vector, "sparsevec")
            |> be_ok()
            |> be_some()
            |> be_equal("{1:1.5,3:-2}/5")
            |> or_fail_with(
              "Expected the server text {1:1.5,3:-2}/5 of sparsevec",
            )
          }),
          it("reads sparsevec {1:1.5,3:-2}/5", fn(sessions) {
            // Act and assert
            Some("{1:1.5,3:-2}/5")
            |> should
            |> read_on_server(sessions, codec.sparse_vector, "sparsevec")
            |> be_ok()
            |> have_sparse_vector_parts()
            |> be_equal(#(5, dict.from_list([#(0, 1.5), #(2, -2.0)])))
            |> or_fail_with(
              "Expected the sparsevec {1:1.5,3:-2}/5 to read as its Gleam value",
            )
          }),
          it("writes sparsevec {}/3", fn(sessions) {
            // Act and assert
            vector.dict_to_sparse_vector(3, dict.from_list([]))
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.sparse_vector, "sparsevec")
            |> be_ok()
            |> be_some()
            |> be_equal("{}/3")
            |> or_fail_with("Expected the server text {}/3 of sparsevec")
          }),
          it("reads sparsevec {}/3", fn(sessions) {
            // Act and assert
            Some("{}/3")
            |> should
            |> read_on_server(sessions, codec.sparse_vector, "sparsevec")
            |> be_ok()
            |> have_sparse_vector_parts()
            |> be_equal(#(3, dict.from_list([])))
            |> or_fail_with(
              "Expected the sparsevec {}/3 to read as its Gleam value",
            )
          }),
          // The enum, composite and domain of the session.
          it("writes pg_temp.probe_mood happy", fn(sessions) {
            // Act and assert
            Happy
            |> should
            |> write_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_mood",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("happy")
            |> or_fail_with(
              "Expected the server text happy of pg_temp.probe_mood",
            )
          }),
          it("reads pg_temp.probe_mood happy", fn(sessions) {
            // Act and assert
            Some("happy")
            |> should
            |> read_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_mood",
            )
            |> be_ok()
            |> be_equal(Happy)
            |> or_fail_with(
              "Expected the pg_temp.probe_mood happy to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_mood ok", fn(sessions) {
            // Act and assert
            Okay
            |> should
            |> write_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_mood",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("ok")
            |> or_fail_with("Expected the server text ok of pg_temp.probe_mood")
          }),
          it("reads pg_temp.probe_mood ok", fn(sessions) {
            // Act and assert
            Some("ok")
            |> should
            |> read_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_mood",
            )
            |> be_ok()
            |> be_equal(Okay)
            |> or_fail_with(
              "Expected the pg_temp.probe_mood ok to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_address (\"Main St\",12,)", fn(sessions) {
            // Act and assert
            Address("Main St", 12, None)
            |> should
            |> write_on_server(
              sessions,
              probe_types.address_codec(),
              "pg_temp.probe_address",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("(\"Main St\",12,)")
            |> or_fail_with(
              "Expected the server text (\"Main St\",12,) of pg_temp.probe_address",
            )
          }),
          it("reads pg_temp.probe_address (\"Main St\",12,)", fn(sessions) {
            // Act and assert
            Some("(\"Main St\",12,)")
            |> should
            |> read_on_server(
              sessions,
              probe_types.address_codec(),
              "pg_temp.probe_address",
            )
            |> be_ok()
            |> be_equal(Address("Main St", 12, None))
            |> or_fail_with(
              "Expected the pg_temp.probe_address (\"Main St\",12,) to read as its Gleam value",
            )
          }),
          it(
            "writes pg_temp.probe_address (\"a\"\"b,c\",-1,\"\")",
            fn(sessions) {
              // Act and assert
              Address("a\"b,c", -1, Some(""))
              |> should
              |> write_on_server(
                sessions,
                probe_types.address_codec(),
                "pg_temp.probe_address",
              )
              |> be_ok()
              |> be_some()
              |> be_equal("(\"a\"\"b,c\",-1,\"\")")
              |> or_fail_with(
                "Expected the server text (\"a\"\"b,c\",-1,\"\") of pg_temp.probe_address",
              )
            },
          ),
          it("reads pg_temp.probe_address (\"a\"\"b,c\",-1,\"\")", fn(sessions) {
            // Act and assert
            Some("(\"a\"\"b,c\",-1,\"\")")
            |> should
            |> read_on_server(
              sessions,
              probe_types.address_codec(),
              "pg_temp.probe_address",
            )
            |> be_ok()
            |> be_equal(Address("a\"b,c", -1, Some("")))
            |> or_fail_with(
              "Expected the pg_temp.probe_address (\"a\"\"b,c\",-1,\"\") to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_positive 7", fn(sessions) {
            // Act and assert
            7
            |> should
            |> write_on_server(sessions, codec.int, "pg_temp.probe_positive")
            |> be_ok()
            |> be_some()
            |> be_equal("7")
            |> or_fail_with(
              "Expected the server text 7 of pg_temp.probe_positive",
            )
          }),
          it("reads pg_temp.probe_positive 7", fn(sessions) {
            // Act and assert
            Some("7")
            |> should
            |> read_on_server(sessions, codec.int, "pg_temp.probe_positive")
            |> be_ok()
            |> be_equal(7)
            |> or_fail_with(
              "Expected the pg_temp.probe_positive 7 to read as its Gleam value",
            )
          }),
          // The arrays.
          it("writes int4[] {1,NULL,3}", fn(sessions) {
            // Act and assert
            [Some(1), None, Some(3)]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.nullable(codec.int)),
              "int4[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{1,NULL,3}")
            |> or_fail_with("Expected the server text {1,NULL,3} of int4[]")
          }),
          it("reads int4[] {1,NULL,3}", fn(sessions) {
            // Act and assert
            Some("{1,NULL,3}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.nullable(codec.int)),
              "int4[]",
            )
            |> be_ok()
            |> be_equal([Some(1), None, Some(3)])
            |> or_fail_with(
              "Expected the int4[] {1,NULL,3} to read as its Gleam value",
            )
          }),
          it("writes int8[] {}", fn(sessions) {
            // Act and assert
            []
            |> should
            |> write_on_server(sessions, codec.array(codec.int), "int8[]")
            |> be_ok()
            |> be_some()
            |> be_equal("{}")
            |> or_fail_with("Expected the server text {} of int8[]")
          }),
          it("reads int8[] {}", fn(sessions) {
            // Act and assert
            Some("{}")
            |> should
            |> read_on_server(sessions, codec.array(codec.int), "int8[]")
            |> be_ok()
            |> be_equal([])
            |> or_fail_with("Expected the int8[] {} to read as its Gleam value")
          }),
          it(
            "writes text[] {\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"}",
            fn(sessions) {
              // Act and assert
              ["a b", "c\"d", "", "NULL", "e\\f"]
              |> should
              |> write_on_server(sessions, codec.array(codec.text), "text[]")
              |> be_ok()
              |> be_some()
              |> be_equal("{\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"}")
              |> or_fail_with(
                "Expected the server text {\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"} of text[]",
              )
            },
          ),
          it(
            "reads text[] {\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"}",
            fn(sessions) {
              // Act and assert
              Some("{\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"}")
              |> should
              |> read_on_server(sessions, codec.array(codec.text), "text[]")
              |> be_ok()
              |> be_equal(["a b", "c\"d", "", "NULL", "e\\f"])
              |> or_fail_with(
                "Expected the text[] {\"a b\",\"c\\\"d\",\"\",\"NULL\",\"e\\\\f\"} to read as its Gleam value",
              )
            },
          ),
          it("writes numeric[] {1.50,NULL,NaN}", fn(sessions) {
            // Act and assert
            [Some("1.50"), None, Some("NaN")]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.nullable(codec.numeric)),
              "numeric[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{1.50,NULL,NaN}")
            |> or_fail_with(
              "Expected the server text {1.50,NULL,NaN} of numeric[]",
            )
          }),
          it("reads numeric[] {1.50,NULL,NaN}", fn(sessions) {
            // Act and assert
            Some("{1.50,NULL,NaN}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.nullable(codec.numeric)),
              "numeric[]",
            )
            |> be_ok()
            |> be_equal([Some("1.50"), None, Some("NaN")])
            |> or_fail_with(
              "Expected the numeric[] {1.50,NULL,NaN} to read as its Gleam value",
            )
          }),
          it("writes date[] {2024-01-01,2024-02-29}", fn(sessions) {
            // Act and assert
            [Date(2024, January, 1), Date(2024, February, 29)]
            |> should
            |> write_on_server(sessions, codec.array(codec.date), "date[]")
            |> be_ok()
            |> be_some()
            |> be_equal("{2024-01-01,2024-02-29}")
            |> or_fail_with(
              "Expected the server text {2024-01-01,2024-02-29} of date[]",
            )
          }),
          it("reads date[] {2024-01-01,2024-02-29}", fn(sessions) {
            // Act and assert
            Some("{2024-01-01,2024-02-29}")
            |> should
            |> read_on_server(sessions, codec.array(codec.date), "date[]")
            |> be_ok()
            |> be_equal([Date(2024, January, 1), Date(2024, February, 29)])
            |> or_fail_with(
              "Expected the date[] {2024-01-01,2024-02-29} to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_mood[] {sad,happy}", fn(sessions) {
            // Act and assert
            [Sad, Happy]
            |> should
            |> write_on_server(
              sessions,
              codec.array(probe_types.mood_codec()),
              "pg_temp.probe_mood[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{sad,happy}")
            |> or_fail_with(
              "Expected the server text {sad,happy} of pg_temp.probe_mood[]",
            )
          }),
          it("reads pg_temp.probe_mood[] {sad,happy}", fn(sessions) {
            // Act and assert
            Some("{sad,happy}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(probe_types.mood_codec()),
              "pg_temp.probe_mood[]",
            )
            |> be_ok()
            |> be_equal([Sad, Happy])
            |> or_fail_with(
              "Expected the pg_temp.probe_mood[] {sad,happy} to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_address[] {\"(x,1,y)\"}", fn(sessions) {
            // Act and assert
            [Address("x", 1, Some("y"))]
            |> should
            |> write_on_server(
              sessions,
              codec.array(probe_types.address_codec()),
              "pg_temp.probe_address[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{\"(x,1,y)\"}")
            |> or_fail_with(
              "Expected the server text {\"(x,1,y)\"} of pg_temp.probe_address[]",
            )
          }),
          it("reads pg_temp.probe_address[] {\"(x,1,y)\"}", fn(sessions) {
            // Act and assert
            Some("{\"(x,1,y)\"}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(probe_types.address_codec()),
              "pg_temp.probe_address[]",
            )
            |> be_ok()
            |> be_equal([Address("x", 1, Some("y"))])
            |> or_fail_with(
              "Expected the pg_temp.probe_address[] {\"(x,1,y)\"} to read as its Gleam value",
            )
          }),
          it("writes int4range[] {\"[1,2)\",empty}", fn(sessions) {
            // Act and assert
            [range.Range(Inclusive(1), Exclusive(2)), EmptyRange]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.range(codec.int)),
              "int4range[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{\"[1,2)\",empty}")
            |> or_fail_with(
              "Expected the server text {\"[1,2)\",empty} of int4range[]",
            )
          }),
          it("reads int4range[] {\"[1,2)\",empty}", fn(sessions) {
            // Act and assert
            Some("{\"[1,2)\",empty}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.range(codec.int)),
              "int4range[]",
            )
            |> be_ok()
            |> be_equal([range.Range(Inclusive(1), Exclusive(2)), EmptyRange])
            |> or_fail_with(
              "Expected the int4range[] {\"[1,2)\",empty} to read as its Gleam value",
            )
          }),
          it("writes ltree[] {a.b,NULL,c}", fn(sessions) {
            // Act and assert
            [Some("a.b"), None, Some("c")]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.nullable(probe_types.text_form_codec("ltree"))),
              "ltree[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{a.b,NULL,c}")
            |> or_fail_with("Expected the server text {a.b,NULL,c} of ltree[]")
          }),
          it("reads ltree[] {a.b,NULL,c}", fn(sessions) {
            // Act and assert
            Some("{a.b,NULL,c}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.nullable(probe_types.text_form_codec("ltree"))),
              "ltree[]",
            )
            |> be_ok()
            |> be_equal([Some("a.b"), None, Some("c")])
            |> or_fail_with(
              "Expected the ltree[] {a.b,NULL,c} to read as its Gleam value",
            )
          }),
          it("writes ltree[] {}", fn(sessions) {
            // Act and assert
            []
            |> should
            |> write_on_server(
              sessions,
              codec.array(probe_types.text_form_codec("ltree")),
              "ltree[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{}")
            |> or_fail_with("Expected the server text {} of ltree[]")
          }),
          it("reads ltree[] {}", fn(sessions) {
            // Act and assert
            Some("{}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(probe_types.text_form_codec("ltree")),
              "ltree[]",
            )
            |> be_ok()
            |> be_equal([])
            |> or_fail_with(
              "Expected the ltree[] {} to read as its Gleam value",
            )
          }),
          // The value cases of the pgo fork that the probes above do not hold.
          it("writes lquery top.*", fn(sessions) {
            // Act and assert
            "top.*"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("lquery"),
              "lquery",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("top.*")
            |> or_fail_with("Expected the server text top.* of lquery")
          }),
          it("reads lquery top.*", fn(sessions) {
            // Act and assert
            Some("top.*")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("lquery"),
              "lquery",
            )
            |> be_ok()
            |> be_equal("top.*")
            |> or_fail_with(
              "Expected the lquery top.* to read as its Gleam value",
            )
          }),
          it("writes ltxtquery top & sci", fn(sessions) {
            // Act and assert
            "top & sci"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("ltxtquery"),
              "ltxtquery",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("top & sci")
            |> or_fail_with("Expected the server text top & sci of ltxtquery")
          }),
          it("reads ltxtquery top & sci", fn(sessions) {
            // Act and assert
            Some("top & sci")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("ltxtquery"),
              "ltxtquery",
            )
            |> be_ok()
            |> be_equal("top & sci")
            |> or_fail_with(
              "Expected the ltxtquery top & sci to read as its Gleam value",
            )
          }),
          it("writes aclitem dream=r/dream", fn(sessions) {
            // Act and assert
            "dream=r/dream"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("aclitem"),
              "aclitem",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("dream=r/dream")
            |> or_fail_with("Expected the server text dream=r/dream of aclitem")
          }),
          it("reads aclitem dream=r/dream", fn(sessions) {
            // Act and assert
            Some("dream=r/dream")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("aclitem"),
              "aclitem",
            )
            |> be_ok()
            |> be_equal("dream=r/dream")
            |> or_fail_with(
              "Expected the aclitem dream=r/dream to read as its Gleam value",
            )
          }),
          it("writes aclitem[] {dream=r/dream}", fn(sessions) {
            // Act and assert
            ["dream=r/dream"]
            |> should
            |> write_on_server(
              sessions,
              codec.array(probe_types.text_form_codec("aclitem")),
              "aclitem[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{dream=r/dream}")
            |> or_fail_with(
              "Expected the server text {dream=r/dream} of aclitem[]",
            )
          }),
          it("reads aclitem[] {dream=r/dream}", fn(sessions) {
            // Act and assert
            Some("{dream=r/dream}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(probe_types.text_form_codec("aclitem")),
              "aclitem[]",
            )
            |> be_ok()
            |> be_equal(["dream=r/dream"])
            |> or_fail_with(
              "Expected the aclitem[] {dream=r/dream} to read as its Gleam value",
            )
          }),
          it("writes money $12.50", fn(sessions) {
            // Act and assert
            "$12.50"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("money"),
              "money",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("$12.50")
            |> or_fail_with("Expected the server text $12.50 of money")
          }),
          it("reads money $12.50", fn(sessions) {
            // Act and assert
            Some("$12.50")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("money"),
              "money",
            )
            |> be_ok()
            |> be_equal("$12.50")
            |> or_fail_with(
              "Expected the money $12.50 to read as its Gleam value",
            )
          }),
          it("writes xml <a>b</a>", fn(sessions) {
            // Act and assert
            "<a>b</a>"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("xml"),
              "xml",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("<a>b</a>")
            |> or_fail_with("Expected the server text <a>b</a> of xml")
          }),
          it("reads xml <a>b</a>", fn(sessions) {
            // Act and assert
            Some("<a>b</a>")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("xml"),
              "xml",
            )
            |> be_ok()
            |> be_equal("<a>b</a>")
            |> or_fail_with(
              "Expected the xml <a>b</a> to read as its Gleam value",
            )
          }),
          it("writes jsonpath $.\"a\"", fn(sessions) {
            // Act and assert
            "$.a"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("jsonpath"),
              "jsonpath",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("$.\"a\"")
            |> or_fail_with("Expected the server text $.\"a\" of jsonpath")
          }),
          it("reads jsonpath $.\"a\"", fn(sessions) {
            // Act and assert
            Some("$.\"a\"")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("jsonpath"),
              "jsonpath",
            )
            |> be_ok()
            |> be_equal("$.\"a\"")
            |> or_fail_with(
              "Expected the jsonpath $.\"a\" to read as its Gleam value",
            )
          }),
          it("writes pg_lsn 16/B374D848", fn(sessions) {
            // Act and assert
            "16/B374D848"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("pg_lsn"),
              "pg_lsn",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("16/B374D848")
            |> or_fail_with("Expected the server text 16/B374D848 of pg_lsn")
          }),
          it("reads pg_lsn 16/B374D848", fn(sessions) {
            // Act and assert
            Some("16/B374D848")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("pg_lsn"),
              "pg_lsn",
            )
            |> be_ok()
            |> be_equal("16/B374D848")
            |> or_fail_with(
              "Expected the pg_lsn 16/B374D848 to read as its Gleam value",
            )
          }),
          it("writes xid 42", fn(sessions) {
            // Act and assert
            "42"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("xid"),
              "xid",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("42")
            |> or_fail_with("Expected the server text 42 of xid")
          }),
          it("reads xid 42", fn(sessions) {
            // Act and assert
            Some("42")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("xid"),
              "xid",
            )
            |> be_ok()
            |> be_equal("42")
            |> or_fail_with("Expected the xid 42 to read as its Gleam value")
          }),
          it("writes cid 7", fn(sessions) {
            // Act and assert
            "7"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("cid"),
              "cid",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("7")
            |> or_fail_with("Expected the server text 7 of cid")
          }),
          it("reads cid 7", fn(sessions) {
            // Act and assert
            Some("7")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("cid"),
              "cid",
            )
            |> be_ok()
            |> be_equal("7")
            |> or_fail_with("Expected the cid 7 to read as its Gleam value")
          }),
          it("writes xid8 42", fn(sessions) {
            // Act and assert
            "42"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("xid8"),
              "xid8",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("42")
            |> or_fail_with("Expected the server text 42 of xid8")
          }),
          it("reads xid8 42", fn(sessions) {
            // Act and assert
            Some("42")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("xid8"),
              "xid8",
            )
            |> be_ok()
            |> be_equal("42")
            |> or_fail_with("Expected the xid8 42 to read as its Gleam value")
          }),
          it("writes pg_snapshot 10:20:10,14,15", fn(sessions) {
            // Act and assert
            "10:20:10,14,15"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("pg_snapshot"),
              "pg_snapshot",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("10:20:10,14,15")
            |> or_fail_with(
              "Expected the server text 10:20:10,14,15 of pg_snapshot",
            )
          }),
          it("reads pg_snapshot 10:20:10,14,15", fn(sessions) {
            // Act and assert
            Some("10:20:10,14,15")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("pg_snapshot"),
              "pg_snapshot",
            )
            |> be_ok()
            |> be_equal("10:20:10,14,15")
            |> or_fail_with(
              "Expected the pg_snapshot 10:20:10,14,15 to read as its Gleam value",
            )
          }),
          it("writes txid_snapshot 10:20:10,14,15", fn(sessions) {
            // Act and assert
            "10:20:10,14,15"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("txid_snapshot"),
              "txid_snapshot",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("10:20:10,14,15")
            |> or_fail_with(
              "Expected the server text 10:20:10,14,15 of txid_snapshot",
            )
          }),
          it("reads txid_snapshot 10:20:10,14,15", fn(sessions) {
            // Act and assert
            Some("10:20:10,14,15")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("txid_snapshot"),
              "txid_snapshot",
            )
            |> be_ok()
            |> be_equal("10:20:10,14,15")
            |> or_fail_with(
              "Expected the txid_snapshot 10:20:10,14,15 to read as its Gleam value",
            )
          }),
          it("writes regclass pg_class", fn(sessions) {
            // Act and assert
            "pg_class"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regclass"),
              "regclass",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("pg_class")
            |> or_fail_with("Expected the server text pg_class of regclass")
          }),
          it("reads regclass pg_class", fn(sessions) {
            // Act and assert
            Some("pg_class")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regclass"),
              "regclass",
            )
            |> be_ok()
            |> be_equal("pg_class")
            |> or_fail_with(
              "Expected the regclass pg_class to read as its Gleam value",
            )
          }),
          it("writes regtype integer", fn(sessions) {
            // Act and assert
            "int4"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regtype"),
              "regtype",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("integer")
            |> or_fail_with("Expected the server text integer of regtype")
          }),
          it("reads regtype integer", fn(sessions) {
            // Act and assert
            Some("integer")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regtype"),
              "regtype",
            )
            |> be_ok()
            |> be_equal("integer")
            |> or_fail_with(
              "Expected the regtype integer to read as its Gleam value",
            )
          }),
          it("writes regproc now", fn(sessions) {
            // Act and assert
            "now"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regproc"),
              "regproc",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("now")
            |> or_fail_with("Expected the server text now of regproc")
          }),
          it("reads regproc now", fn(sessions) {
            // Act and assert
            Some("now")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regproc"),
              "regproc",
            )
            |> be_ok()
            |> be_equal("now")
            |> or_fail_with(
              "Expected the regproc now to read as its Gleam value",
            )
          }),
          it("writes regnamespace pg_catalog", fn(sessions) {
            // Act and assert
            "pg_catalog"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regnamespace"),
              "regnamespace",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("pg_catalog")
            |> or_fail_with(
              "Expected the server text pg_catalog of regnamespace",
            )
          }),
          it("reads regnamespace pg_catalog", fn(sessions) {
            // Act and assert
            Some("pg_catalog")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regnamespace"),
              "regnamespace",
            )
            |> be_ok()
            |> be_equal("pg_catalog")
            |> or_fail_with(
              "Expected the regnamespace pg_catalog to read as its Gleam value",
            )
          }),
          it("writes regrole dream", fn(sessions) {
            // Act and assert
            "dream"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regrole"),
              "regrole",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("dream")
            |> or_fail_with("Expected the server text dream of regrole")
          }),
          it("reads regrole dream", fn(sessions) {
            // Act and assert
            Some("dream")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regrole"),
              "regrole",
            )
            |> be_ok()
            |> be_equal("dream")
            |> or_fail_with(
              "Expected the regrole dream to read as its Gleam value",
            )
          }),
          it("writes regconfig simple", fn(sessions) {
            // Act and assert
            "simple"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("regconfig"),
              "regconfig",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("simple")
            |> or_fail_with("Expected the server text simple of regconfig")
          }),
          it("reads regconfig simple", fn(sessions) {
            // Act and assert
            Some("simple")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("regconfig"),
              "regconfig",
            )
            |> be_ok()
            |> be_equal("simple")
            |> or_fail_with(
              "Expected the regconfig simple to read as its Gleam value",
            )
          }),
          it("writes cstring abc", fn(sessions) {
            // Act and assert
            "abc"
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("cstring"),
              "cstring",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("abc")
            |> or_fail_with("Expected the server text abc of cstring")
          }),
          it("reads cstring abc", fn(sessions) {
            // Act and assert
            Some("abc")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("cstring"),
              "cstring",
            )
            |> be_ok()
            |> be_equal("abc")
            |> or_fail_with(
              "Expected the cstring abc to read as its Gleam value",
            )
          }),
          it("writes void ", fn(sessions) {
            // Act and assert
            ""
            |> should
            |> write_on_server(
              sessions,
              probe_types.text_form_codec("void"),
              "void",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("")
            |> or_fail_with("Expected an empty server text of void")
          }),
          it("reads void ", fn(sessions) {
            // Act and assert
            Some("")
            |> should
            |> read_on_server(
              sessions,
              probe_types.text_form_codec("void"),
              "void",
            )
            |> be_ok()
            |> be_equal("")
            |> or_fail_with("Expected an empty void to read as its Gleam value")
          }),
          it("writes int2vector 1 2", fn(sessions) {
            // Act and assert
            [1, 2]
            |> should
            |> write_on_server(sessions, codec.array(codec.int), "int2vector")
            |> be_ok()
            |> be_some()
            |> be_equal("1 2")
            |> or_fail_with("Expected the server text 1 2 of int2vector")
          }),
          it("reads int2vector 1 2", fn(sessions) {
            // Act and assert
            Some("1 2")
            |> should
            |> read_on_server(sessions, codec.array(codec.int), "int2vector")
            |> be_ok()
            |> be_equal([1, 2])
            |> or_fail_with(
              "Expected the int2vector 1 2 to read as its Gleam value",
            )
          }),
          it("writes oidvector 1 2", fn(sessions) {
            // Act and assert
            [1, 2]
            |> should
            |> write_on_server(sessions, codec.array(codec.int), "oidvector")
            |> be_ok()
            |> be_some()
            |> be_equal("1 2")
            |> or_fail_with("Expected the server text 1 2 of oidvector")
          }),
          it("reads oidvector 1 2", fn(sessions) {
            // Act and assert
            Some("1 2")
            |> should
            |> read_on_server(sessions, codec.array(codec.int), "oidvector")
            |> be_ok()
            |> be_equal([1, 2])
            |> or_fail_with(
              "Expected the oidvector 1 2 to read as its Gleam value",
            )
          }),
          it("reads ROW(1.5::numeric, 'a')", fn(sessions) {
            // Act and assert
            "ROW(1.5::numeric, 'a')"
            |> should
            |> read_expression_on_server(
              sessions,
              probe_types.text_form_codec("record"),
            )
            |> be_ok()
            |> be_equal("(1.5,a)")
            |> or_fail_with("Expected the text form of ROW(1.5::numeric, 'a')")
          }),
          it("reads ROW(1, 'dream=r/dream'::aclitem)", fn(sessions) {
            // Act and assert
            "ROW(1, 'dream=r/dream'::aclitem)"
            |> should
            |> read_expression_on_server(
              sessions,
              probe_types.text_form_codec("record"),
            )
            |> be_ok()
            |> be_equal("(1,dream=r/dream)")
            |> or_fail_with(
              "Expected the text form of ROW(1, 'dream=r/dream'::aclitem)",
            )
          }),
          it(
            "reads histogram_bounds FROM pg_stats WHERE tablename = 'probe_counts'",
            fn(sessions) {
              // Act and assert
              "histogram_bounds FROM pg_stats WHERE tablename = 'probe_counts'"
              |> should
              |> read_expression_on_server(
                sessions,
                probe_types.text_form_codec("anyarray"),
              )
              |> be_ok()
              |> be_equal("{1,2,3,4,5}")
              |> or_fail_with(
                "Expected the text form of histogram_bounds FROM pg_stats WHERE tablename = 'probe_counts'",
              )
            },
          ),
          it("writes timetz 24:00:00+00", fn(sessions) {
            // Act and assert
            TimeWithOffset(TimeOfDay(24, 0, 0, 0), 0)
            |> should
            |> write_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_some()
            |> be_equal("24:00:00+00")
            |> or_fail_with("Expected the server text 24:00:00+00 of timetz")
          }),
          it("reads timetz 24:00:00+00", fn(sessions) {
            // Act and assert
            Some("24:00:00+00")
            |> should
            |> read_on_server(sessions, codec.time_with_offset, "timetz")
            |> be_ok()
            |> be_equal(TimeWithOffset(TimeOfDay(24, 0, 0, 0), 0))
            |> or_fail_with(
              "Expected the timetz 24:00:00+00 to read as its Gleam value",
            )
          }),
          it("writes timetz[] {13:45:30+02}", fn(sessions) {
            // Act and assert
            [TimeWithOffset(TimeOfDay(13, 45, 30, 0), 7200)]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.time_with_offset),
              "timetz[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{13:45:30+02}")
            |> or_fail_with(
              "Expected the server text {13:45:30+02} of timetz[]",
            )
          }),
          it("reads timetz[] {13:45:30+02}", fn(sessions) {
            // Act and assert
            Some("{13:45:30+02}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.time_with_offset),
              "timetz[]",
            )
            |> be_ok()
            |> be_equal([TimeWithOffset(TimeOfDay(13, 45, 30, 0), 7200)])
            |> or_fail_with(
              "Expected the timetz[] {13:45:30+02} to read as its Gleam value",
            )
          }),
          it("writes interval 25:00:00", fn(sessions) {
            // Act and assert
            Interval(0, 0, 90_000_000_000)
            |> should
            |> write_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_some()
            |> be_equal("25:00:00")
            |> or_fail_with("Expected the server text 25:00:00 of interval")
          }),
          it("reads interval 25:00:00", fn(sessions) {
            // Act and assert
            Some("25:00:00")
            |> should
            |> read_on_server(sessions, codec.interval, "interval")
            |> be_ok()
            |> be_equal(Interval(0, 0, 90_000_000_000))
            |> or_fail_with(
              "Expected the interval 25:00:00 to read as its Gleam value",
            )
          }),
          it("writes nummultirange {[1.5,2),[3,4)}", fn(sessions) {
            // Act and assert
            [
              range.Range(Inclusive("1.5"), Exclusive("2")),
              range.Range(Inclusive("3"), Exclusive("4")),
            ]
            |> should
            |> write_on_server(
              sessions,
              codec.multirange(codec.numeric),
              "nummultirange",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{[1.5,2),[3,4)}")
            |> or_fail_with(
              "Expected the server text {[1.5,2),[3,4)} of nummultirange",
            )
          }),
          it("reads nummultirange {[1.5,2),[3,4)}", fn(sessions) {
            // Act and assert
            Some("{[1.5,2),[3,4)}")
            |> should
            |> read_on_server(
              sessions,
              codec.multirange(codec.numeric),
              "nummultirange",
            )
            |> be_ok()
            |> be_equal([
              range.Range(Inclusive("1.5"), Exclusive("2")),
              range.Range(Inclusive("3"), Exclusive("4")),
            ])
            |> or_fail_with(
              "Expected the nummultirange {[1.5,2),[3,4)} to read as its Gleam value",
            )
          }),
          it("writes numrange[] {\"[1.5,2)\",empty}", fn(sessions) {
            // Act and assert
            [range.Range(Inclusive("1.5"), Exclusive("2")), EmptyRange]
            |> should
            |> write_on_server(
              sessions,
              codec.array(codec.range(codec.numeric)),
              "numrange[]",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("{\"[1.5,2)\",empty}")
            |> or_fail_with(
              "Expected the server text {\"[1.5,2)\",empty} of numrange[]",
            )
          }),
          it("reads numrange[] {\"[1.5,2)\",empty}", fn(sessions) {
            // Act and assert
            Some("{\"[1.5,2)\",empty}")
            |> should
            |> read_on_server(
              sessions,
              codec.array(codec.range(codec.numeric)),
              "numrange[]",
            )
            |> be_ok()
            |> be_equal([
              range.Range(Inclusive("1.5"), Exclusive("2")),
              EmptyRange,
            ])
            |> or_fail_with(
              "Expected the numrange[] {\"[1.5,2)\",empty} to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_price 3.10", fn(sessions) {
            // Act and assert
            "3.10"
            |> should
            |> write_on_server(sessions, codec.numeric, "pg_temp.probe_price")
            |> be_ok()
            |> be_some()
            |> be_equal("3.10")
            |> or_fail_with(
              "Expected the server text 3.10 of pg_temp.probe_price",
            )
          }),
          it("reads pg_temp.probe_price 3.10", fn(sessions) {
            // Act and assert
            Some("3.10")
            |> should
            |> read_on_server(sessions, codec.numeric, "pg_temp.probe_price")
            |> be_ok()
            |> be_equal("3.10")
            |> or_fail_with(
              "Expected the pg_temp.probe_price 3.10 to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_span [1.5,2.5)", fn(sessions) {
            // Act and assert
            range.Range(Inclusive("1.5"), Exclusive("2.5"))
            |> should
            |> write_on_server(
              sessions,
              codec.range(codec.numeric),
              "pg_temp.probe_span",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("[1.5,2.5)")
            |> or_fail_with(
              "Expected the server text [1.5,2.5) of pg_temp.probe_span",
            )
          }),
          it("reads pg_temp.probe_span [1.5,2.5)", fn(sessions) {
            // Act and assert
            Some("[1.5,2.5)")
            |> should
            |> read_on_server(
              sessions,
              codec.range(codec.numeric),
              "pg_temp.probe_span",
            )
            |> be_ok()
            |> be_equal(range.Range(Inclusive("1.5"), Exclusive("2.5")))
            |> or_fail_with(
              "Expected the pg_temp.probe_span [1.5,2.5) to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_embedding [1,2,3]", fn(sessions) {
            // Act and assert
            vector.list_to_vector([1.0, 2.0, 3.0])
            |> should
            |> be_ok()
            |> write_on_server(
              sessions,
              codec.vector,
              "pg_temp.probe_embedding",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("[1,2,3]")
            |> or_fail_with(
              "Expected the server text [1,2,3] of pg_temp.probe_embedding",
            )
          }),
          it("reads pg_temp.probe_embedding [1,2,3]", fn(sessions) {
            // Act and assert
            Some("[1,2,3]")
            |> should
            |> read_on_server(sessions, codec.vector, "pg_temp.probe_embedding")
            |> be_ok()
            |> have_vector_floats()
            |> be_equal([1.0, 2.0, 3.0])
            |> or_fail_with(
              "Expected the pg_temp.probe_embedding [1,2,3] to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_feeling happy", fn(sessions) {
            // Act and assert
            Happy
            |> should
            |> write_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_feeling",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("happy")
            |> or_fail_with(
              "Expected the server text happy of pg_temp.probe_feeling",
            )
          }),
          it("reads pg_temp.probe_feeling happy", fn(sessions) {
            // Act and assert
            Some("happy")
            |> should
            |> read_on_server(
              sessions,
              probe_types.mood_codec(),
              "pg_temp.probe_feeling",
            )
            |> be_ok()
            |> be_equal(Happy)
            |> or_fail_with(
              "Expected the pg_temp.probe_feeling happy to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_home (\"Main St\",12,)", fn(sessions) {
            // Act and assert
            Address("Main St", 12, None)
            |> should
            |> write_on_server(
              sessions,
              probe_types.address_codec(),
              "pg_temp.probe_home",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("(\"Main St\",12,)")
            |> or_fail_with(
              "Expected the server text (\"Main St\",12,) of pg_temp.probe_home",
            )
          }),
          it("reads pg_temp.probe_home (\"Main St\",12,)", fn(sessions) {
            // Act and assert
            Some("(\"Main St\",12,)")
            |> should
            |> read_on_server(
              sessions,
              probe_types.address_codec(),
              "pg_temp.probe_home",
            )
            |> be_ok()
            |> be_equal(Address("Main St", 12, None))
            |> or_fail_with(
              "Expected the pg_temp.probe_home (\"Main St\",12,) to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_line_item (12.50,3)", fn(sessions) {
            // Act and assert
            LineItem("12.50", 3)
            |> should
            |> write_on_server(
              sessions,
              probe_types.line_item_codec(),
              "pg_temp.probe_line_item",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("(12.50,3)")
            |> or_fail_with(
              "Expected the server text (12.50,3) of pg_temp.probe_line_item",
            )
          }),
          it("reads pg_temp.probe_line_item (12.50,3)", fn(sessions) {
            // Act and assert
            Some("(12.50,3)")
            |> should
            |> read_on_server(
              sessions,
              probe_types.line_item_codec(),
              "pg_temp.probe_line_item",
            )
            |> be_ok()
            |> be_equal(LineItem("12.50", 3))
            |> or_fail_with(
              "Expected the pg_temp.probe_line_item (12.50,3) to read as its Gleam value",
            )
          }),
          it("writes pg_temp.probe_order (\"(0.10,1)\",gift)", fn(sessions) {
            // Act and assert
            Order(LineItem("0.10", 1), Some("gift"))
            |> should
            |> write_on_server(
              sessions,
              probe_types.order_codec(),
              "pg_temp.probe_order",
            )
            |> be_ok()
            |> be_some()
            |> be_equal("(\"(0.10,1)\",gift)")
            |> or_fail_with(
              "Expected the server text (\"(0.10,1)\",gift) of pg_temp.probe_order",
            )
          }),
          it("reads pg_temp.probe_order (\"(0.10,1)\",gift)", fn(sessions) {
            // Act and assert
            Some("(\"(0.10,1)\",gift)")
            |> should
            |> read_on_server(
              sessions,
              probe_types.order_codec(),
              "pg_temp.probe_order",
            )
            |> be_ok()
            |> be_equal(Order(LineItem("0.10", 1), Some("gift")))
            |> or_fail_with(
              "Expected the pg_temp.probe_order (\"(0.10,1)\",gift) to read as its Gleam value",
            )
          }),
          it(
            "writes pg_temp.probe_line_item[] {\"(1.5,2)\",\"(-0.25,0)\"}",
            fn(sessions) {
              // Act and assert
              [LineItem("1.5", 2), LineItem("-0.25", 0)]
              |> should
              |> write_on_server(
                sessions,
                codec.array(probe_types.line_item_codec()),
                "pg_temp.probe_line_item[]",
              )
              |> be_ok()
              |> be_some()
              |> be_equal("{\"(1.5,2)\",\"(-0.25,0)\"}")
              |> or_fail_with(
                "Expected the server text {\"(1.5,2)\",\"(-0.25,0)\"} of pg_temp.probe_line_item[]",
              )
            },
          ),
          it(
            "reads pg_temp.probe_line_item[] {\"(1.5,2)\",\"(-0.25,0)\"}",
            fn(sessions) {
              // Act and assert
              Some("{\"(1.5,2)\",\"(-0.25,0)\"}")
              |> should
              |> read_on_server(
                sessions,
                codec.array(probe_types.line_item_codec()),
                "pg_temp.probe_line_item[]",
              )
              |> be_ok()
              |> be_equal([LineItem("1.5", 2), LineItem("-0.25", 0)])
              |> or_fail_with(
                "Expected the pg_temp.probe_line_item[] {\"(1.5,2)\",\"(-0.25,0)\"} to read as its Gleam value",
              )
            },
          ),
          it("writes vector[] {\"[1,2,3]\",\"[4,5,6]\"}", fn(sessions) {
            // Act and assert
            list.try_map(
              [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]],
              vector.list_to_vector,
            )
            |> should
            |> be_ok()
            |> write_on_server(sessions, codec.array(codec.vector), "vector[]")
            |> be_ok()
            |> be_some()
            |> be_equal("{\"[1,2,3]\",\"[4,5,6]\"}")
            |> or_fail_with(
              "Expected the server text {\"[1,2,3]\",\"[4,5,6]\"} of vector[]",
            )
          }),
          it("reads vector[] {\"[1,2,3]\",\"[4,5,6]\"}", fn(sessions) {
            // Act and assert
            Some("{\"[1,2,3]\",\"[4,5,6]\"}")
            |> should
            |> read_on_server(sessions, codec.array(codec.vector), "vector[]")
            |> be_ok()
            |> have_each_vector_floats()
            |> be_equal([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
            |> or_fail_with(
              "Expected the vector[] {\"[1,2,3]\",\"[4,5,6]\"} to read as its Gleam value",
            )
          }),
        ])
      }),
      // PostgreSQL 17 added the infinite intervals, so each server from 17
      // on has a second group of the same name with those probes.
      list.map(server_versions.from(17), fn(version) {
        group(server_versions.group_name(version), [
          before_all(probe_sessions.choose_version(version)),
          // PostgreSQL 17 added the infinite intervals.
          it("writes interval infinity", fn(sessions) {
            // Act and assert
            PositiveInfinity
            |> should
            |> write_on_server(sessions, codec.interval_or_infinite, "interval")
            |> be_ok()
            |> be_some()
            |> be_equal("infinity")
            |> or_fail_with("Expected the server text infinity of interval")
          }),
          it("reads interval infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(sessions, codec.interval_or_infinite, "interval")
            |> be_ok()
            |> be_equal(PositiveInfinity)
            |> or_fail_with(
              "Expected the interval infinity to read as its Gleam value",
            )
          }),
          it("writes interval -infinity", fn(sessions) {
            // Act and assert
            NegativeInfinity
            |> should
            |> write_on_server(sessions, codec.interval_or_infinite, "interval")
            |> be_ok()
            |> be_some()
            |> be_equal("-infinity")
            |> or_fail_with("Expected the server text -infinity of interval")
          }),
          it("reads interval -infinity", fn(sessions) {
            // Act and assert
            Some("-infinity")
            |> should
            |> read_on_server(sessions, codec.interval_or_infinite, "interval")
            |> be_ok()
            |> be_equal(NegativeInfinity)
            |> or_fail_with(
              "Expected the interval -infinity to read as its Gleam value",
            )
          }),
          it("refuses to read interval infinity", fn(sessions) {
            // Act and assert
            Some("infinity")
            |> should
            |> read_on_server(sessions, codec.interval, "interval")
            |> be_error()
            |> be_equal(ReadDecodeFailed(OutOfRange("infinity")))
            |> or_fail_with(
              "Expected the codec to refuse the interval infinity",
            )
          }),
        ])
      }),
    ),
  )
}
