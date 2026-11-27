//// Tests for `dream_postgres/driver/encode`: the exact bytes of every
//// frontend message, written out from the layouts of the PostgreSQL
//// documentation ("Message Formats"), and each value that a layout cannot
//// hold.

import dream_postgres/driver/encode.{encode, length_field}
import dream_postgres/driver/message.{
  type EncodeError, type FrontendMessage, Bind, CancelRequest, Close, CopyData,
  CopyDone, CopyFail, Describe, DuplicateStartupParameter,
  EmptyStartupParameterName, Execute, Flush, FunctionCall, GssEncryptionRequest,
  GssResponse, NumberOutOfRange, Parse, PasswordMessage, Portal, Protocol30,
  Protocol32, Query, SaslInitialResponse, SaslResponse,
  SecretKeyLengthOutOfRange, SslRequest, StartupMessage, Statement, Sync,
  Terminate, TooManyItems, ZeroByteInString,
}
import dream_postgres/internal/cell.{
  Binary, BinaryFormat, Null, Text, TextFormat,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/list.{map, repeat}
import gleam/option.{None, Some}

/// The tests of the encoder.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/encode", [
    group(
      "the bytes of each frontend message",
      map(message_cases(), bytes_test),
    ),
    group("values that a layout cannot hold", map(error_cases(), error_test)),
    group("the 32-bit length field", length_field_tests()),
  ])
}

type MessageCase {
  MessageCase(name: String, message: FrontendMessage, bytes: BitArray)
}

type ErrorCase {
  ErrorCase(name: String, message: FrontendMessage, error: EncodeError)
}

fn bytes_test(test_case: MessageCase) {
  it(test_case.name, fn() {
    // Act
    let bytes = encode(test_case.message)

    // Assert
    bytes
    |> should
    |> be_ok
    |> be_equal(test_case.bytes)
    |> or_fail_with("Expected the bytes of " <> test_case.name)
  })
}

