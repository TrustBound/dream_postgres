//// Decodes bytes that real servers sent, PostgreSQL 16 to 19, recorded
//// once in `test/driver/recorded`. The tests need no server.
////
//// Each server got the same three requests from a plain TCP client:
////
//// - `<version>_startup.bin`: the answer to a StartupMessage for the user
////   `dream_trust`, with the startup parameter `_pq_.dream_test`, which no
////   server knows. It asks for protocol 3.0 on PostgreSQL 16 and 3.2 on the
////   others.
//// - `<version>_error.bin`: the answer to
////   `SELECT relname, 1/0 FROM pg_class LIMIT 1`.
//// - `<version>_rows.bin`: the answer to
////   `SELECT c.relname, NULL::int4, ''::text, ctid FROM pg_class c WHERE relname = 'pg_class'`.

import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/message.{
  type BackendMessage, type ProtocolError, type ResultColumn, BackendKeyData,
  DataRow, Decoded, ErrorResponse, NeedMoreBytes, NegotiateProtocolVersion,
  ParameterStatus, ResultColumn, RowDescription,
}
import dream_postgres/internal/cell.{ColumnDescription, TextFormat}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array.{byte_size, slice}
import gleam/int.{range, to_string}
import gleam/list.{filter_map, first, map, prepend, reverse, take}
import gleam/option.{type Option, None, Some}
import gleam/result.{try}
import gleam/string.{inspect}

@external(erlang, "driver_file_ffi", "read_recording")
fn read_recording(name: String) -> Result(BitArray, String)

type Recording {
  Recording(
    version: Int,
    minor_version: Int,
    secret_key_length: Int,
    server_version: String,
  )
}

fn recordings() -> List(Recording) {
  [
    Recording(16, 0, 4, "16.16"),
    Recording(17, 0, 4, "17.12"),
    Recording(18, 2, 32, "18.7"),
    Recording(19, 2, 32, "19.0"),
  ]
}

/// The tests of the recorded bytes.
pub fn tests() -> TestSuite {
  describe("bytes recorded from real servers", map(recordings(), version_tests))
}

fn version_tests(recording: Recording) {
  group("PostgreSQL " <> to_string(recording.version), [
    it("answers the unknown _pq_ parameter with NegotiateProtocolVersion", fn() {
      check_negotiation(recording)
    }),
    it("sends a secret key of the length of its protocol", fn() {
      check_secret_key(recording)
    }),
    it("reports its server_version", fn() { check_server_version(recording) }),
    it("never gives an error for a cut of the startup answer", fn() {
      check_every_cut(recording)
    }),
    it("sends the SQLSTATE of a division by zero", fn() {
      check_error_code(recording)
    }),
    it("describes a table column, a computed column and a system column", fn() {
      check_columns(recording)
    }),
    it("sends a value, a NULL and an empty value", fn() { check_row(recording) }),
  ])
}

fn check_negotiation(recording: Recording) {
  // Arrange
  let file = name(recording, "startup")

  // Act
  let first_message = messages_of(file) |> try(first_of)

  // Assert
  first_message
  |> should
  |> be_equal(
    Ok(
      NegotiateProtocolVersion(3, recording.minor_version, ["_pq_.dream_test"]),
    ),
  )
  |> or_fail_with("Expected NegotiateProtocolVersion first")
}

fn check_secret_key(recording: Recording) {
  // Arrange
  let file = name(recording, "startup")

  // Act
  let lengths =
    messages_of(file) |> result.map(filter_map(_, secret_key_length))

  // Assert
  lengths
  |> should
  |> be_equal(Ok([recording.secret_key_length]))
  |> or_fail_with("Expected one BackendKeyData with the key length")
}

fn check_server_version(recording: Recording) {
  // Arrange
  let file = name(recording, "startup")

  // Act
  let versions = messages_of(file) |> result.map(filter_map(_, server_version))

  // Assert
  versions
  |> should
  |> be_equal(Ok([recording.server_version]))
  |> or_fail_with("Expected the server_version " <> recording.server_version)
}

fn check_every_cut(recording: Recording) {
  // Arrange
  let bytes = read_recording(name(recording, "startup"))

  // Act
  let errors = bytes |> result.map(cut_errors)

  // Assert
  errors
  |> should
  |> be_equal(Ok([]))
  |> or_fail_with("Expected no error for any cut")
}

