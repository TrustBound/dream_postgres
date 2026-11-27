//// Proves the bit-array features that the driver's encoder and decoder rely
//// on, before any test of the driver itself. Each one is a plain Gleam
//// expression or pattern, checked against bytes written out one by one.

import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import matchers/extract_float.{extract_float}
import matchers/extract_length_prefixed_bytes.{extract_length_prefixed_bytes}
import matchers/extract_signed_integer.{extract_signed_integer}
import matchers/extract_unsigned_integer.{extract_unsigned_integer}
import matchers/split_bytes.{split_bytes}

/// The tests of the bit-array features.
pub fn tests() -> TestSuite {
  describe("the bit-array features of the driver", [
    sized_integer_tests(),
    signed_integer_tests(),
    float_tests(),
    byte_slice_tests(),
  ])
}

fn sized_integer_tests() {
  group("sized integers are big-endian", [
    it("writes a 16-bit integer as two bytes", fn() {
      // Act
      let bytes = <<1234:16>>

      // Assert
      bytes
      |> should
      |> be_equal(<<4, 210>>)
      |> or_fail_with("Expected 1234 as the bytes 4 and 210")
    }),
    it("writes a 32-bit integer as four bytes", fn() {
      // Act
      let bytes = <<80_877_103:32>>

      // Assert
      bytes
      |> should
      |> be_equal(<<4, 210, 22, 47>>)
      |> or_fail_with("Expected the SSLRequest code as 4, 210, 22, 47")
    }),
    it("reads an unsigned 32-bit integer above the signed range", fn() {
      // Arrange
      let bytes = <<255, 255, 255, 255>>

      // Act and Assert
      bytes
      |> should
      |> extract_unsigned_integer(bits: 32)
      |> be_equal(4_294_967_295)
      |> or_fail_with("Expected 4294967295")
    }),
  ])
}

fn signed_integer_tests() {
  group("signed integers", [
    it("writes -1 as a 32-bit integer of four 255 bytes", fn() {
      // Act
      let bytes = <<-1:32>>

      // Assert
      bytes
      |> should
      |> be_equal(<<255, 255, 255, 255>>)
      |> or_fail_with("Expected -1 as four 255 bytes")
    }),
    it("reads four 255 bytes as -1 with the signed option", fn() {
      // Arrange
      let bytes = <<255, 255, 255, 255>>

      // Act and Assert
      bytes
      |> should
      |> extract_signed_integer(bits: 32)
      |> be_equal(-1)
      |> or_fail_with("Expected -1")
    }),
    it("reads a signed 16-bit integer", fn() {
      // Arrange
      let bytes = <<255, 254>>

      // Act and Assert
      bytes
      |> should
      |> extract_signed_integer(bits: 16)
      |> be_equal(-2)
      |> or_fail_with("Expected -2")
    }),
  ])
}

fn float_tests() {
  group("floats", [
    it("writes a 64-bit float as its IEEE 754 bytes", fn() {
      // Act
      let bytes = <<1.5:float-size(64)>>

      // Assert
      bytes
      |> should
      |> be_equal(<<63, 248, 0, 0, 0, 0, 0, 0>>)
      |> or_fail_with("Expected 1.5 as 63, 248 and six zero bytes")
    }),
    it("reads a 32-bit float", fn() {
      // Arrange
      let bytes = <<64, 32, 0, 0>>

      // Act and Assert
      bytes
      |> should
      |> extract_float(bits: 32)
      |> be_equal(2.5)
      |> or_fail_with("Expected 2.5")
    }),
  ])
}

fn byte_slice_tests() {
  group("byte slices", [
    it("takes a slice whose size is a variable", fn() {
      // Arrange
      let bytes = <<3:32, "abcdef":utf8>>

      // Act and Assert
      bytes
      |> should
      |> extract_length_prefixed_bytes
      |> be_equal(<<"abc":utf8>>)
      |> or_fail_with("Expected the first three bytes")
    }),
    it("gives the bytes after a slice", fn() {
      // Arrange
      let bytes = <<"abcdef":utf8>>

      // Act and Assert
      bytes
      |> should
      |> split_bytes(at: 2)
      |> be_ok
      |> be_equal(#(<<"ab":utf8>>, <<"cdef":utf8>>))
      |> or_fail_with("Expected the bytes after the first two")
    }),
    it("does not match a slice longer than the bytes", fn() {
      // Arrange
      let bytes = <<"ab":utf8>>

      // Act and Assert
      bytes
      |> should
      |> split_bytes(at: 3)
      |> be_error
      |> be_equal(Nil)
      |> or_fail_with("Expected no match for a slice of 3 bytes out of 2")
    }),
    it("does not match a slice of a negative size", fn() {
      // Arrange
      let size = -1
      let bytes = <<"ab":utf8>>

      // Act and Assert
      bytes
      |> should
      |> split_bytes(at: size)
      |> be_error
      |> be_equal(Nil)
      |> or_fail_with("Expected no match for a slice of size -1")
    }),
    it("writes a string as its UTF-8 bytes", fn() {
      // Act
      let bytes = <<"é":utf8, 0>>

      // Assert
      bytes
      |> should
      |> be_equal(<<195, 169, 0>>)
      |> or_fail_with("Expected é as 195, 169, then a zero byte")
    }),
  ])
}
