//// Writes the messages that the client sends to PostgreSQL as bytes.
////
//// `encode` is a pure function: it gives the bytes of one message and
//// touches no socket. Each layout is the one of the PostgreSQL
//// documentation, chapter "Frontend/Backend Protocol", section "Message
//// Formats". A value that the layout cannot hold, such as a zero byte in a
//// string or a 70000-item list, is an `EncodeError`, never a wrong message.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/message.{
  type EncodeError, type FrontendMessage, type ProtocolVersion, type Target,
  Bind, CancelRequest, Close, CopyData, CopyDone, CopyFail, Describe,
  DuplicateStartupParameter, Execute, Flush, FunctionCall, GssEncryptionRequest,
  GssResponse, MessageTooLong, NumberOutOfRange, Parse, PasswordMessage, Portal,
  Protocol30, Protocol32, Query, SaslInitialResponse, SaslResponse,
  SecretKeyLengthOutOfRange, SslRequest, StartupMessage, Statement, Sync,
  Terminate, TooManyItems, ZeroByteInString,
}
import dream_postgres/internal/cell.{
  type Cell, type Format, Binary, BinaryFormat, Null, Text, TextFormat,
}
import gleam/bit_array.{byte_size}
import gleam/bool.{guard}
import gleam/list.{length, try_fold, try_map}
import gleam/option.{type Option, None, Some}
import gleam/result.{map, try}
import gleam/set.{type Set}
import gleam/string.{contains}

/// The largest count that a 16-bit count field holds.
const largest_count = 65_535

/// The largest length that a 32-bit length field holds.
const largest_length = 2_147_483_647

/// The largest unsigned 32-bit number: the largest object ID.
const largest_unsigned_32 = 4_294_967_295

/// The request code of an SslRequest: 1234 and 5679 in two 16-bit halves.
const ssl_request_code = 80_877_103

/// The request code of a GssEncryptionRequest: 1234 and 5680.
const gss_encryption_request_code = 80_877_104

/// The request code of a CancelRequest: 1234 and 5678.
const cancel_request_code = 80_877_102

/// Writes one frontend message as the bytes to send.
///
/// ## Parameters
///
/// - `message`: the message to write
///
/// ## Returns
///
/// - `Ok(bytes)`: the whole message, with its type byte and its length
/// - `Error(EncodeError)`: a field holds a value that its wire layout cannot
///   hold
pub fn encode(message: FrontendMessage) -> Result(BitArray, EncodeError) {
  case message {
    StartupMessage(version:, user:, parameters:) ->
      startup_message(version, user, parameters)
    SslRequest -> Ok(ssl_request())
    GssEncryptionRequest -> Ok(<<8:32, gss_encryption_request_code:32>>)
    CancelRequest(process_id:, secret_key:) ->
      cancel_request(process_id, secret_key)
    PasswordMessage(password:) -> string_message("p", "password", password)
    SaslInitialResponse(mechanism:, data:) ->
      sasl_initial_response(mechanism, data)
    SaslResponse(data:) -> framed(data, "p")
    GssResponse(data:) -> framed(data, "p")
    Parse(statement:, query:, parameter_type_ids:) ->
      parse(statement, query, parameter_type_ids)
    Bind(portal:, statement:, parameters:, result_formats:) ->
      bind(portal, statement, parameters, result_formats)
    Describe(target:) -> target_message("D", target)
    Execute(portal:, row_limit:) -> execute(portal, row_limit)
    Sync -> Ok(<<"S", 4:32>>)
    Flush -> Ok(<<"H", 4:32>>)
    Close(target:) -> target_message("C", target)
    Query(query:) -> string_message("Q", "query", query)
    FunctionCall(function_id:, arguments:, result_format:) ->
      function_call(function_id, arguments, result_format)
    CopyData(data:) -> framed(data, "d")
    CopyDone -> Ok(<<"c", 4:32>>)
    CopyFail(message:) -> string_message("f", "message", message)
    Terminate -> Ok(<<"X", 4:32>>)
  }
}

/// The bytes of an SSLRequest. It has no field, so it cannot fail, and the
/// transport sends it without a `Result`.
///
/// ## Returns
///
/// The eight bytes of the SSLRequest.
pub fn ssl_request() -> BitArray {
  <<8:32, ssl_request_code:32>>
}

