//// Reads the bytes that PostgreSQL sends as messages.
////
//// Each function here is pure: it reads the bytes it gets and touches no
//// socket. Each layout is the one of the PostgreSQL documentation, chapter
//// "Frontend/Backend Protocol", section "Message Formats".
////
//// The bytes can end anywhere. When they end inside a message, the answer
//// is `NeedMoreBytes`, never an error: read more bytes and call the
//// function again with all of them. A whole message that does not have the
//// layout of its type is a `ProtocolError`.
////
//// NegotiateProtocolVersion: the docs call its first field the newest
//// minor version, but PostgreSQL 16.16, 17.12, 18.7 and 19.0 all send the
//// whole version number (196608 for 3.0, 196610 for 3.2), as the
//// recordings in `test/driver/recorded` show. The decoder reads the field
//// as a 16-bit major and a 16-bit minor version. Do not change it to match
//// the docs.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/message.{
  type BackendMessage, type DecodeStep, type EncryptionAnswer,
  type ProtocolError, type ResultColumn, AuthenticationCleartextPassword,
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
import dream_postgres/internal/cell.{
  type Format, type ParameterDescription, type ServerReport,
  type TransactionStatus, BinaryFormat, ColumnDescription, Idle,
  InFailedTransaction, InTransaction, ServerReport, TextFormat,
}
import gleam/bit_array.{to_string}
import gleam/bool.{guard}
import gleam/int.{parse}
import gleam/list.{contains, fold, key_find, reverse, try_map}
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result.{map, replace_error, try}
import gleam/set.{type Set}

/// The request codes of the Authentication messages that the protocol
/// defines.
const authentication_codes = [0, 2, 3, 5, 7, 8, 9, 10, 11, 12]

// The type bytes of the messages whose decoders name them in errors.
const authentication_byte = 82

const backend_key_data_byte = 75

const negotiate_protocol_version_byte = 118

const ready_for_query_byte = 90

const parameter_description_byte = 116

const row_description_byte = 84

const data_row_byte = 68

const function_call_response_byte = 86

const parameter_status_byte = 83

const notification_response_byte = 65

// The field codes of an ErrorResponse or a NoticeResponse (PostgreSQL
// documentation, "Error and Notice Message Fields").
const localized_severity_code = 83

const severity_code = 86

const sqlstate_code = 67

const message_code = 77

const detail_code = 68

const hint_code = 72

const position_code = 80

const internal_position_code = 112

const internal_query_code = 113

const context_code = 87

const schema_code = 115

const table_code = 116

const column_code = 99

const data_type_code = 100

const constraint_code = 110

const file_code = 70

const line_code = 76

const routine_code = 82

/// The report fields that `ServerReport` has a field of its own for.
const named_report_fields = [
  localized_severity_code, severity_code, sqlstate_code, message_code,
  detail_code, hint_code, position_code, internal_position_code,
  internal_query_code, context_code, schema_code, table_code, column_code,
  data_type_code, constraint_code, file_code, line_code, routine_code,
]

/// Reads the first message of the bytes from the server.
///
/// ## Parameters
///
/// - `bytes`: the bytes read so far, from the start of a message
///
/// ## Returns
///
/// - `Ok(Decoded(message, rest))`: the first message, and the bytes after
///   it
/// - `Ok(NeedMoreBytes)`: the bytes end inside the first message
/// - `Error(ProtocolError)`: the first message is not valid
pub fn decode_backend(
  bytes: BitArray,
) -> Result(DecodeStep(BackendMessage), ProtocolError) {
  case bytes {
    <<type_byte, length:32-signed, after_length:bytes>> ->
      split_message(type_byte, length, after_length)
    _ -> Ok(NeedMoreBytes)
  }
}

/// Reads the answer to an SslRequest: `S`, `N`, `E` or another byte.
///
/// ## Parameters
///
/// - `bytes`: the bytes read so far after the SslRequest
///
/// ## Returns
///
/// - `Decoded(answer, rest)`: the answer, and the bytes after it
/// - `NeedMoreBytes`: no byte yet
pub fn decode_ssl_answer(bytes: BitArray) -> DecodeStep(EncryptionAnswer) {
  encryption_answer(bytes, "S")
}

/// Reads the answer to a GssEncryptionRequest: `G`, `N`, `E` or another
/// byte.
///
/// ## Parameters
///
/// - `bytes`: the bytes read so far after the GssEncryptionRequest
///
/// ## Returns
///
/// - `Decoded(answer, rest)`: the answer, and the bytes after it
/// - `NeedMoreBytes`: no byte yet
pub fn decode_gss_encryption_answer(
  bytes: BitArray,
) -> DecodeStep(EncryptionAnswer) {
  encryption_answer(bytes, "G")
}

