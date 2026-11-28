//// The text search and pgvector codecs against the exact bytes of their
//// binary formats, and the vector values' checks.

import dream_postgres/codecs/codec_type.{Malformed, NullValue}
import dream_postgres/codecs/text_search.{
  And, EmptyQuery, Lexeme, Not, Phrase, Term, WeightA, WeightB, WeightC, WeightD,
}
import dream_postgres/codecs/vector.{
  DimensionsOutOfRange, ElementTooLarge, FloatTooLarge, IndexOutOfRange,
  NoDimensions, TooManyDimensions, TooManyElements,
}
import dream_postgres/driver/cell.{Binary, Null}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/text_search_samples
import fixtures/type_catalog
import fixtures/vector_bytes
import gleam/dict
import gleam/list
import gleam/string
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}
import matchers/have_half_vector_dimensions.{have_half_vector_dimensions}
import matchers/have_half_vector_floats.{have_half_vector_floats}
import matchers/have_sparse_vector_dimensions.{have_sparse_vector_dimensions}
import matchers/have_sparse_vector_elements.{have_sparse_vector_elements}
import matchers/have_vector_dimensions.{have_vector_dimensions}
import matchers/have_vector_floats.{have_vector_floats}

pub fn tests() -> TestSuite {
  describe("text search and vector codecs", [
    group("vector values", [
      it("keeps the floats of a vector", fn() {
        // Arrange
        let floats = [1.5, -2.0]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_vector_floats()
        |> be_equal([1.5, -2.0])
        |> or_fail_with("Expected the vector to keep the floats 1.5 and -2.0")
      }),
      it("counts the dimensions of a vector", fn() {
        // Arrange
        let floats = [1.5, -2.0, 0.0]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_vector_dimensions()
        |> be_equal(3)
        |> or_fail_with(
          "Expected a vector of three floats to have 3 dimensions",
        )
      }),
      it("refuses a vector of no floats", fn() {
        // Arrange
        let floats = []

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(NoDimensions)
        |> or_fail_with("Expected a vector of no floats to be refused")
      }),
      it("refuses a vector of more than 16000 floats", fn() {
        // Arrange
        let floats = list.repeat(2.0, 16_001)

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(TooManyDimensions(16_001, 16_000))
        |> or_fail_with(
          "Expected 16001 floats to be more than the 16000 a vector holds",
        )
      }),
      it("takes a vector of 16000 floats", fn() {
        // Arrange
        let floats = list.repeat(2.0, 16_000)

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_vector_dimensions()
        |> be_equal(16_000)
        |> or_fail_with(
          "Expected a vector of 16000 floats to have 16000 dimensions",
        )
      }),
      it("refuses a float larger than a float4", fn() {
        // Arrange
        let floats = [1.0, 1.0e39]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(FloatTooLarge(1, 1.0e39, 3.4028234663852886e38))
        |> or_fail_with(
          "Expected the float 1.0e39 at index 1 to be too large for a float4",
        )
      }),
      it("refuses a float smaller than the lowest float4", fn() {
        // Arrange
        let floats = [-1.0e39]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(FloatTooLarge(0, -1.0e39, 3.4028234663852886e38))
        |> or_fail_with(
          "Expected the float -1.0e39 at index 0 to be too large for a float4",
        )
      }),
      it("rounds a float to the nearest float4", fn() {
        // Arrange
        let floats = [0.1]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_vector_floats()
        |> be_equal([0.10000000149011612])
        |> or_fail_with("Expected 0.1 to round to the nearest float4")
      }),
      it("keeps the floats of a half vector", fn() {
        // Arrange
        let floats = [1.5, -2.0, 65_504.0]

        // Act
        let created = vector.half_vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_half_vector_floats()
        |> be_equal([1.5, -2.0, 65_504.0])
        |> or_fail_with(
          "Expected the half vector to keep the floats 1.5, -2.0 and 65504.0",
        )
      }),
      it("counts the dimensions of a half vector", fn() {
        // Arrange
        let floats = [1.5, -2.0]

        // Act
        let created = vector.half_vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_half_vector_dimensions()
        |> be_equal(2)
        |> or_fail_with(
          "Expected a half vector of two floats to have 2 dimensions",
        )
      }),
      it("refuses a float larger than a float2", fn() {
        // Arrange
        let floats = [70_000.0]

        // Act
        let created = vector.half_vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(FloatTooLarge(0, 70_000.0, 65_504.0))
        |> or_fail_with(
          "Expected the float 70000.0 to be too large for a float2",
        )
      }),
      it("refuses a float smaller than the lowest float2", fn() {
        // Arrange
        let floats = [1.0, -70_000.0]

        // Act
        let created = vector.half_vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(FloatTooLarge(1, -70_000.0, 65_504.0))
        |> or_fail_with(
          "Expected the float -70000.0 at index 1 to be too large for a float2",
        )
      }),
    ]),
    group("sparse vector values", [
      it("keeps the elements of a sparse vector, without its zeros", fn() {
        // Arrange
        let elements =
          dict.from_list([#(3, 2.5), #(0, 1.0), #(1, 0.0), #(2, -0.0)])

        // Act
        let created = vector.sparse_vector_from_dict(5, elements)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_sparse_vector_elements()
        |> be_equal(dict.from_list([#(0, 1.0), #(3, 2.5)]))
        |> or_fail_with("Expected only the elements that are not zero")
      }),
      it("keeps the dimensions of a sparse vector", fn() {
        // Arrange
        let elements = dict.new()

        // Act
        let created = vector.sparse_vector_from_dict(5, elements)

        // Assert
        created
        |> should
        |> be_ok()
        |> have_sparse_vector_dimensions()
        |> be_equal(5)
        |> or_fail_with("Expected the sparse vector to keep its 5 dimensions")
      }),
      it("refuses a sparse vector of 0 dimensions", fn() {
        // Arrange
        let elements = dict.new()

        // Act
        let created = vector.sparse_vector_from_dict(0, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(DimensionsOutOfRange(0, 1_000_000_000))
        |> or_fail_with("Expected 0 dimensions to be out of range")
      }),
      it("refuses a sparse vector of more than 1000000000 dimensions", fn() {
        // Arrange
        let elements = dict.new()

        // Act
        let created = vector.sparse_vector_from_dict(1_000_000_001, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(DimensionsOutOfRange(1_000_000_001, 1_000_000_000))
        |> or_fail_with("Expected 1000000001 dimensions to be out of range")
      }),
      it("refuses an index past the dimensions", fn() {
        // Arrange
        let elements = dict.from_list([#(3, 1.0)])

        // Act
        let created = vector.sparse_vector_from_dict(3, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(IndexOutOfRange(3, 3))
        |> or_fail_with("Expected the index 3 to be past 3 dimensions")
      }),
      it("refuses a negative index", fn() {
        // Arrange
        let elements = dict.from_list([#(-1, 1.0)])

        // Act
        let created = vector.sparse_vector_from_dict(3, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(IndexOutOfRange(-1, 3))
        |> or_fail_with("Expected the index -1 to be out of range")
      }),
      it("refuses an element larger than a float4", fn() {
        // Arrange
        let elements = dict.from_list([#(2, 1.0e39)])

        // Act
        let created = vector.sparse_vector_from_dict(3, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(ElementTooLarge(2, 1.0e39, 3.4028234663852886e38))
        |> or_fail_with(
          "Expected the element 1.0e39 at index 2 to be too large for a float4",
        )
      }),
      it("refuses more than 16000 elements", fn() {
        // Arrange
        let floats = list.repeat(1.0, 16_001)
        let elements =
          floats
          |> list.index_map(fn(value, index) { #(index, value) })
          |> dict.from_list

        // Act
        let created = vector.sparse_vector_from_dict(20_000, elements)

        // Assert
        created
        |> should
        |> be_error()
        |> be_equal(TooManyElements(16_001, 16_000))
        |> or_fail_with(
          "Expected 16001 elements to be more than the 16000 a sparse vector holds",
        )
      }),
    ]),
    group("vector codecs", [
      it("takes vector", fn() {
        // Arrange
        let subject = vector.vector

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("vector"))
        |> be_true()
        |> or_fail_with("Expected vector to take the type vector")
      }),
      it("takes halfvec", fn() {
        // Arrange
        let subject = vector.half_vector

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("halfvec"))
        |> be_true()
        |> or_fail_with("Expected half_vector to take the type halfvec")
      }),
      it("takes sparsevec", fn() {
        // Arrange
        let subject = vector.sparse_vector

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("sparsevec"))
        |> be_true()
        |> or_fail_with("Expected sparse_vector to take the type sparsevec")
      }),
      it("does not take halfvec as a vector", fn() {
        // Arrange
        let subject = vector.vector

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("halfvec"))
        |> be_false()
        |> or_fail_with("Expected vector to refuse the type halfvec")
      }),
      it("writes a vector", fn() {
        // Arrange
        let floats = [1.5, -2.0]

        // Act
        let created = vector.vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> encode_as(vector.vector, type_catalog.base("vector"))
        |> be_ok()
        |> be_equal(Binary(vector_bytes.vector_of_two()))
        |> or_fail_with(
          "Expected the dimensions 2, the unused 0 and two float4 values",
        )
      }),
      it("reads a vector", fn() {
        // Arrange
        let cell = Binary(vector_bytes.vector_of_two())

        // Act and assert
        cell
        |> should
        |> decode_as(vector.vector, type_catalog.base("vector"))
        |> be_ok()
        |> have_vector_floats()
        |> be_equal([1.5, -2.0])
        |> or_fail_with("Expected the vector [1.5,-2]")
      }),
      it("refuses a vector of 0 dimensions", fn() {
        // Arrange
        let cell = Binary(<<0:size(16), 0:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.vector, type_catalog.base("vector"))
        |> be_error()
        |> be_equal(Malformed("the vector's dimensions do not match its floats"))
        |> or_fail_with("Expected a vector of 0 dimensions to be malformed")
      }),
      it("refuses a vector whose floats do not match its dimensions", fn() {
        // Arrange
        let cell = Binary(<<2:size(16), 0:size(16), 0x3FC00000:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.vector, type_catalog.base("vector"))
        |> be_error()
        |> be_equal(Malformed("the vector's dimensions do not match its floats"))
        |> or_fail_with("Expected 2 dimensions with one float to be malformed")
      }),
      it("refuses a vector that holds NaN", fn() {
        // Arrange
        let cell = Binary(<<1:size(16), 0:size(16), 0x7FC00000:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.vector, type_catalog.base("vector"))
        |> be_error()
        |> be_equal(Malformed("the vector holds a float that is not finite"))
        |> or_fail_with("Expected a vector that holds NaN to be malformed")
      }),
      it("gives NullValue for a NULL vector", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(vector.vector, type_catalog.base("vector"))
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a vector")
      }),
      it("writes a half vector", fn() {
        // Arrange
        let floats = [1.5, -2.0]

        // Act
        let created = vector.half_vector_from_list(floats)

        // Assert
        created
        |> should
        |> be_ok()
        |> encode_as(vector.half_vector, type_catalog.base("halfvec"))
        |> be_ok()
        |> be_equal(Binary(vector_bytes.half_vector_of_two()))
        |> or_fail_with(
          "Expected the dimensions 2, the unused 0 and two float2 values",
        )
      }),
      it("reads a half vector", fn() {
        // Arrange
        let cell = Binary(vector_bytes.half_vector_of_two())

        // Act and assert
        cell
        |> should
        |> decode_as(vector.half_vector, type_catalog.base("halfvec"))
        |> be_ok()
        |> have_half_vector_floats()
        |> be_equal([1.5, -2.0])
        |> or_fail_with("Expected the half vector [1.5,-2]")
      }),
      it("refuses a half vector whose floats do not match its dimensions", fn() {
        // Arrange
        let cell = Binary(<<0:size(16), 0:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.half_vector, type_catalog.base("halfvec"))
        |> be_error()
        |> be_equal(Malformed(
          "the half vector's dimensions do not match its floats",
        ))
        |> or_fail_with(
          "Expected a half vector of 0 dimensions to be malformed",
        )
      }),
      it("refuses a half vector that holds infinity", fn() {
        // Arrange
        let cell = Binary(<<1:size(16), 0:size(16), 0x7C00:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.half_vector, type_catalog.base("halfvec"))
        |> be_error()
        |> be_equal(Malformed(
          "the half vector holds a float that is not finite",
        ))
        |> or_fail_with(
          "Expected a half vector that holds infinity to be malformed",
        )
      }),
      it("writes a sparse vector", fn() {
        // Arrange
        let elements = dict.from_list([#(3, -2.0), #(0, 1.5)])

        // Act
        let created = vector.sparse_vector_from_dict(5, elements)

        // Assert
        created
        |> should
        |> be_ok()
        |> encode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_ok()
        |> be_equal(Binary(vector_bytes.sparse_vector_of_two()))
        |> or_fail_with(
          "Expected the dimensions, the count, the indices in order, then the floats",
        )
      }),
      it("reads a sparse vector", fn() {
        // Arrange
        let cell = Binary(vector_bytes.sparse_vector_of_two())

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_ok()
        |> have_sparse_vector_elements()
        |> be_equal(dict.from_list([#(0, 1.5), #(3, -2.0)]))
        |> or_fail_with("Expected 1.5 at index 0 and -2.0 at index 3")
      }),
      it("reads the dimensions of a sparse vector", fn() {
        // Arrange
        let cell = Binary(<<5:size(32), 0:size(32), 0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_ok()
        |> have_sparse_vector_dimensions()
        |> be_equal(5)
        |> or_fail_with("Expected the sparse vector of 5 dimensions")
      }),
      it("refuses a sparse vector of 0 dimensions", fn() {
        // Arrange
        let cell = Binary(<<0:size(32), 0:size(32), 0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_error()
        |> be_equal(Malformed(
          "the sparse vector's sizes do not match its elements",
        ))
        |> or_fail_with(
          "Expected a sparse vector of 0 dimensions to be malformed",
        )
      }),
      it("refuses a sparse vector whose indices go down", fn() {
        // Arrange
        let cell =
          Binary(<<
            5:size(32),
            2:size(32),
            0:size(32),
            3:size(32),
            0:size(32),
            0x3FC00000:size(32),
            0xC0000000:size(32),
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_error()
        |> be_equal(Malformed(
          "the sparse vector holds an index out of order or out of range, or a float that is not finite",
        ))
        |> or_fail_with("Expected the indices 3 then 0 to be out of order")
      }),
      it("refuses a sparse vector with an index past its dimensions", fn() {
        // Arrange
        let cell =
          Binary(<<
            5:size(32),
            1:size(32),
            0:size(32),
            5:size(32),
            0x3FC00000:size(32),
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_error()
        |> be_equal(Malformed(
          "the sparse vector holds an index out of order or out of range, or a float that is not finite",
        ))
        |> or_fail_with("Expected the index 5 to be past 5 dimensions")
      }),
      it("refuses a sparse vector that holds NaN", fn() {
        // Arrange
        let cell =
          Binary(<<
            5:size(32),
            1:size(32),
            0:size(32),
            1:size(32),
            0x7FC00000:size(32),
          >>)

        // Act and assert
        cell
        |> should
        |> decode_as(vector.sparse_vector, type_catalog.base("sparsevec"))
        |> be_error()
        |> be_equal(Malformed(
          "the sparse vector holds an index out of order or out of range, or a float that is not finite",
        ))
        |> or_fail_with(
          "Expected a sparse vector that holds NaN to be malformed",
        )
      }),
    ]),
    group("text search vectors", [
      it("takes tsvector", fn() {
        // Arrange
        let subject = text_search.text_search_vector

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("tsvector"))
        |> be_true()
        |> or_fail_with("Expected text_search_vector to take the type tsvector")
      }),
      it("writes a text search vector", fn() {
        // Arrange
        let value = [
          Lexeme("cat", [#(1, WeightA), #(3, WeightD)]),
          Lexeme("dog", []),
        ]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> be_equal(Binary(text_search_samples.cat_and_dog_vector_bytes()))
        |> or_fail_with(
          "Expected the count, then each lexeme with its positions",
        )
      }),
      it("reads a text search vector", fn() {
        // Arrange
        let cell = Binary(text_search_samples.cat_and_dog_vector_bytes())

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> be_equal([
          Lexeme("cat", [#(1, WeightA), #(3, WeightD)]),
          Lexeme("dog", []),
        ])
        |> or_fail_with("Expected the lexemes cat:1A,3 and dog")
      }),
      it("writes the weights B and C", fn() {
        // Arrange
        let value = [Lexeme("cat", [#(1, WeightB), #(16_383, WeightC)])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> be_equal(Binary(text_search_samples.weights_b_and_c_vector_bytes()))
        |> or_fail_with("Expected the weight bits 10 for B and 01 for C")
      }),
      it("reads the weights B and C", fn() {
        // Arrange
        let cell = Binary(text_search_samples.weights_b_and_c_vector_bytes())

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> be_equal([Lexeme("cat", [#(1, WeightB), #(16_383, WeightC)])])
        |> or_fail_with("Expected the weights B and C")
      }),
      it("writes an empty text search vector", fn() {
        // Arrange
        let value = []

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> be_equal(Binary(<<0:size(32)>>))
        |> or_fail_with("Expected the count 0")
      }),
      it("refuses an empty lexeme", fn() {
        // Arrange
        let value = [Lexeme("", [])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("a lexeme or a query word cannot be empty")
        |> or_fail_with("Expected an empty lexeme to be refused")
      }),
      it("refuses a lexeme of more than 2047 bytes", fn() {
        // Arrange
        let word = string.repeat("a", 2048)

        // Act and assert
        [Lexeme(word, [])]
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the word " <> word <> " is longer than 2047 bytes")
        |> or_fail_with("Expected a lexeme of 2048 bytes to be too long")
      }),
      it("takes a lexeme of 2047 bytes", fn() {
        // Arrange
        let value = [Lexeme(string.repeat("a", 2047), [])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_ok()
        |> or_fail_with("Expected a lexeme of 2047 bytes to be written")
      }),
      it("refuses a lexeme that holds a 0 byte", fn() {
        // Arrange
        let value = [Lexeme("a\u{0}b", [])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("a lexeme or a query word cannot hold a 0 byte")
        |> or_fail_with("Expected a lexeme that holds a 0 byte to be refused")
      }),
      it("refuses a lexeme that is in the vector twice", fn() {
        // Arrange
        let value = [Lexeme("cat", []), Lexeme("cat", [#(1, WeightA)])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the lexeme cat is in the vector twice")
        |> or_fail_with("Expected the lexeme cat twice to be refused")
      }),
      it("refuses more than 256 positions", fn() {
        // Arrange
        let positions =
          list.repeat(WeightD, 257)
          |> list.index_map(fn(weight, index) { #(index + 1, weight) })

        // Act and assert
        [Lexeme("cat", positions)]
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the lexeme cat has more than 256 positions")
        |> or_fail_with("Expected 257 positions to be refused")
      }),
      it("refuses the position 0", fn() {
        // Arrange
        let value = [Lexeme("cat", [#(0, WeightD)])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the position 0 of cat is outside 1 to 16383")
        |> or_fail_with("Expected the position 0 to be refused")
      }),
      it("refuses a position past 16383", fn() {
        // Arrange
        let value = [Lexeme("cat", [#(16_384, WeightD)])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the position 16384 of cat is outside 1 to 16383")
        |> or_fail_with("Expected the position 16384 to be refused")
      }),
      it("refuses positions that do not go up", fn() {
        // Arrange
        let value = [Lexeme("cat", [#(2, WeightA), #(2, WeightB)])]

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal("the positions of cat must go up, each once")
        |> or_fail_with("Expected the position 2 twice to be refused")
      }),
      it("refuses a text search vector that is cut short", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("1 bytes are not a tsvector value"))
        |> or_fail_with("Expected a count of one byte to be malformed")
      }),
      it("refuses bytes after the last lexeme", fn() {
        // Arrange
        let cell = Binary(<<0:size(32), 1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("the vector has bytes after its last lexeme"))
        |> or_fail_with("Expected a byte after the last lexeme to be malformed")
      }),
      it("refuses a lexeme with no number of positions", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), "cat":utf8, 0>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("the lexeme cat is cut short"))
        |> or_fail_with(
          "Expected the lexeme cat with no number of positions to be malformed",
        )
      }),
      it("refuses positions that are cut short", fn() {
        // Arrange
        let cell =
          Binary(<<1:size(32), "cat":utf8, 0, 2:size(16), 0xC001:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("the positions are cut short"))
        |> or_fail_with("Expected one of two positions to be malformed")
      }),
      it("refuses a lexeme with no 0 byte at its end", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), "cat":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("a word has no 0 byte at its end"))
        |> or_fail_with(
          "Expected the lexeme cat with no 0 byte to be malformed",
        )
      }),
      it("refuses a lexeme that is not UTF-8", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 0xFF, 0, 0:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_vector,
          type_catalog.base("tsvector"),
        )
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with(
          "Expected the lexeme byte 255 to be refused as not UTF-8",
        )
      }),
    ]),
    group("text search queries", [
      it("takes tsquery", fn() {
        // Arrange
        let subject = text_search.text_search_query

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("tsquery"))
        |> be_true()
        |> or_fail_with("Expected text_search_query to take the type tsquery")
      }),
      it("writes a text search query", fn() {
        // Arrange
        let value = text_search_samples.query()

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(Binary(text_search_samples.query_bytes()))
        |> or_fail_with(
          "Expected the items of cat & (dog:AC* | !fox) in prefix order",
        )
      }),
      it("reads a text search query", fn() {
        // Arrange
        let cell = Binary(text_search_samples.query_bytes())

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(text_search_samples.query())
        |> or_fail_with("Expected the query cat & (dog:AC* | !fox)")
      }),
      it("writes a phrase", fn() {
        // Arrange
        let value = text_search_samples.phrase()

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(Binary(text_search_samples.phrase_bytes()))
        |> or_fail_with("Expected the phrase operator with the distance 2")
      }),
      it("reads a phrase", fn() {
        // Arrange
        let cell = Binary(text_search_samples.phrase_bytes())

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(text_search_samples.phrase())
        |> or_fail_with("Expected the phrase a:ABCD <2> b:B")
      }),
      it("writes the empty query", fn() {
        // Arrange
        let value = EmptyQuery

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(Binary(<<0:size(32)>>))
        |> or_fail_with("Expected the empty query as the count 0")
      }),
      it("reads the empty query", fn() {
        // Arrange
        let cell = Binary(<<0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_ok()
        |> be_equal(EmptyQuery)
        |> or_fail_with("Expected the count 0 to be the empty query")
      }),
      it("refuses the empty query inside a query", fn() {
        // Arrange
        let value = Not(EmptyQuery)

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(
          "an empty query can only be the whole query, not a part of one",
        )
        |> or_fail_with("Expected an empty query under Not to be refused")
      }),
      it("refuses an empty word", fn() {
        // Arrange
        let value = Term("", [], False)

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal("a lexeme or a query word cannot be empty")
        |> or_fail_with("Expected an empty query word to be refused")
      }),
      it("refuses a negative phrase distance", fn() {
        // Arrange
        let value = Phrase(-1, Term("a", [], False), Term("b", [], False))

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal("the phrase distance -1 is outside 0 to 16384")
        |> or_fail_with("Expected the phrase distance -1 to be refused")
      }),
      it("refuses a phrase distance past 16384", fn() {
        // Arrange
        let value = Phrase(16_385, Term("a", [], False), Term("b", [], False))

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal("the phrase distance 16385 is outside 0 to 16384")
        |> or_fail_with("Expected the phrase distance 16385 to be refused")
      }),
      it("refuses an empty query in the left operand", fn() {
        // Arrange
        let value = And(EmptyQuery, Term("b", [], False))

        // Act and assert
        value
        |> should
        |> encode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(
          "an empty query can only be the whole query, not a part of one",
        )
        |> or_fail_with(
          "Expected an empty query as the left operand to be refused",
        )
      }),
      it("refuses a text search query that is cut short", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(Malformed("1 bytes are not a tsquery value"))
        |> or_fail_with("Expected a count of one byte to be malformed")
      }),
      it("refuses bytes after the last item", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 1, 0, 0, "a":utf8, 0, 9>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(Malformed("the query has bytes after its last item"))
        |> or_fail_with("Expected a byte after the last item to be malformed")
      }),
      it("refuses an item of an unknown kind", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 7>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(Malformed("the query has an item of an unknown kind"))
        |> or_fail_with("Expected the item kind 7 to be malformed")
      }),
      it("refuses a word with no 0 byte at its end", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 1, 0, 0, "a":utf8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          text_search.text_search_query,
          type_catalog.base("tsquery"),
        )
        |> be_error()
        |> be_equal(Malformed("a word has no 0 byte at its end"))
        |> or_fail_with(
          "Expected the query word a with no 0 byte to be malformed",
        )
      }),
    ]),
  ])
}
