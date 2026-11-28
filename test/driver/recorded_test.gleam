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

import dream_postgres/driver/cell.{ColumnDescription, TextFormat}
import dream_postgres/driver/message.{
  type ResultColumn, NegotiateProtocolVersion, ResultColumn,
}
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/test_files.{read_recording}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import matchers/extract_backend_messages.{extract_backend_messages}
import matchers/extract_cut_errors.{extract_cut_errors}
import matchers/extract_data_rows.{extract_data_rows}
import matchers/extract_error_codes.{extract_error_codes}
import matchers/extract_first.{extract_first}
import matchers/extract_parameter_values.{extract_parameter_values}
import matchers/extract_row_descriptions.{extract_row_descriptions}
import matchers/extract_secret_key_lengths.{extract_secret_key_lengths}

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
      // Act
      let bytes = read_recording(file_name(recording, "startup"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_first
      |> be_equal(
        NegotiateProtocolVersion(3, recording.minor_version, [
          "_pq_.dream_test",
        ]),
      )
      |> or_fail_with("Expected NegotiateProtocolVersion first")
    }),
    it("sends a secret key of the length of its protocol", fn() {
      // Act
      let bytes = read_recording(file_name(recording, "startup"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_secret_key_lengths
      |> be_equal([recording.secret_key_length])
      |> or_fail_with("Expected one BackendKeyData with the key length")
    }),
    it("reports its server_version", fn() {
      // Act
      let bytes = read_recording(file_name(recording, "startup"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_parameter_values(named: "server_version")
      |> be_equal([recording.server_version])
      |> or_fail_with(
        "Expected the server_version " <> recording.server_version,
      )
    }),
    it("never gives an error for a cut of the startup answer", fn() {
      // Act
      let bytes = read_recording(file_name(recording, "startup"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_cut_errors
      |> be_equal([])
      |> or_fail_with("Expected no error for any cut")
    }),
    it("sends the SQLSTATE of a division by zero", fn() {
      // Act
      let bytes = read_recording(file_name(recording, "error"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_error_codes
      |> be_equal(["22012"])
      |> or_fail_with("Expected the SQLSTATE 22012")
    }),
    it("describes a table column, a computed column and a system column", fn() {
      // Arrange
      let expected_columns = [
        column("relname", 19, 1259, 2, 64),
        column("int4", 23, 0, 0, 4),
        column("text", 25, 0, 0, -1),
        column("ctid", 27, 1259, -1, 6),
      ]

      // Act
      let bytes = read_recording(file_name(recording, "rows"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_row_descriptions
      |> be_equal([expected_columns])
      |> or_fail_with("Expected the four described columns")
    }),
    it("sends a value, a NULL and an empty value", fn() {
      // Act
      let bytes = read_recording(file_name(recording, "rows"))

      // Assert
      bytes
      |> should
      |> be_ok
      |> extract_backend_messages
      |> extract_data_rows(columns: 3)
      |> be_equal([[Some(<<"pg_class":utf8>>), None, Some(<<>>)]])
      |> or_fail_with("Expected pg_class, NULL and an empty value")
    }),
  ])
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

/// The file name of one recording of the server.
fn file_name(recording: Recording, kind: String) -> String {
  "pg" <> to_string(recording.version) <> "_" <> kind <> ".bin"
}