fn encryption_answer(
  bytes: BitArray,
  accept_byte: String,
) -> DecodeStep(EncryptionAnswer) {
  case bytes {
    <<"N", rest:bytes>> -> Decoded(EncryptionRefused, rest)
    <<"E", rest:bytes>> -> Decoded(EncryptionErrorResponse, rest)
    <<answer, rest:bytes>> ->
      Decoded(accepted_answer(answer, accept_byte), rest)
    _ -> NeedMoreBytes
  }
}

fn accepted_answer(answer: Int, accept_byte: String) -> EncryptionAnswer {
  case <<answer>> == <<accept_byte:utf8>> {
    True -> EncryptionAccepted
    False -> UnknownAnswer(answer)
  }
}

fn split_message(
  type_byte: Int,
  length: Int,
  after_length: BitArray,
) -> Result(DecodeStep(BackendMessage), ProtocolError) {
  use <- guard(length < 4, Error(InvalidMessageLength(type_byte, length)))
  case after_length {
    <<body:bytes-size(length - 4), rest:bytes>> ->
      decode_body(type_byte, body) |> map(Decoded(_, rest))
    _ -> Ok(NeedMoreBytes)
  }
}

fn decode_body(
  type_byte: Int,
  body: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  case <<type_byte>> {
    <<"R">> -> authentication(body)
    <<"K">> -> backend_key_data(body)
    <<"2">> -> no_body(body, type_byte, BindComplete)
    <<"3">> -> no_body(body, type_byte, CloseComplete)
    <<"C">> -> one_string(body, type_byte) |> map(CommandComplete)
    <<"d">> -> Ok(CopyDataFromServer(body))
    <<"c">> -> no_body(body, type_byte, CopyDoneFromServer)
    <<"G">> -> copy_response(body, type_byte, CopyInResponse)
    <<"H">> -> copy_response(body, type_byte, CopyOutResponse)
    <<"W">> -> copy_response(body, type_byte, CopyBothResponse)
    <<"D">> -> data_row(body)
    <<"I">> -> no_body(body, type_byte, EmptyQueryResponse)
    <<"E">> -> server_report(body, type_byte) |> map(ErrorResponse)
    <<"V">> -> function_call_response(body)
    <<"v">> -> negotiate_protocol_version(body)
    <<"n">> -> no_body(body, type_byte, NoData)
    <<"N">> -> server_report(body, type_byte) |> map(NoticeResponse)
    <<"A">> -> notification_response(body)
    <<"t">> -> parameter_descriptions(body)
    <<"S">> -> parameter_status(body)
    <<"1">> -> no_body(body, type_byte, ParseComplete)
    <<"s">> -> no_body(body, type_byte, PortalSuspended)
    <<"Z">> -> ready_for_query(body)
    <<"T">> -> row_description(body)
    _ -> Error(UnknownMessageType(type_byte))
  }
}

// Authentication ------------------------------------------------------------

fn authentication(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<0:32>> -> Ok(AuthenticationOk)
    <<2:32>> -> Ok(AuthenticationKerberosV5)
    <<3:32>> -> Ok(AuthenticationCleartextPassword)
    <<5:32, salt:bytes-size(4)>> -> Ok(AuthenticationMd5Password(salt))
    <<7:32>> -> Ok(AuthenticationGss)
    <<8:32, data:bytes>> -> Ok(AuthenticationGssContinue(data))
    <<9:32>> -> Ok(AuthenticationSspi)
    <<10:32, names:bytes>> ->
      string_list(names, authentication_byte, []) |> map(AuthenticationSasl)
    <<11:32, data:bytes>> -> Ok(AuthenticationSaslContinue(data))
    <<12:32, data:bytes>> -> Ok(AuthenticationSaslFinal(data))
    <<code:32, _:bytes>> -> unknown_authentication(code)
    _ -> Error(InvalidMessageBody(authentication_byte))
  }
}

/// A code that the protocol defines but with the wrong body is an invalid
/// body. Any other code is a request that the protocol does not define.
fn unknown_authentication(code: Int) -> Result(BackendMessage, ProtocolError) {
  use <- guard(contains(authentication_codes, code), {
    Error(InvalidMessageBody(authentication_byte))
  })
  Error(UnknownAuthenticationRequest(code))
}

fn backend_key_data(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<process_id:32, secret_key:bytes>> ->
      secret_key_message(process_id, secret_key)
    _ -> Error(InvalidMessageBody(backend_key_data_byte))
  }
}