fn startup_message(
  version: ProtocolVersion,
  user: String,
  parameters: List(#(String, String)),
) -> Result(BitArray, EncodeError) {
  use _names <- try(try_fold(parameters, set.new(), check_parameter_name))
  use user_pair <- try(startup_parameter(#("user", user)))
  use pairs <- try(try_map(parameters, startup_parameter))
  let body = <<
    version_code(version):32,
    user_pair:bits,
    bit_array.concat(pairs):bits,
    0,
  >>
  unframed(body)
}

fn version_code(version: ProtocolVersion) -> Int {
  case version {
    Protocol30 -> 196_608
    Protocol32 -> 196_610
  }
}

fn check_parameter_name(
  seen: Set(String),
  parameter: #(String, String),
) -> Result(Set(String), EncodeError) {
  let name = parameter.0
  let repeated = name == "user" || set.contains(seen, name)
  use <- guard(repeated, Error(DuplicateStartupParameter(name)))
  Ok(set.insert(seen, name))
}

fn startup_parameter(
  parameter: #(String, String),
) -> Result(BitArray, EncodeError) {
  use name <- try(string_field("startup parameter name", parameter.0))
  use value <- try(string_field("startup parameter value", parameter.1))
  Ok(<<name:bits, value:bits>>)
}

fn cancel_request(
  process_id: Int,
  secret_key: BitArray,
) -> Result(BitArray, EncodeError) {
  use process <- try(unsigned_32("process_id", process_id))
  let key_length = byte_size(secret_key)
  let wrong_length = key_length < 4 || key_length > 256
  use <- guard(wrong_length, Error(SecretKeyLengthOutOfRange(key_length)))
  unframed(<<cancel_request_code:32, process:bits, secret_key:bits>>)
}

fn sasl_initial_response(
  mechanism: String,
  data: Option(BitArray),
) -> Result(BitArray, EncodeError) {
  use name <- try(string_field("mechanism", mechanism))
  use value <- try(optional_value(data))
  framed(<<name:bits, value:bits>>, "p")
}

fn parse(
  statement: String,
  query: String,
  parameter_type_ids: List(Int),
) -> Result(BitArray, EncodeError) {
  use name <- try(string_field("statement", statement))
  use text <- try(string_field("query", query))
  use count <- try(count_field("parameter_type_ids", parameter_type_ids))
  use type_ids <- try(try_map(parameter_type_ids, object_id))
  framed(
    <<name:bits, text:bits, count:bits, bit_array.concat(type_ids):bits>>,
    "P",
  )
}

fn bind(
  portal: String,
  statement: String,
  parameters: List(Cell),
  result_formats: List(Format),
) -> Result(BitArray, EncodeError) {
  use portal_name <- try(string_field("portal", portal))
  use statement_name <- try(string_field("statement", statement))
  use values <- try(cells("parameters", parameters))
  use formats <- try(format_codes("result_formats", result_formats))
  framed(
    <<portal_name:bits, statement_name:bits, values:bits, formats:bits>>,
    "B",
  )
}

fn function_call(
  function_id: Int,
  arguments: List(Cell),
  result_format: Format,
) -> Result(BitArray, EncodeError) {
  use function <- try(object_id(function_id))
  use values <- try(cells("arguments", arguments))
  framed(<<function:bits, values:bits, format_code(result_format):16>>, "F")
}

/// The format codes of the cells, one for each, then their count and their
/// values: the layout that Bind and FunctionCall share.
fn cells(field: String, values: List(Cell)) -> Result(BitArray, EncodeError) {
  use count <- try(count_field(field, values))
  use bodies <- try(try_map(values, cell_value))
  let codes = list.map(values, cell_format_code)
  Ok(<<
    count:bits,
    bit_array.concat(codes):bits,
    count:bits,
    bit_array.concat(bodies):bits,
  >>)
}

fn cell_format_code(value: Cell) -> BitArray {
  case value {
    Binary(_) -> <<1:16>>
    Text(_) | Null -> <<0:16>>
  }
}

fn cell_value(value: Cell) -> Result(BitArray, EncodeError) {
  case value {
    Binary(bytes:) | Text(bytes:) -> optional_value(Some(bytes))
    Null -> optional_value(None)
  }
}

/// A value with its 32-bit length, or the length -1 for NULL.
fn optional_value(value: Option(BitArray)) -> Result(BitArray, EncodeError) {
  case value {
    Some(bytes) -> {
      use size <- map(length_field(byte_size(bytes)))
      <<size:bits, bytes:bits>>
    }
    None -> Ok(<<-1:32>>)
  }
}

fn format_codes(
  field: String,
  formats: List(Format),
) -> Result(BitArray, EncodeError) {
  use count <- map(count_field(field, formats))
  let codes = list.map(formats, format_code_bytes)
  <<count:bits, bit_array.concat(codes):bits>>
}

fn format_code_bytes(format: Format) -> BitArray {
  <<format_code(format):16>>
}

fn format_code(format: Format) -> Int {
  case format {
    TextFormat -> 0
    BinaryFormat -> 1
  }
}

fn target_message(
  type_byte: String,
  target: Target,
) -> Result(BitArray, EncodeError) {
  let #(kind, field, name) = case target {
    Statement(name:) -> #("S", "statement", name)
    Portal(name:) -> #("P", "portal", name)
  }
  use name_field <- try(string_field(field, name))
  framed(<<kind:utf8, name_field:bits>>, type_byte)
}

fn execute(portal: String, row_limit: Int) -> Result(BitArray, EncodeError) {
  use name <- try(string_field("portal", portal))
  let wrong_limit = row_limit < 0 || row_limit > largest_length
  use <- guard(wrong_limit, Error(NumberOutOfRange("row_limit", row_limit)))
  framed(<<name:bits, row_limit:32>>, "E")
}

fn string_message(
  type_byte: String,
  field: String,
  text: String,
) -> Result(BitArray, EncodeError) {
  use body <- try(string_field(field, text))
  framed(body, type_byte)
}

/// A string as the protocol writes it: its UTF-8 bytes and a zero byte.
fn string_field(field: String, text: String) -> Result(BitArray, EncodeError) {
  use <- guard(contains(text, "\u{0000}"), Error(ZeroByteInString(field)))
  Ok(<<text:utf8, 0>>)
}

fn count_field(field: String, items: List(a)) -> Result(BitArray, EncodeError) {
  let count = length(items)
  use <- guard(count > largest_count, Error(TooManyItems(field, count)))
  Ok(<<count:16>>)
}

fn object_id(id: Int) -> Result(BitArray, EncodeError) {
  unsigned_32("object id", id)
}

fn unsigned_32(field: String, value: Int) -> Result(BitArray, EncodeError) {
  let out_of_range = value < 0 || value > largest_unsigned_32
  use <- guard(out_of_range, Error(NumberOutOfRange(field, value)))
  Ok(<<value:32>>)
}

/// A message with a type byte: the byte, the length, the body.
fn framed(body: BitArray, type_byte: String) -> Result(BitArray, EncodeError) {
  use length_field <- map(message_length(body))
  <<type_byte:utf8, length_field:bits, body:bits>>
}

/// A message without a type byte, as the first messages of a connection
/// are: the length, then the body.
fn unframed(body: BitArray) -> Result(BitArray, EncodeError) {
  use length_field <- map(message_length(body))
  <<length_field:bits, body:bits>>
}

/// The length field counts itself and the body, not the type byte.
fn message_length(body: BitArray) -> Result(BitArray, EncodeError) {
  length_field(byte_size(body) + 4)
}

/// Writes a 32-bit length field: of a whole message, or of one value of a
/// Bind, a FunctionCall or a SASLInitialResponse. The protocol reads it as
/// a signed number, so the largest length is 2147483647.
///
/// ## Parameters
///
/// - `byte_count`: the length to write
///
/// ## Returns
///
/// - `Ok(bytes)`: the four bytes of the length
/// - `Error(MessageTooLong(byte_count))`: the length is above 2147483647
pub fn length_field(byte_count: Int) -> Result(BitArray, EncodeError) {
  use <- guard(byte_count > largest_length, Error(MessageTooLong(byte_count)))
  Ok(<<byte_count:32>>)
}