fn error_test(test_case: ErrorCase) {
  it(test_case.name, fn() {
    // Act
    let bytes = encode(test_case.message)

    // Assert
    bytes
    |> should
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn message_cases() -> List(MessageCase) {
  list.flatten([startup_cases(), login_cases(), query_cases(), copy_cases()])
}

fn startup_cases() -> List(MessageCase) {
  [
    MessageCase(
      "a StartupMessage of protocol 3.0 with the user only",
      StartupMessage(Protocol30, "ada", []),
      <<18:32, 3:16, 0:16, "user":utf8, 0, "ada":utf8, 0, 0>>,
    ),
    MessageCase(
      "a StartupMessage of protocol 3.2 with database and options",
      StartupMessage(Protocol32, "ada", [
        #("database", "shop"),
        #("options", "-c search_path=app"),
      ]),
      <<
        59:32, 3:16, 2:16, "user":utf8, 0, "ada":utf8, 0, "database":utf8, 0,
        "shop":utf8, 0, "options":utf8, 0, "-c search_path=app":utf8, 0, 0,
      >>,
    ),
    MessageCase("an SSLRequest", SslRequest, <<8:32, 1234:16, 5679:16>>),
    MessageCase("a GSSENCRequest", GssEncryptionRequest, <<
      8:32,
      1234:16,
      5680:16,
    >>),
    MessageCase(
      "a CancelRequest with a 4-byte key",
      CancelRequest(4321, <<1, 2, 3, 4>>),
      <<16:32, 1234:16, 5678:16, 4321:32, 1, 2, 3, 4>>,
    ),
    MessageCase(
      "a CancelRequest with a 32-byte key of protocol 3.2",
      CancelRequest(4321, <<7:256>>),
      <<44:32, 1234:16, 5678:16, 4321:32, 7:256>>,
    ),
    MessageCase("a Terminate", Terminate, <<"X", 4:32>>),
  ]
}

fn login_cases() -> List(MessageCase) {
  [
    MessageCase("a PasswordMessage", PasswordMessage("secret"), <<
      "p",
      11:32,
      "secret":utf8,
      0,
    >>),
    MessageCase(
      "a SASLInitialResponse with data",
      SaslInitialResponse("SCRAM-SHA-256", Some(<<"n,,n=,r=abc":utf8>>)),
      <<"p", 33:32, "SCRAM-SHA-256":utf8, 0, 11:32, "n,,n=,r=abc":utf8>>,
    ),
    MessageCase(
      "a SASLInitialResponse without data",
      SaslInitialResponse("SCRAM-SHA-256", None),
      <<"p", 22:32, "SCRAM-SHA-256":utf8, 0, -1:32>>,
    ),
    MessageCase("a SASLResponse", SaslResponse(<<"c=biws":utf8>>), <<
      "p",
      10:32,
      "c=biws":utf8,
    >>),
    MessageCase("a GSSResponse", GssResponse(<<1, 2, 3>>), <<
      "p",
      7:32,
      1,
      2,
      3,
    >>),
  ]
}

fn query_cases() -> List(MessageCase) {
  [
    MessageCase(
      "a Parse with two parameter types",
      Parse("find_user", "SELECT $1, $2", [23, 0]),
      <<
        "P", 38:32, "find_user":utf8, 0, "SELECT $1, $2":utf8, 0, 2:16, 23:32,
        0:32,
      >>,
    ),
    MessageCase(
      "a Bind with a binary, a text and a NULL parameter",
      Bind(
        "",
        "find_user",
        [Binary(<<0, 0, 0, 7>>), Text(<<"ada":utf8>>), Null],
        [
          BinaryFormat,
          TextFormat,
        ],
      ),
      <<
        "B", 50:32, 0, "find_user":utf8, 0, 3:16, 1:16, 0:16, 0:16, 3:16, 4:32,
        0, 0, 0, 7, 3:32, "ada":utf8, -1:32, 2:16, 1:16, 0:16,
      >>,
    ),
    MessageCase(
      "a Bind with no parameters and no result formats",
      Bind("portal", "", [], []),
      <<"B", 18:32, "portal":utf8, 0, 0, 0:16, 0:16, 0:16>>,
    ),
    MessageCase("a Describe of a statement", Describe(Statement("find_user")), <<
      "D",
      15:32,
      "S",
      "find_user":utf8,
      0,
    >>),
    MessageCase("a Describe of the unnamed portal", Describe(Portal("")), <<
      "D",
      6:32,
      "P",
      0,
    >>),
    MessageCase("an Execute with a row limit", Execute("", 100), <<
      "E",
      9:32,
      0,
      100:32,
    >>),
    MessageCase("a Sync", Sync, <<"S", 4:32>>),
    MessageCase("a Flush", Flush, <<"H", 4:32>>),
    MessageCase("a Close of a statement", Close(Statement("find_user")), <<
      "C",
      15:32,
      "S",
      "find_user":utf8,
      0,
    >>),
    MessageCase("a Close of a portal", Close(Portal("p1")), <<
      "C",
      8:32,
      "P",
      "p1":utf8,
      0,
    >>),
    MessageCase("a Query", Query("SELECT 1"), <<"Q", 13:32, "SELECT 1":utf8, 0>>),
    MessageCase(
      "a FunctionCall with a text argument and a binary result",
      FunctionCall(1598, [Text(<<"x":utf8>>)], BinaryFormat),
      <<"F", 21:32, 1598:32, 1:16, 0:16, 1:16, 1:32, "x":utf8, 1:16>>,
    ),
  ]
}

fn copy_cases() -> List(MessageCase) {
  [
    MessageCase("a CopyData", CopyData(<<"1\tada\n":utf8>>), <<
      "d",
      10:32,
      "1\tada\n":utf8,
    >>),
    MessageCase("a CopyDone", CopyDone, <<"c", 4:32>>),
    MessageCase("a CopyFail", CopyFail("stopped"), <<
      "f",
      12:32,
      "stopped":utf8,
      0,
    >>),
  ]
}

fn error_cases() -> List(ErrorCase) {
  [
    ErrorCase(
      "a zero byte in a Query",
      Query("SELECT 1\u{0000}"),
      ZeroByteInString("query"),
    ),
    ErrorCase(
      "a zero byte in a startup parameter name",
      StartupMessage(Protocol30, "ada", [#("data\u{0000}base", "shop")]),
      ZeroByteInString("startup parameter name"),
    ),
    ErrorCase(
      "a zero byte in a startup parameter value",
      StartupMessage(Protocol30, "ada", [#("database", "sh\u{0000}op")]),
      ZeroByteInString("startup parameter value"),
    ),
    ErrorCase(
      "a zero byte in the user",
      StartupMessage(Protocol30, "a\u{0000}da", []),
      ZeroByteInString("startup parameter value"),
    ),
    ErrorCase(
      "a startup parameter with an empty name",
      StartupMessage(Protocol30, "ada", [#("", "x")]),
      EmptyStartupParameterName,
    ),
    ErrorCase(
      "a startup parameter named user",
      StartupMessage(Protocol30, "ada", [#("user", "bob")]),
      DuplicateStartupParameter("user"),
    ),
    ErrorCase(
      "a startup parameter given two times",
      StartupMessage(Protocol30, "ada", [
        #("database", "shop"),
        #("database", "shop"),
      ]),
      DuplicateStartupParameter("database"),
    ),
    ErrorCase(
      "a CancelRequest key of 3 bytes",
      CancelRequest(1, <<1, 2, 3>>),
      SecretKeyLengthOutOfRange(3),
    ),
    ErrorCase(
      "a CancelRequest key of 257 bytes",
      CancelRequest(1, <<0:size(2056)>>),
      SecretKeyLengthOutOfRange(257),
    ),
    ErrorCase(
      "a negative process ID",
      CancelRequest(-1, <<1, 2, 3, 4>>),
      NumberOutOfRange("process_id", -1),
    ),
    ErrorCase(
      "a process ID above 32 bits",
      CancelRequest(4_294_967_296, <<1, 2, 3, 4>>),
      NumberOutOfRange("process_id", 4_294_967_296),
    ),
    ErrorCase(
      "a negative type OID in a Parse",
      Parse("", "SELECT $1", [-1]),
      NumberOutOfRange("object id", -1),
    ),
    ErrorCase(
      "65536 parameter types in a Parse",
      Parse("", "SELECT 1", repeat(0, 65_536)),
      TooManyItems("parameter_type_ids", 65_536),
    ),
    ErrorCase(
      "65536 parameters in a Bind",
      Bind("", "", repeat(Null, 65_536), []),
      TooManyItems("parameters", 65_536),
    ),
    ErrorCase(
      "65536 result formats in a Bind",
      Bind("", "", [], repeat(TextFormat, 65_536)),
      TooManyItems("result_formats", 65_536),
    ),
    ErrorCase(
      "a negative row limit",
      Execute("", -1),
      NumberOutOfRange("row_limit", -1),
    ),
    ErrorCase(
      "a row limit above 31 bits",
      Execute("", 2_147_483_648),
      NumberOutOfRange("row_limit", 2_147_483_648),
    ),
    ErrorCase(
      "a negative function OID",
      FunctionCall(-5, [], TextFormat),
      NumberOutOfRange("object id", -5),
    ),
    ErrorCase(
      "a zero byte in a SASL mechanism",
      SaslInitialResponse("SCRAM\u{0000}", None),
      ZeroByteInString("mechanism"),
    ),
  ]
}

fn length_field_tests() {
  [
    it("writes the largest length, 2147483647", fn() {
      // Act
      let bytes = length_field(2_147_483_647)

      // Assert
      bytes
      |> should
      |> be_ok
      |> be_equal(<<127, 255, 255, 255>>)
      |> or_fail_with("Expected the bytes 127, 255, 255, 255")
    }),
    it("refuses one more than the largest length", fn() {
      // Act
      let bytes = length_field(2_147_483_648)

      // Assert
      bytes
      |> should
      |> be_error
      |> be_equal(2_147_483_648)
      |> or_fail_with("Expected the length 2147483648")
    }),
  ]
}