fn secret_key_message(
  process_id: Int,
  secret_key: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  let length = bit_array.byte_size(secret_key)
  use <- guard(length < 4 || length > 256, {
    Error(InvalidSecretKeyLength(length))
  })
  Ok(BackendKeyData(process_id:, secret_key:))
}

fn negotiate_protocol_version(
  body: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<major:16, minor:16, count:32, names:bytes>> -> {
      use #(options, rest) <- try(
        strings(names, count, negotiate_protocol_version_byte, []),
      )
      end_of_body(
        NegotiateProtocolVersion(major, minor, options),
        rest,
        negotiate_protocol_version_byte,
      )
    }
    _ -> Error(InvalidMessageBody(negotiate_protocol_version_byte))
  }
}

// Queries --------------------------------------------------------------------

fn ready_for_query(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<status>> -> transaction_status(status) |> map(ReadyForQuery)
    _ -> Error(InvalidMessageBody(ready_for_query_byte))
  }
}

fn transaction_status(status: Int) -> Result(TransactionStatus, ProtocolError) {
  case <<status>> {
    <<"I">> -> Ok(Idle)
    <<"T">> -> Ok(InTransaction)
    <<"E">> -> Ok(InFailedTransaction)
    _ -> Error(UnknownTransactionStatus(status))
  }
}

fn parameter_descriptions(
  body: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<count:16, type_ids:bytes>> -> {
      use #(parameters, rest) <- try(parameter_types(type_ids, count, []))
      end_of_body(
        ParameterDescriptions(parameters),
        rest,
        parameter_description_byte,
      )
    }
    _ -> Error(InvalidMessageBody(parameter_description_byte))
  }
}

