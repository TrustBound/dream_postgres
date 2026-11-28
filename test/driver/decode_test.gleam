//// Tests for `dream_postgres/driver/decode`: every backend message from its
//// exact bytes, written out from the layouts of the PostgreSQL
//// documentation ("Message Formats"); every cut of each message; and each
//// way that bytes can fail to be a message.

import dream_postgres/driver/cell.{
  BinaryFormat, ColumnDescription, Idle, InFailedTransaction, InTransaction,
  ParameterDescription, ServerReport, TextFormat,
}
import dream_postgres/driver/decode.{
  decode_backend, decode_gss_encryption_answer, decode_ssl_answer,
}
import dream_postgres/driver/message.{
  type BackendMessage, type ProtocolError, AuthenticationCleartextPassword,
  AuthenticationGss, AuthenticationGssContinue, AuthenticationKerberosV5,
  AuthenticationMd5Password, AuthenticationOk, AuthenticationSasl,
  AuthenticationSaslContinue, AuthenticationSaslFinal, AuthenticationSspi,
  BackendKeyData, BindComplete, CloseComplete, CommandComplete, CopyBothResponse,
  CopyDataFromServer, CopyDoneFromServer, CopyInResponse, CopyOutResponse,
  DataRow, Decoded, EmptyQueryResponse, EncryptionAccepted,
  EncryptionErrorResponse, EncryptionRefused, ErrorResponse,
  FunctionCallResponse, InvalidMessageBody, InvalidMessageLength,
  InvalidReportNumber, InvalidSecretKeyLength, InvalidUtf8, MissingReportField,
  NeedMoreBytes, NegotiateProtocolVersion, NoData, NoticeResponse,
  NotificationResponse, ParameterDescriptions, ParameterStatus, ParseComplete,
  PortalSuspended, ReadyForQuery, ResultColumn, RowDescription, UnknownAnswer,
  UnknownAuthenticationRequest, UnknownFormatCode, UnknownMessageType,
  UnknownTransactionStatus,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array.{byte_size, concat}
import gleam/list.{flatten, map}
import gleam/option.{None, Some}
import matchers/extract_wrong_cut_answers.{extract_wrong_cut_answers}

/// The tests of the decoder.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/decode", [
    group(
      "each backend message from its bytes",
      map(message_cases(), message_test),
    ),
    group(
      "each backend message cut at any byte",
      map(message_cases(), every_cut_test),
    ),
    group("the bytes after a message", [rest_test()]),
    group("bytes that are not a message", map(error_cases(), error_test)),
    group("the answer to an encryption request", answer_tests()),
  ])
}

type MessageCase {
  MessageCase(name: String, bytes: BitArray, message: BackendMessage)
}

type ErrorCase {
  ErrorCase(name: String, bytes: BitArray, error: ProtocolError)
}

fn message_test(test_case: MessageCase) {
  it(test_case.name, fn() {
    // Act
    let step = decode_backend(test_case.bytes)

    // Assert
    step
    |> should
    |> be_ok
    |> be_equal(Decoded(test_case.message, <<>>))
    |> or_fail_with("Expected the message of " <> test_case.name)
  })
}

fn every_cut_test(test_case: MessageCase) {
  it(test_case.name, fn() {
    // Act and Assert
    test_case.bytes
    |> should
    |> extract_wrong_cut_answers
    |> be_equal([])
    |> or_fail_with(
      "Expected NeedMoreBytes for every cut of " <> test_case.name,
    )
  })
}

fn rest_test() {
  it("gives the bytes after the first message", fn() {
    // Arrange
    let bytes = <<"1", 4:32, "2", 4:32, "Z">>

    // Act
    let step = decode_backend(bytes)

    // Assert
    step
    |> should
    |> be_ok
    |> be_equal(Decoded(ParseComplete, <<"2", 4:32, "Z">>))
    |> or_fail_with("Expected ParseComplete and the bytes after it")
  })
}

