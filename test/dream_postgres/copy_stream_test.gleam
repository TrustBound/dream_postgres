//// The binary COPY format with no server: the quoting of identifiers, the
//// SQL of each COPY, the writer, and the reader of a stream in chunks.

import dream_postgres/error.{
  BytesAfterCopyTrailer, CopyStreamCutShort, InvalidCopyFieldCount,
  InvalidCopyFieldLength, InvalidCopySignature, UnsupportedCopyFlags,
}
import dream_postgres/internal/cell.{Binary}
import dream_postgres/internal/copy
import dream_postgres/internal/copy_request
import dream_postgres/internal/copy_stream
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/copy_streams
import gleam/option.{None, Some}
import matchers/read_copy_stream.{read_copy_stream}

pub fn tests() -> TestSuite {
  describe("the binary COPY format", [
    group("identifiers and SQL", [
      it("an identifier is quoted with its double quotes doubled", fn() {
        // Act and assert
        copy_stream.quote_identifier("Odd \"Name\".x")
        |> should
        |> be_equal("\"Odd \"\"Name\"\".x\"")
        |> or_fail_with("Expected the name in quotes, its quotes doubled")
      }),
      it("copy_from_sql quotes the table and each column", fn() {
        // Act and assert
        copy.copy_from_sql(copy_request.table("public.users"), ["id", "Email"])
        |> should
        |> be_equal(
          "COPY \"public.users\" (\"id\", \"Email\") FROM STDIN (FORMAT binary)",
        )
        |> or_fail_with("Expected the dot kept inside the quoted table name")
      }),
      it("copy_from_sql quotes the schema and the table on their own", fn() {
        // Act and assert
        copy.copy_from_sql(copy_request.table_in_schema("billing", "Invoices"), [
          "id",
        ])
        |> should
        |> be_equal(
          "COPY \"billing\".\"Invoices\" (\"id\") FROM STDIN (FORMAT binary)",
        )
        |> or_fail_with("Expected the schema and the table quoted on their own")
      }),
      it("copy_to_sql puts the query in a binary COPY TO STDOUT", fn() {
        // Act and assert
        copy.copy_to_sql("SELECT 1")
        |> should
        |> be_equal("COPY (SELECT 1) TO STDOUT (FORMAT binary)")
        |> or_fail_with("Expected the query inside COPY TO STDOUT")
      }),
    ]),
    group("the writer", [
      it("a stream is the header, the tuples and the trailer", fn() {
        // Act and assert
        <<
          copy_stream.header():bits,
          copy_stream.encode_tuple([
            Some(<<7:size(32)>>),
            Some(<<"Ada":utf8>>),
          ]):bits,
          copy_stream.encode_tuple([Some(<<8:size(32)>>), None]):bits,
          copy_stream.trailer():bits,
        >>
        |> should
        |> be_equal(copy_streams.stream())
        |> or_fail_with("Expected the bytes of the binary COPY format")
      }),
      it("a tuple of no fields is the field count 0", fn() {
        // Act and assert
        copy_stream.encode_tuple([])
        |> should
        |> be_equal(<<0:size(16)>>)
        |> or_fail_with("Expected the field count 0 alone")
      }),
    ]),
    group("the reader", [
      it("reads a stream in one chunk", fn() {
        // Act and assert
        [copy_streams.stream()]
        |> should
        |> read_copy_stream()
        |> be_equal(Ok(copy_streams.tuples()))
        |> or_fail_with("Expected both tuples")
      }),
      it("reads a stream in chunks of one byte", fn() {
        // Act and assert
        copy_streams.one_byte_chunks(copy_streams.stream())
        |> should
        |> read_copy_stream()
        |> be_equal(Ok(copy_streams.tuples()))
        |> or_fail_with("Expected both tuples from chunks of one byte")
      }),
      it("skips a header extension", fn() {
        // Act and assert
        [
          copy_streams.header(flags: 0, extension: <<1, 2, 3>>),
          <<1:size(16), 1:size(32), 9, -1:size(16)>>,
        ]
        |> should
        |> read_copy_stream()
        |> be_equal(Ok([[Binary(<<9>>)]]))
        |> or_fail_with("Expected the tuple after the skipped extension")
      }),
      it("ignores flags of bits 17 to 31", fn() {
        // Act and assert
        [copy_streams.header(flags: 0x20000, extension: <<>>), <<-1:size(16)>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Ok([]))
        |> or_fail_with("Expected the flag of bit 17 to be ignored")
      }),
      it("refuses the flag of OID columns", fn() {
        // Act and assert
        [copy_streams.header(flags: 0x10000, extension: <<>>)]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(UnsupportedCopyFlags(flags: 0x10000)))
        |> or_fail_with("Expected the OID flag to be refused")
      }),
      it("refuses a critical flag of bits 0 to 15", fn() {
        // Act and assert
        [copy_streams.header(flags: 1, extension: <<>>)]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(UnsupportedCopyFlags(flags: 1)))
        |> or_fail_with("Expected the flag of bit 0 to be refused")
      }),
      it("refuses data with another signature", fn() {
        // Act and assert
        [<<"PGCOPZ":utf8>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(InvalidCopySignature))
        |> or_fail_with("Expected the wrong signature to be refused")
      }),
      it("refuses a field count below -1", fn() {
        // Act and assert
        [copy_streams.header(flags: 0, extension: <<>>), <<-2:size(16)>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(InvalidCopyFieldCount(count: -2)))
        |> or_fail_with("Expected the field count -2 to be refused")
      }),
      it("refuses a field length below -1", fn() {
        // Act and assert
        [
          copy_streams.header(flags: 0, extension: <<>>),
          <<1:size(16), -2:size(32)>>,
        ]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(InvalidCopyFieldLength(length: -2)))
        |> or_fail_with("Expected the field length -2 to be refused")
      }),
      it("refuses a stream with no trailer", fn() {
        // Act and assert
        [copy_streams.header(flags: 0, extension: <<>>), <<1:size(16)>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(CopyStreamCutShort))
        |> or_fail_with("Expected the stream with no trailer to be cut short")
      }),
      it("refuses a stream with no header", fn() {
        // Act and assert
        []
        |> should
        |> read_copy_stream()
        |> be_equal(Error(CopyStreamCutShort))
        |> or_fail_with("Expected the empty stream to be cut short")
      }),
      it("refuses bytes after the trailer in the same chunk", fn() {
        // Act and assert
        [<<copy_streams.stream():bits, 0>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(BytesAfterCopyTrailer))
        |> or_fail_with("Expected the byte after the trailer to be refused")
      }),
      it("refuses bytes after the trailer in a later chunk", fn() {
        // Act and assert
        [copy_streams.stream(), <<0>>]
        |> should
        |> read_copy_stream()
        |> be_equal(Error(BytesAfterCopyTrailer))
        |> or_fail_with("Expected the chunk after the trailer to be refused")
      }),
    ]),
  ])
}