fn parameter_types(
  bytes: BitArray,
  count: Int,
  collected: List(ParameterDescription),
) -> Result(#(List(ParameterDescription), BitArray), ProtocolError) {
  use <- guard(count == 0, Ok(#(reverse(collected), bytes)))
  case bytes {
    <<type_id:32, rest:bytes>> ->
      parameter_types(rest, count - 1, [
        cell.ParameterDescription(type_id),
        ..collected
      ])
    _ -> Error(InvalidMessageBody(parameter_description_byte))
  }
}

fn row_description(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<count:16, fields:bytes>> -> {
      use #(columns, rest) <- try(result_columns(fields, count, []))
      end_of_body(RowDescription(columns), rest, row_description_byte)
    }
    _ -> Error(InvalidMessageBody(row_description_byte))
  }
}

fn result_columns(
  bytes: BitArray,
  count: Int,
  collected: List(ResultColumn),
) -> Result(#(List(ResultColumn), BitArray), ProtocolError) {
  use <- guard(count == 0, Ok(#(reverse(collected), bytes)))
  use #(name, after_name) <- try(take_string(bytes, row_description_byte))
  use #(column, rest) <- try(result_column(name, after_name))
  result_columns(rest, count - 1, [column, ..collected])
}

fn result_column(
  name: String,
  bytes: BitArray,
) -> Result(#(ResultColumn, BitArray), ProtocolError) {
  case bytes {
    <<
      table_id:32,
      column_number:16-signed,
      type_id:32,
      type_size:16-signed,
      type_modifier:32-signed,
      format_code:16,
      rest:bytes,
    >> -> {
      use format <- try(format_from_code(format_code, row_description_byte))
      let column =
        ColumnDescription(
          name:,
          type_id:,
          type_modifier:,
          table_id:,
          column_number:,
        )
      Ok(#(ResultColumn(column:, type_size:, format:), rest))
    }
    _ -> Error(InvalidMessageBody(row_description_byte))
  }
}

fn data_row(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<count:16, cells:bytes>> -> {
      use #(values, rest) <- try(values(cells, count, data_row_byte, []))
      end_of_body(DataRow(values), rest, data_row_byte)
    }
    _ -> Error(InvalidMessageBody(data_row_byte))
  }
}

fn function_call_response(
  body: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  use #(value, rest) <- try(one_value(body, function_call_response_byte))
  end_of_body(FunctionCallResponse(value), rest, function_call_response_byte)
}

/// Reads `count` values, each a 32-bit length and that many bytes, or the
/// length -1 for NULL.
fn values(
  bytes: BitArray,
  count: Int,
  type_byte: Int,
  collected: List(Option(BitArray)),
) -> Result(#(List(Option(BitArray)), BitArray), ProtocolError) {
  use <- guard(count == 0, Ok(#(reverse(collected), bytes)))
  use #(value, rest) <- try(one_value(bytes, type_byte))
  values(rest, count - 1, type_byte, [value, ..collected])
}

fn one_value(
  bytes: BitArray,
  type_byte: Int,
) -> Result(#(Option(BitArray), BitArray), ProtocolError) {
  case bytes {
    <<-1:32-signed, rest:bytes>> -> Ok(#(None, rest))
    <<length:32-signed, value:bytes-size(length), rest:bytes>> if length >= 0 ->
      Ok(#(Some(value), rest))
    _ -> Error(InvalidMessageBody(type_byte))
  }
}

fn copy_response(
  body: BitArray,
  type_byte: Int,
  message: fn(Format, List(Format)) -> BackendMessage,
) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<format_code:8, count:16, codes:bytes>> -> {
      use format <- try(format_from_code(format_code, type_byte))
      use #(column_codes, rest) <- try(int16_list(codes, count, type_byte, []))
      use formats <- try(try_map(column_codes, format_from_code(_, type_byte)))
      end_of_body(message(format, formats), rest, type_byte)
    }
    _ -> Error(InvalidMessageBody(type_byte))
  }
}

fn int16_list(
  bytes: BitArray,
  count: Int,
  type_byte: Int,
  collected: List(Int),
) -> Result(#(List(Int), BitArray), ProtocolError) {
  use <- guard(count == 0, Ok(#(reverse(collected), bytes)))
  case bytes {
    <<code:16, rest:bytes>> ->
      int16_list(rest, count - 1, type_byte, [code, ..collected])
    _ -> Error(InvalidMessageBody(type_byte))
  }
}

fn format_from_code(
  code: Int,
  type_byte: Int,
) -> Result(Format, ProtocolError) {
  case code {
    0 -> Ok(TextFormat)
    1 -> Ok(BinaryFormat)
    _ -> Error(UnknownFormatCode(type_byte, code))
  }
}

// Status, notifications and reports ------------------------------------------

fn parameter_status(body: BitArray) -> Result(BackendMessage, ProtocolError) {
  use #(name, after_name) <- try(take_string(body, parameter_status_byte))
  use #(value, rest) <- try(take_string(after_name, parameter_status_byte))
  end_of_body(ParameterStatus(name, value), rest, parameter_status_byte)
}

fn notification_response(
  body: BitArray,
) -> Result(BackendMessage, ProtocolError) {
  case body {
    <<process_id:32, strings:bytes>> -> {
      use #(channel, after_channel) <- try(take_string(
        strings,
        notification_response_byte,
      ))
      use #(payload, rest) <- try(take_string(
        after_channel,
        notification_response_byte,
      ))
      end_of_body(
        NotificationResponse(process_id, channel, payload),
        rest,
        notification_response_byte,
      )
    }
    _ -> Error(InvalidMessageBody(notification_response_byte))
  }
}

/// Reads the fields of an ErrorResponse or a NoticeResponse.
fn server_report(
  body: BitArray,
  type_byte: Int,
) -> Result(ServerReport, ProtocolError) {
  use fields <- try(report_fields(body, type_byte, []))
  use severity <- try(required_field(fields, severity_code, type_byte))
  use localized_severity <- try(required_field(
    fields,
    localized_severity_code,
    type_byte,
  ))
  use code <- try(required_field(fields, sqlstate_code, type_byte))
  use message <- try(required_field(fields, message_code, type_byte))
  use position <- try(number_field(fields, position_code, type_byte))
  use internal_position <- try(number_field(
    fields,
    internal_position_code,
    type_byte,
  ))
  use line <- try(number_field(fields, line_code, type_byte))
  Ok(ServerReport(
    severity:,
    localized_severity:,
    code:,
    message:,
    detail: optional_field(fields, detail_code),
    hint: optional_field(fields, hint_code),
    position:,
    internal_position:,
    internal_query: optional_field(fields, internal_query_code),
    context: optional_field(fields, context_code),
    schema: optional_field(fields, schema_code),
    table: optional_field(fields, table_code),
    column: optional_field(fields, column_code),
    data_type: optional_field(fields, data_type_code),
    constraint: optional_field(fields, constraint_code),
    file: optional_field(fields, file_code),
    line:,
    routine: optional_field(fields, routine_code),
    other_fields: other_fields(fields),
  ))
}

/// The fields in the order the server sent them: each code byte and its
/// value.
fn report_fields(
  bytes: BitArray,
  type_byte: Int,
  collected: List(#(Int, String)),
) -> Result(List(#(Int, String)), ProtocolError) {
  case bytes {
    <<0>> -> Ok(reverse(collected))
    <<code, after_code:bytes>> if code != 0 -> {
      use #(value, rest) <- try(take_string(after_code, type_byte))
      report_fields(rest, type_byte, [#(code, value), ..collected])
    }
    _ -> Error(InvalidMessageBody(type_byte))
  }
}

fn required_field(
  fields: List(#(Int, String)),
  code: Int,
  type_byte: Int,
) -> Result(String, ProtocolError) {
  key_find(fields, code)
  |> replace_error(MissingReportField(type_byte, code))
}

fn optional_field(fields: List(#(Int, String)), code: Int) -> Option(String) {
  key_find(fields, code) |> option.from_result
}

fn number_field(
  fields: List(#(Int, String)),
  code: Int,
  type_byte: Int,
) -> Result(Option(Int), ProtocolError) {
  case key_find(fields, code) {
    Ok(text) -> parse_number(text, code, type_byte)
    Error(Nil) -> Ok(None)
  }
}

fn parse_number(
  text: String,
  code: Int,
  type_byte: Int,
) -> Result(Option(Int), ProtocolError) {
  parse(text)
  |> map(Some)
  |> replace_error(InvalidReportNumber(type_byte, code, text))
}

/// The fields that `ServerReport` has no field of its own for: each field
/// of an unknown code, and each repeat of a known code after its first.
fn other_fields(fields: List(#(Int, String))) -> List(#(Int, String)) {
  let #(_seen, kept) = fold(fields, #(set.new(), []), keep_other_field)
  reverse(kept)
}

fn keep_other_field(
  state: #(Set(Int), List(#(Int, String))),
  field: #(Int, String),
) -> #(Set(Int), List(#(Int, String))) {
  let #(seen, kept) = state
  let #(code, _value) = field
  let first_named =
    contains(named_report_fields, code) && !set.contains(seen, code)
  use <- guard(first_named, #(set.insert(seen, code), kept))
  #(seen, [field, ..kept])
}

// Strings ---------------------------------------------------------------------

/// Reads a string list that a zero byte ends, as in AuthenticationSASL.
fn string_list(
  bytes: BitArray,
  type_byte: Int,
  collected: List(String),
) -> Result(List(String), ProtocolError) {
  case bytes {
    <<0>> -> Ok(reverse(collected))
    _ -> {
      use #(text, rest) <- try(take_string(bytes, type_byte))
      string_list(rest, type_byte, [text, ..collected])
    }
  }
}

/// Reads `count` strings.
fn strings(
  bytes: BitArray,
  count: Int,
  type_byte: Int,
  collected: List(String),
) -> Result(#(List(String), BitArray), ProtocolError) {
  use <- guard(count == 0, Ok(#(reverse(collected), bytes)))
  use #(text, rest) <- try(take_string(bytes, type_byte))
  strings(rest, count - 1, type_byte, [text, ..collected])
}

fn one_string(body: BitArray, type_byte: Int) -> Result(String, ProtocolError) {
  use #(text, rest) <- try(take_string(body, type_byte))
  end_of_body(text, rest, type_byte)
}

/// Reads a string that a zero byte ends, and gives the bytes after it.
fn take_string(
  bytes: BitArray,
  type_byte: Int,
) -> Result(#(String, BitArray), ProtocolError) {
  find_zero_byte(bytes, 0, type_byte)
}

fn find_zero_byte(
  bytes: BitArray,
  offset: Int,
  type_byte: Int,
) -> Result(#(String, BitArray), ProtocolError) {
  case bytes {
    <<text:bytes-size(offset), 0, rest:bytes>> ->
      utf8_string(text, rest, type_byte)
    <<_:bytes-size(offset), _, _:bytes>> ->
      find_zero_byte(bytes, offset + 1, type_byte)
    _ -> Error(InvalidMessageBody(type_byte))
  }
}

fn utf8_string(
  text: BitArray,
  rest: BitArray,
  type_byte: Int,
) -> Result(#(String, BitArray), ProtocolError) {
  to_string(text)
  |> map(pair.new(_, rest))
  |> replace_error(InvalidUtf8(type_byte))
}

// Endings ---------------------------------------------------------------------

fn no_body(
  body: BitArray,
  type_byte: Int,
  message: BackendMessage,
) -> Result(BackendMessage, ProtocolError) {
  end_of_body(message, body, type_byte)
}

/// The value, when no bytes are left after the last field of the body.
fn end_of_body(
  value: value,
  rest: BitArray,
  type_byte: Int,
) -> Result(value, ProtocolError) {
  case rest {
    <<>> -> Ok(value)
    _ -> Error(InvalidMessageBody(type_byte))
  }
}