fn error_test(test_case: ErrorCase) {
  it(test_case.name, fn() {
    // Act
    let step = decode_backend(test_case.bytes)

    // Assert
    step
    |> should
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn message_cases() -> List(MessageCase) {
  flatten([
    authentication_cases(),
    startup_cases(),
    query_cases(),
    copy_cases(),
    report_cases(),
  ])
}

fn authentication_cases() -> List(MessageCase) {
  [
    MessageCase("AuthenticationOk", <<"R", 8:32, 0:32>>, AuthenticationOk),
    MessageCase(
      "AuthenticationKerberosV5",
      <<"R", 8:32, 2:32>>,
      AuthenticationKerberosV5,
    ),
    MessageCase(
      "AuthenticationCleartextPassword",
      <<"R", 8:32, 3:32>>,
      AuthenticationCleartextPassword,
    ),
    MessageCase(
      "AuthenticationMD5Password",
      <<"R", 12:32, 5:32, 1, 2, 3, 4>>,
      AuthenticationMd5Password(<<1, 2, 3, 4>>),
    ),
    MessageCase("AuthenticationGSS", <<"R", 8:32, 7:32>>, AuthenticationGss),
    MessageCase(
      "AuthenticationGSSContinue",
      <<"R", 11:32, 8:32, 9, 8, 7>>,
      AuthenticationGssContinue(<<9, 8, 7>>),
    ),
    MessageCase("AuthenticationSSPI", <<"R", 8:32, 9:32>>, AuthenticationSspi),
    MessageCase(
      "AuthenticationSASL with two mechanisms",
      <<
        "R", 42:32, 10:32, "SCRAM-SHA-256-PLUS":utf8, 0, "SCRAM-SHA-256":utf8, 0,
        0,
      >>,
      AuthenticationSasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]),
    ),
    MessageCase(
      "AuthenticationSASLContinue",
      <<"R", 14:32, 11:32, "r=abc,":utf8>>,
      AuthenticationSaslContinue(<<"r=abc,":utf8>>),
    ),
    MessageCase(
      "AuthenticationSASLFinal",
      <<"R", 12:32, 12:32, "v=xy":utf8>>,
      AuthenticationSaslFinal(<<"v=xy":utf8>>),
    ),
  ]
}

fn startup_cases() -> List(MessageCase) {
  [
    MessageCase(
      "BackendKeyData with a 4-byte key",
      <<"K", 12:32, 4321:32, 1, 2, 3, 4>>,
      BackendKeyData(4321, <<1, 2, 3, 4>>),
    ),
    MessageCase(
      "BackendKeyData with a 32-byte key of protocol 3.2",
      <<"K", 40:32, 4321:32, 5:256>>,
      BackendKeyData(4321, <<5:256>>),
    ),
    MessageCase(
      "NegotiateProtocolVersion",
      <<"v", 25:32, 3:16, 0:16, 1:32, "_pq_.unknown":utf8, 0>>,
      NegotiateProtocolVersion(3, 0, ["_pq_.unknown"]),
    ),
    MessageCase(
      "ParameterStatus",
      <<"S", 25:32, "client_encoding":utf8, 0, "UTF8":utf8, 0>>,
      ParameterStatus("client_encoding", "UTF8"),
    ),
    MessageCase("ReadyForQuery idle", <<"Z", 5:32, "I">>, ReadyForQuery(Idle)),
    MessageCase(
      "ReadyForQuery in a transaction",
      <<"Z", 5:32, "T">>,
      ReadyForQuery(InTransaction),
    ),
    MessageCase(
      "ReadyForQuery in a failed transaction",
      <<"Z", 5:32, "E">>,
      ReadyForQuery(InFailedTransaction),
    ),
    MessageCase(
      "NotificationResponse",
      <<"A", 18:32, 4321:32, "jobs":utf8, 0, "done":utf8, 0>>,
      NotificationResponse(4321, "jobs", "done"),
    ),
  ]
}

fn query_cases() -> List(MessageCase) {
  [
    MessageCase("ParseComplete", <<"1", 4:32>>, ParseComplete),
    MessageCase("BindComplete", <<"2", 4:32>>, BindComplete),
    MessageCase("CloseComplete", <<"3", 4:32>>, CloseComplete),
    MessageCase("NoData", <<"n", 4:32>>, NoData),
    MessageCase("PortalSuspended", <<"s", 4:32>>, PortalSuspended),
    MessageCase("EmptyQueryResponse", <<"I", 4:32>>, EmptyQueryResponse),
    MessageCase(
      "CommandComplete",
      <<"C", 15:32, "INSERT 0 3":utf8, 0>>,
      CommandComplete("INSERT 0 3"),
    ),
    MessageCase(
      "ParameterDescription",
      <<"t", 14:32, 2:16, 23:32, 25:32>>,
      ParameterDescriptions([ParameterDescription(23), ParameterDescription(25)]),
    ),
    MessageCase(
      "RowDescription with a table column and a computed column",
      <<
        "T", 54:32, 2:16, "id":utf8, 0, 16_384:32, 1:16, 23:32, 4:16, -1:32,
        1:16, "?column?":utf8, 0, 0:32, 0:16, 1043:32, -1:16, 24:32, 0:16,
      >>,
      RowDescription([
        ResultColumn(
          column: ColumnDescription(
            name: "id",
            type_id: 23,
            type_modifier: -1,
            table_id: 16_384,
            column_number: 1,
          ),
          type_size: 4,
          format: BinaryFormat,
        ),
        ResultColumn(
          column: ColumnDescription(
            name: "?column?",
            type_id: 1043,
            type_modifier: 24,
            table_id: 0,
            column_number: 0,
          ),
          type_size: -1,
          format: TextFormat,
        ),
      ]),
    ),
    MessageCase(
      "RowDescription of a system column",
      <<
        "T",
        29:32,
        1:16,
        "ctid":utf8,
        0,
        16_384:32,
        -1:16,
        27:32,
        6:16,
        -1:32,
        0:16,
      >>,
      RowDescription([
        ResultColumn(
          column: ColumnDescription(
            name: "ctid",
            type_id: 27,
            type_modifier: -1,
            table_id: 16_384,
            column_number: -1,
          ),
          type_size: 6,
          format: TextFormat,
        ),
      ]),
    ),
    MessageCase(
      "DataRow with a value, a NULL and an empty value",
      <<"D", 20:32, 3:16, 2:32, "42":utf8, -1:32, 0:32>>,
      DataRow([Some(<<"42":utf8>>), None, Some(<<>>)]),
    ),
    MessageCase("DataRow with no columns", <<"D", 6:32, 0:16>>, DataRow([])),
    MessageCase(
      "FunctionCallResponse with a value",
      <<"V", 10:32, 2:32, "ok":utf8>>,
      FunctionCallResponse(Some(<<"ok":utf8>>)),
    ),
    MessageCase(
      "FunctionCallResponse with NULL",
      <<"V", 8:32, -1:32>>,
      FunctionCallResponse(None),
    ),
  ]
}

fn copy_cases() -> List(MessageCase) {
  [
    MessageCase(
      "CopyInResponse in text",
      <<"G", 11:32, 0, 2:16, 0:16, 0:16>>,
      CopyInResponse(TextFormat, [TextFormat, TextFormat]),
    ),
    MessageCase(
      "CopyOutResponse in binary",
      <<"H", 11:32, 1, 2:16, 1:16, 1:16>>,
      CopyOutResponse(BinaryFormat, [BinaryFormat, BinaryFormat]),
    ),
    MessageCase(
      "CopyBothResponse",
      <<"W", 7:32, 0, 0:16>>,
      CopyBothResponse(TextFormat, []),
    ),
    MessageCase(
      "CopyData",
      <<"d", 10:32, "1\tada\n":utf8>>,
      CopyDataFromServer(<<"1\tada\n":utf8>>),
    ),
    MessageCase("CopyDone", <<"c", 4:32>>, CopyDoneFromServer),
  ]
}

/// A report message: the type byte, the length, then each field as its
/// code byte, its value and a zero byte, then the zero byte that ends the
/// list.
fn report_message(type_byte: String, fields: List(#(String, String))) {
  let body =
    concat([
      concat(map(fields, fn(field) { <<field.0:utf8, field.1:utf8, 0>> })),
      <<0>>,
    ])
  <<type_byte:utf8, { byte_size(body) + 4 }:32, body:bits>>
}

fn report_cases() -> List(MessageCase) {
  [
    MessageCase(
      "ErrorResponse with every field and one of an unknown code",
      report_message("E", [
        #("S", "FEHLER"),
        #("V", "ERROR"),
        #("C", "23505"),
        #("M", "duplicate key"),
        #("D", "Key (id)=(1) already exists."),
        #("H", "Use another id."),
        #("P", "15"),
        #("p", "3"),
        #("q", "SELECT 1"),
        #("W", "SQL function f"),
        #("s", "public"),
        #("t", "users"),
        #("c", "id"),
        #("d", "int4"),
        #("n", "users_pkey"),
        #("F", "nbtinsert.c"),
        #("L", "666"),
        #("R", "_bt_check_unique"),
        #("X", "a field of a later version"),
      ]),
      ErrorResponse(
        ServerReport(
          severity: "ERROR",
          localized_severity: "FEHLER",
          code: "23505",
          message: "duplicate key",
          detail: Some("Key (id)=(1) already exists."),
          hint: Some("Use another id."),
          position: Some(15),
          internal_position: Some(3),
          internal_query: Some("SELECT 1"),
          context: Some("SQL function f"),
          schema: Some("public"),
          table: Some("users"),
          column: Some("id"),
          data_type: Some("int4"),
          constraint: Some("users_pkey"),
          file: Some("nbtinsert.c"),
          line: Some(666),
          routine: Some("_bt_check_unique"),
          other_fields: [#(88, "a field of a later version")],
        ),
      ),
    ),
    MessageCase(
      "NoticeResponse with the fields that are always there",
      report_message("N", [
        #("S", "NOTICE"),
        #("V", "NOTICE"),
        #("C", "00000"),
        #("M", "table t does not exist, skipping"),
      ]),
      NoticeResponse(
        minimal_report("NOTICE", "table t does not exist, skipping", []),
      ),
    ),
    MessageCase(
      "NoticeResponse with a field given two times",
      report_message("N", [
        #("S", "WARNING"),
        #("V", "WARNING"),
        #("C", "01000"),
        #("M", "first"),
        #("M", "second"),
      ]),
      NoticeResponse(
        ServerReport(
          ..minimal_report("WARNING", "first", [#(77, "second")]),
          code: "01000",
        ),
      ),
    ),
  ]
}

fn minimal_report(
  severity: String,
  text: String,
  other_fields: List(#(Int, String)),
) -> cell.ServerReport {
  ServerReport(
    severity:,
    localized_severity: severity,
    code: "00000",
    message: text,
    detail: None,
    hint: None,
    position: None,
    internal_position: None,
    internal_query: None,
    context: None,
    schema: None,
    table: None,
    column: None,
    data_type: None,
    constraint: None,
    file: None,
    line: None,
    routine: None,
    other_fields:,
  )
}

fn error_cases() -> List(ErrorCase) {
  flatten([frame_error_cases(), body_error_cases(), report_error_cases()])
}

fn frame_error_cases() -> List(ErrorCase) {
  [
    ErrorCase("an unknown message type", <<"x", 4:32>>, UnknownMessageType(120)),
    ErrorCase("a length below 4", <<"1", 3:32>>, InvalidMessageLength(49, 3)),
    ErrorCase("a negative length", <<"1", -1:32>>, InvalidMessageLength(49, -1)),
    ErrorCase(
      "a ParseComplete with a body",
      <<"1", 5:32, 0>>,
      InvalidMessageBody(49),
    ),
  ]
}

fn body_error_cases() -> List(ErrorCase) {
  [
    ErrorCase(
      "an Authentication message with an unknown code",
      <<"R", 8:32, 99:32>>,
      UnknownAuthenticationRequest(99),
    ),
    ErrorCase(
      "an AuthenticationOk with bytes after the code",
      <<"R", 9:32, 0:32, 0>>,
      InvalidMessageBody(82),
    ),
    ErrorCase(
      "an Authentication message shorter than its code",
      <<"R", 6:32, 0:16>>,
      InvalidMessageBody(82),
    ),
    ErrorCase(
      "an AuthenticationSASL whose list does not end",
      <<"R", 14:32, 10:32, "SCRAM":utf8, 0>>,
      InvalidMessageBody(82),
    ),
    ErrorCase(
      "a BackendKeyData key of 3 bytes",
      <<"K", 11:32, 1:32, 1, 2, 3>>,
      InvalidSecretKeyLength(3),
    ),
    ErrorCase(
      "a BackendKeyData key of 257 bytes",
      <<"K", 265:32, 1:32, 0:size(2056)>>,
      InvalidSecretKeyLength(257),
    ),
    ErrorCase(
      "a BackendKeyData shorter than a process ID",
      <<"K", 6:32, 1:16>>,
      InvalidMessageBody(75),
    ),
    ErrorCase(
      "a NegotiateProtocolVersion with fewer options than its count",
      <<"v", 12:32, 0:32, 2:32>>,
      InvalidMessageBody(118),
    ),
    ErrorCase(
      "a NegotiateProtocolVersion with bytes after its options",
      <<"v", 13:32, 0:32, 0:32, 0>>,
      InvalidMessageBody(118),
    ),
    ErrorCase(
      "a NegotiateProtocolVersion shorter than its counts",
      <<"v", 8:32, 0:32>>,
      InvalidMessageBody(118),
    ),
    ErrorCase(
      "a ReadyForQuery with an unknown status",
      <<"Z", 5:32, "X">>,
      UnknownTransactionStatus(88),
    ),
    ErrorCase(
      "a ReadyForQuery with two status bytes",
      <<"Z", 6:32, "II">>,
      InvalidMessageBody(90),
    ),
    ErrorCase(
      "a CommandComplete that is not UTF-8",
      <<"C", 6:32, 255, 0>>,
      InvalidUtf8(67),
    ),
    ErrorCase(
      "a CommandComplete without its zero byte",
      <<"C", 6:32, "OK":utf8>>,
      InvalidMessageBody(67),
    ),
    ErrorCase(
      "a ParameterDescription with fewer types than its count",
      <<"t", 10:32, 2:16, 23:32>>,
      InvalidMessageBody(116),
    ),
    ErrorCase(
      "a ParameterDescription without its count",
      <<"t", 5:32, 0>>,
      InvalidMessageBody(116),
    ),
    ErrorCase(
      "a RowDescription with an unknown format code",
      <<"T", 27:32, 1:16, "id":utf8, 0, 0:32, 0:16, 23:32, 4:16, -1:32, 2:16>>,
      UnknownFormatCode(84, 2),
    ),
    ErrorCase(
      "a RowDescription whose column ends early",
      <<"T", 13:32, 1:16, "id":utf8, 0, 0:32>>,
      InvalidMessageBody(84),
    ),
    ErrorCase(
      "a RowDescription without its count",
      <<"T", 5:32, 0>>,
      InvalidMessageBody(84),
    ),
    ErrorCase(
      "a DataRow with a length of -2",
      <<"D", 10:32, 1:16, -2:32>>,
      InvalidMessageBody(68),
    ),
    ErrorCase(
      "a DataRow without its count",
      <<"D", 5:32, 0>>,
      InvalidMessageBody(68),
    ),
    ErrorCase(
      "a FunctionCallResponse with bytes after its value",
      <<"V", 9:32, -1:32, 0>>,
      InvalidMessageBody(86),
    ),
    ErrorCase(
      "a CopyInResponse with an unknown overall format",
      <<"G", 7:32, 2, 0:16>>,
      UnknownFormatCode(71, 2),
    ),
    ErrorCase(
      "a CopyOutResponse with an unknown column format",
      <<"H", 9:32, 0, 1:16, 5:16>>,
      UnknownFormatCode(72, 5),
    ),
    ErrorCase(
      "a CopyInResponse with fewer formats than its count",
      <<"G", 9:32, 0, 2:16, 0:16>>,
      InvalidMessageBody(71),
    ),
    ErrorCase(
      "a CopyBothResponse without its count",
      <<"W", 5:32, 0>>,
      InvalidMessageBody(87),
    ),
    ErrorCase(
      "a NotificationResponse shorter than a process ID",
      <<"A", 6:32, 1:16>>,
      InvalidMessageBody(65),
    ),
    ErrorCase(
      "a ParameterStatus without a value",
      <<"S", 9:32, "name":utf8, 0>>,
      InvalidMessageBody(83),
    ),
  ]
}

fn report_error_cases() -> List(ErrorCase) {
  [
    ErrorCase(
      "an ErrorResponse without its severity",
      report_message("E", [#("S", "ERROR"), #("C", "XX000"), #("M", "m")]),
      MissingReportField(69, 86),
    ),
    ErrorCase(
      "an ErrorResponse without its localized severity",
      report_message("E", [#("V", "ERROR"), #("C", "XX000"), #("M", "m")]),
      MissingReportField(69, 83),
    ),
    ErrorCase(
      "an ErrorResponse without its SQLSTATE",
      report_message("E", [#("S", "ERROR"), #("V", "ERROR"), #("M", "m")]),
      MissingReportField(69, 67),
    ),
    ErrorCase(
      "a NoticeResponse without its message",
      report_message("N", [#("S", "NOTICE"), #("V", "NOTICE"), #("C", "00000")]),
      MissingReportField(78, 77),
    ),
    ErrorCase(
      "an ErrorResponse with a position that is not a number",
      report_message("E", [
        #("S", "ERROR"),
        #("V", "ERROR"),
        #("C", "42601"),
        #("M", "syntax error"),
        #("P", "near"),
      ]),
      InvalidReportNumber(69, 80, "near"),
    ),
    ErrorCase(
      "an ErrorResponse whose field list does not end",
      <<"E", 11:32, "S":utf8, "ERROR":utf8, 0>>,
      InvalidMessageBody(69),
    ),
  ]
}

fn answer_tests() {
  [
    it("reads S to an SSLRequest as accepted", fn() {
      // Act
      let step = decode_ssl_answer(<<"S">>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(EncryptionAccepted, <<>>))
      |> or_fail_with("Expected EncryptionAccepted")
    }),
    it("keeps the bytes after an S, which a client must refuse", fn() {
      // Act
      let step = decode_ssl_answer(<<"S", 1, 2>>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(EncryptionAccepted, <<1, 2>>))
      |> or_fail_with("Expected EncryptionAccepted and the bytes 1 and 2")
    }),
    it("reads N as refused", fn() {
      // Act
      let step = decode_ssl_answer(<<"N">>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(EncryptionRefused, <<>>))
      |> or_fail_with("Expected EncryptionRefused")
    }),
    it("reads E as an ErrorResponse and keeps no text", fn() {
      // Act
      let step = decode_ssl_answer(<<"E", 0, 0, 0, 9>>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(EncryptionErrorResponse, <<0, 0, 0, 9>>))
      |> or_fail_with("Expected EncryptionErrorResponse")
    }),
    it("needs more bytes when no byte came yet", fn() {
      // Act
      let step = decode_ssl_answer(<<>>)

      // Assert
      step
      |> should
      |> be_equal(NeedMoreBytes)
      |> or_fail_with("Expected NeedMoreBytes")
    }),
    it("reads G to an SSLRequest as an unknown answer", fn() {
      // Act
      let step = decode_ssl_answer(<<"G">>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(UnknownAnswer(71), <<>>))
      |> or_fail_with("Expected UnknownAnswer(71)")
    }),
    it("reads G to a GSSENCRequest as accepted", fn() {
      // Act
      let step = decode_gss_encryption_answer(<<"G">>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(EncryptionAccepted, <<>>))
      |> or_fail_with("Expected EncryptionAccepted")
    }),
    it("reads S to a GSSENCRequest as an unknown answer", fn() {
      // Act
      let step = decode_gss_encryption_answer(<<"S">>)

      // Assert
      step
      |> should
      |> be_equal(Decoded(UnknownAnswer(83), <<>>))
      |> or_fail_with("Expected UnknownAnswer(83)")
    }),
  ]
}