fn check_error_code(recording: Recording) {
  // Arrange
  let file = name(recording, "error")

  // Act
  let codes = messages_of(file) |> result.map(filter_map(_, error_code))

  // Assert
  codes
  |> should
  |> be_equal(Ok(["22012"]))
  |> or_fail_with("Expected the SQLSTATE 22012")
}

fn check_columns(recording: Recording) {
  // Arrange
  let file = name(recording, "rows")

  // Act
  let columns = messages_of(file) |> result.map(filter_map(_, row_columns))

  // Assert
  columns
  |> should
  |> be_equal(Ok([expected_columns()]))
  |> or_fail_with("Expected the four described columns")
}

fn check_row(recording: Recording) {
  // Arrange
  let file = name(recording, "rows")

  // Act
  let rows = messages_of(file) |> result.map(filter_map(_, first_three_values))

  // Assert
  rows
  |> should
  |> be_equal(Ok([[Some(<<"pg_class":utf8>>), None, Some(<<>>)]]))
  |> or_fail_with("Expected pg_class, NULL and an empty value")
}

fn expected_columns() -> List(ResultColumn) {
  [
    column("relname", 19, 1259, 2, 64),
    column("int4", 23, 0, 0, 4),
    column("text", 25, 0, 0, -1),
    column("ctid", 27, 1259, -1, 6),
  ]
}

fn column(
  name: String,
  type_id: Int,
  table_id: Int,
  column_number: Int,
  type_size: Int,
) -> ResultColumn {
  ResultColumn(
    column: ColumnDescription(
      name:,
      type_id:,
      type_modifier: -1,
      table_id:,
      column_number:,
    ),
    type_size:,
    format: TextFormat,
  )
}

fn name(recording: Recording, kind: String) -> String {
  "pg" <> to_string(recording.version) <> "_" <> kind <> ".bin"
}

fn first_of(messages: List(BackendMessage)) -> Result(BackendMessage, String) {
  first(messages) |> result.replace_error("no message")
}

fn secret_key_length(message: BackendMessage) -> Result(Int, Nil) {
  case message {
    BackendKeyData(secret_key:, ..) -> Ok(byte_size(secret_key))
    _ -> Error(Nil)
  }
}

fn server_version(message: BackendMessage) -> Result(String, Nil) {
  case message {
    ParameterStatus("server_version", value) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn error_code(message: BackendMessage) -> Result(String, Nil) {
  case message {
    ErrorResponse(report) -> Ok(report.code)
    _ -> Error(Nil)
  }
}

fn row_columns(message: BackendMessage) -> Result(List(ResultColumn), Nil) {
  case message {
    RowDescription(columns) -> Ok(columns)
    _ -> Error(Nil)
  }
}

fn first_three_values(
  message: BackendMessage,
) -> Result(List(Option(BitArray)), Nil) {
  case message {
    DataRow(values) -> Ok(take(values, 3))
    _ -> Error(Nil)
  }
}

/// Every message of a recording, when the bytes end at a message end.
fn messages_of(file: String) -> Result(List(BackendMessage), String) {
  use bytes <- try(read_recording(file))
  use #(messages, rest) <- try(
    decode_all(bytes, []) |> result.map_error(describe_error),
  )
  case rest {
    <<>> -> Ok(messages)
    _ -> Error("bytes left after the last message")
  }
}

fn describe_error(error: ProtocolError) -> String {
  "protocol error: " <> inspect(error)
}

/// Decodes messages until the bytes end inside one, and gives the messages
/// and the bytes that are left.
fn decode_all(
  bytes: BitArray,
  collected: List(BackendMessage),
) -> Result(#(List(BackendMessage), BitArray), ProtocolError) {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) -> decode_all(rest, [message, ..collected])
    Ok(NeedMoreBytes) -> Ok(#(reverse(collected), bytes))
    Error(error) -> Error(error)
  }
}

/// The errors of decoding each cut of the bytes. A cut can end inside a
/// message, but it must never give an error.
fn cut_errors(bytes: BitArray) -> List(#(Int, ProtocolError)) {
  range(from: 0, to: byte_size(bytes), with: [], run: prepend)
  |> filter_map(cut_error(bytes, _))
}

fn cut_error(
  bytes: BitArray,
  length: Int,
) -> Result(#(Int, ProtocolError), Nil) {
  let cut = slice(bytes, 0, length) |> result.unwrap(<<>>)
  case decode_all(cut, []) {
    Ok(_decoded) -> Error(Nil)
    Error(error) -> Ok(#(length, error))
  }
}
