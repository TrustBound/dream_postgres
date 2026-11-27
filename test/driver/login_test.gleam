//// Tests for `dream_postgres/driver/login`: the checks of the settings, the
//// StartupMessage, and the login state machine for each method, with the
//// messages of a server written out by hand. No test needs a server.
////
//// The SCRAM values come from a separate Python implementation
//// (`hashlib.pbkdf2_hmac` and `hmac`), which gives the example of RFC 7677
//// exactly, with the password `pencil`, the client nonce of the bytes 0 to
//// 17 and the server nonce suffix `server-nonce`. The MD5 value is
//// `"md5" + md5(md5("pencil" + "ada").hexdigest() + "\x01\x02\x03\x04")`.

import dream_postgres/driver/channel_binding.{UnsupportedSignatureAlgorithm}
import dream_postgres/driver/login.{
  type ChannelBindingSetting, type ConfigError, type LoginConfig,
  type LoginError, type LoginOutcome, type LoginStartError, CancelKey,
  CertificateHashFailed, ChannelBindingNotOffered,
  ChannelBindingOfferedWithoutTls, ChannelBindingRequiresTls, CleartextLogin,
  ClientNonceTooLong, ClientNonceTooShort, DisableChannelBinding,
  DuplicateParameter, EmptyParameterName, EmptyUser, GssLogin, KerberosV5Login,
  LoginOutcome, Md5Login, PasswordHasZeroByte, PasswordRequired, PasswordTooLong,
  PreferChannelBinding, RequireChannelBinding, SaslLogin, ScramLogin,
  ScramServerFinalFailed, ScramServerFirstFailed, ServerRejectedLogin, SspiLogin,
  StartupMessageTooLong, TrustLogin, UnexpectedMessage,
  UnsupportedClientEncoding, UnsupportedLoginMethod, UnsupportedProtocolVersion,
  ZeroByteInParameter, ZeroByteInPassword, client_nonce, new, no_password,
  password, password_function,
}
import dream_postgres/driver/message.{
  type BackendMessage, type ProtocolVersion, AuthenticationCleartextPassword,
  AuthenticationGss, AuthenticationKerberosV5, AuthenticationMd5Password,
  AuthenticationOk, AuthenticationSasl, AuthenticationSaslContinue,
  AuthenticationSaslFinal, AuthenticationSspi, BackendKeyData, ErrorResponse,
  NegotiateProtocolVersion, NoticeResponse, ParameterStatus, Protocol30,
  Protocol32, ReadyForQuery,
}
import dream_postgres/driver/scram.{
  InvalidServerFirstMessage, ServerFirstTooLong, ServerSignatureMismatch,
}
import dream_postgres/internal/cell.{Idle, ServerReport}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/stored_password.{store_password, stored_password}
import fixtures/login_message_bytes.{
  password_message_bytes, sasl_initial_response_bytes, sasl_response_bytes,
  startup_message_bytes,
}
import fixtures/long_startup_parameters.{long_startup_parameters}
import gleam/dict
import gleam/list.{map}
import gleam/option.{type Option, None, Some}
import gleam/string.{repeat}
import matchers/extract_login_run.{type LoginRun, LoginRun, extract_login_run}
import matchers/extract_login_start.{extract_login_start}
import matchers/extract_login_state.{extract_login_state}
import matchers/extract_printed.{extract_printed}
import matchers/extract_startup_message.{extract_startup_message}
import matchers/extract_state_after.{extract_state_after}
import matchers/not_contain_text.{not_contain_text}

/// The tests of the login.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/login", [
    group("the StartupMessage", map(startup_cases(), startup_test)),
    group("settings that new refuses", map(config_error_cases(), config_test)),
    group("client_nonce", [client_nonce_test(), client_nonce_too_long_test()]),
    group("start", map(start_error_cases(), start_error_test)),
    group("logins that work", map(login_cases(), login_test)),
    group("logins that fail", map(failure_cases(), login_test)),
    group("channel binding", map(channel_binding_cases(), login_test)),
    group("protocol version", map(protocol_cases(), login_test)),
    group("messages that a step does not expect", {
      map(unexpected_cases(), login_test)
    }),
    group("the password function", [
      password_read_again_test(),
    ]),
    group("the password never prints", [
      printed_config_test(),
      ..map(state_cases(), state_test)
    ]),
  ])
}

// Values ----------------------------------------------------------------------

/// The client nonce: the bytes 0 to 17, `AAECAwQFBgcICQoLDA0ODxAR` in base64.
const nonce = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17>>

const server_first =
  "r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

const wrong_password_report =
  ServerReport(
    severity: "FATAL",
    localized_severity: "FATAL",
    code: "28P01",
    message: "password authentication failed for user \"ada\"",
    detail: Some("Connection matched file \"pg_hba.conf\" line 7"),
    hint: Some("hint"),
    position: Some(1),
    internal_position: Some(2),
    internal_query: Some("internal query"),
    context: Some("context"),
    schema: Some("schema"),
    table: Some("table"),
    column: Some("column"),
    data_type: Some("data type"),
    constraint: Some("constraint"),
    file: Some("auth.c"),
    line: Some(323),
    routine: Some("auth_failed"),
    other_fields: [#(0x5A, "other")],
  )

const first_notice =
  ServerReport(
    severity: "NOTICE",
    localized_severity: "NOTICE",
    code: "00000",
    message: "first",
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
    other_fields: [],
  )

const second_notice =
  ServerReport(
    severity: "WARNING",
    localized_severity: "WARNUNG",
    code: "01000",
    message: "second",
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
    other_fields: [],
  )

/// The settings of a test login. A test body gives them to `new`, so that
/// the coverage of the test run sees each check.
type Settings {
  Settings(
    user: String,
    database: String,
    password: PasswordSetting,
    parameters: List(#(String, String)),
    channel_binding: ChannelBindingSetting,
    protocol_version: ProtocolVersion,
  )
}

/// The password of a test login.
type PasswordSetting {
  TextPassword(text: String)
  FunctionPassword(read: fn() -> String)
  NoPasswordGiven
}

fn build(settings: Settings) -> Result(LoginConfig, ConfigError) {
  new(
    user: settings.user,
    database: settings.database,
    password: case settings.password {
      TextPassword(text:) -> password(text)
      FunctionPassword(read:) -> password_function(read)
      NoPasswordGiven -> no_password()
    },
    parameters: settings.parameters,
    channel_binding: settings.channel_binding,
    protocol_version: settings.protocol_version,
  )
}

fn config_with(
  password: PasswordSetting,
  channel_binding: ChannelBindingSetting,
  protocol_version: ProtocolVersion,
) -> Settings {
  Settings(
    user: "ada",
    database: "shop",
    password:,
    parameters: [],
    channel_binding:,
    protocol_version:,
  )
}

fn pencil(channel_binding: ChannelBindingSetting) -> Settings {
  config_with(TextPassword("pencil"), channel_binding, Protocol30)
}

fn sasl_first(flag: String) -> BitArray {
  let mechanism = case flag {
    "p=tls-server-end-point" -> "SCRAM-SHA-256-PLUS"
    _ -> "SCRAM-SHA-256"
  }
  sasl_initial_response_bytes(mechanism, <<
    flag:utf8,
    ",,n=,r=AAECAwQFBgcICQoLDA0ODxAR",
  >>)
}

fn sasl_final(binding: String, proof: String) -> BitArray {
  sasl_response_bytes(<<
    "c=":utf8,
    binding:utf8,
    ",r=AAECAwQFBgcICQoLDA0ODxARserver-nonce,p=":utf8,
    proof:utf8,
  >>)
}

const proof_without_binding = "TiYDpRjdsbRebN57WRJ0zaT3zsO7iKC3PFBX+WsscT0="

const signature_without_binding =
  "v=AvBMH0OLqQw46G6e1bvWRKc3j4kiF9BIHq4zhXgikQU="

const proof_with_flag_y = "msyn1LY0Oxyf+gll/EK7CSRK3qevfV2WO+EnTVvsmtY="

const signature_with_flag_y = "v=XWerSOwJj3Jipqf9+ifSFHLsATHu/Paues7tk7jd0vc="

const end_point_binding =
  "cD10bHMtc2VydmVyLWVuZC1wb2ludCwsGWtpJLD+PZUvUNHkl3nPH9RfsMH6IB1iMsapkzkqGNU="

const proof_with_end_point = "Fx0VuA3kaR3WQ4pqLtQ5uy0fXOuvt6uaMPY0dBUxApk="

const signature_with_end_point = "v=5RkvOJ60zJ/bG+wNLVBrZJn0Ezt116/vOqCHGUeseBs="

fn ready_messages() -> List(BackendMessage) {
  [
    AuthenticationOk,
    ParameterStatus("server_version", "17.0"),
    ParameterStatus("client_encoding", "UTF8"),
    BackendKeyData(42, <<1, 2, 3, 4>>),
    ReadyForQuery(Idle),
  ]
}

fn ready_outcome() -> LoginOutcome {
  LoginOutcome(
    parameters: dict.from_list([
      #("server_version", "17.0"),
      #("client_encoding", "UTF8"),
    ]),
    cancel_key: Some(CancelKey(42, <<1, 2, 3, 4>>)),
    protocol_version: Protocol30,
    unrecognized_options: [],
    notices: [],
    transaction_status: Idle,
  )
}

fn scram_messages(signature: String) -> List(BackendMessage) {
  [
    AuthenticationSaslContinue(<<server_first:utf8>>),
    AuthenticationSaslFinal(<<signature:utf8>>),
    ..ready_messages()
  ]
}

// The StartupMessage ----------------------------------------------------------

type StartupCase {
  StartupCase(name: String, settings: Settings, expected: BitArray)
}

fn startup_test(test_case: StartupCase) {
  it(test_case.name, fn() {
    // Arrange
    let config = build(test_case.settings)

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(nonce:, certificate_file: None)
    |> be_ok
    |> extract_startup_message
    |> be_equal(test_case.expected)
    |> or_fail_with("Expected the StartupMessage of " <> test_case.name)
  })
}

fn with_parameters(parameters: List(#(String, String))) -> Settings {
  Settings(..pencil(PreferChannelBinding), parameters:)
}

fn startup_cases() -> List(StartupCase) {
  [
    StartupCase(
      "the default application_name and client_encoding",
      with_parameters([]),
      startup_message_bytes(0, "ada", [
        #("database", "shop"),
        #("application_name", "dream_postgres"),
        #("client_encoding", "UTF8"),
      ]),
    ),
    StartupCase(
      "the caller's application_name in any case replaces the default",
      with_parameters([
        #("Application_Name", "billing"),
        #("options", "-c search_path=app"),
      ]),
      startup_message_bytes(0, "ada", [
        #("database", "shop"),
        #("options", "-c search_path=app"),
        #("Application_Name", "billing"),
        #("client_encoding", "UTF8"),
      ]),
    ),
    StartupCase(
      "a client_encoding that names UTF-8 is sent as UTF8",
      with_parameters([#("client_encoding", "utf-8")]),
      startup_message_bytes(0, "ada", [
        #("database", "shop"),
        #("application_name", "dream_postgres"),
        #("client_encoding", "UTF8"),
      ]),
    ),
    StartupCase(
      "the client_encoding unicode is UTF-8",
      with_parameters([#("CLIENT_ENCODING", "Unicode")]),
      startup_message_bytes(0, "ada", [
        #("database", "shop"),
        #("application_name", "dream_postgres"),
        #("client_encoding", "UTF8"),
      ]),
    ),
    StartupCase(
      "protocol 3.2",
      config_with(TextPassword("pencil"), PreferChannelBinding, Protocol32),
      startup_message_bytes(2, "ada", [
        #("database", "shop"),
        #("application_name", "dream_postgres"),
        #("client_encoding", "UTF8"),
      ]),
    ),
  ]
}

// Settings that new refuses ---------------------------------------------------

type ConfigCase {
  ConfigCase(name: String, settings: Settings, error: ConfigError)
}

fn config_test(test_case: ConfigCase) {
  it(test_case.name, fn() {
    // Act
    let config = build(test_case.settings)

    // Assert
    config
    |> should
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn config_error_cases() -> List(ConfigCase) {
  [
    ConfigCase(
      "an empty user",
      Settings(
        ..config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
        user: "",
        database: "shop",
      ),
      EmptyUser,
    ),
    ConfigCase(
      "a zero byte in the password",
      config_with(
        TextPassword("pen\u{0000}cil"),
        PreferChannelBinding,
        Protocol30,
      ),
      ZeroByteInPassword,
    ),
    ConfigCase(
      "a zero byte from the password function",
      config_with(
        FunctionPassword(fn() { "pen\u{0000}cil" }),
        PreferChannelBinding,
        Protocol30,
      ),
      ZeroByteInPassword,
    ),
    ConfigCase(
      "a zero byte in the user",
      Settings(
        ..config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
        user: "a\u{0000}da",
        database: "shop",
      ),
      ZeroByteInParameter("user"),
    ),
    ConfigCase(
      "a zero byte in the database",
      Settings(
        ..config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
        user: "ada",
        database: "sh\u{0000}op",
      ),
      ZeroByteInParameter("database"),
    ),
    ConfigCase(
      "a zero byte in a parameter value",
      with_parameters([#("options", "-c a=\u{0000}")]),
      ZeroByteInParameter("options"),
    ),
    ConfigCase(
      "a zero byte in a parameter name",
      with_parameters([#("opt\u{0000}ions", "-c a=1")]),
      ZeroByteInParameter("opt\u{0000}ions"),
    ),
    ConfigCase(
      "an empty parameter name",
      with_parameters([#("", "value")]),
      EmptyParameterName,
    ),
    ConfigCase(
      "a parameter given two times, in two cases",
      with_parameters([#("options", "-c a=1"), #("OPTIONS", "-c b=2")]),
      DuplicateParameter("OPTIONS"),
    ),
    ConfigCase(
      "a user parameter",
      with_parameters([#("User", "bob")]),
      DuplicateParameter("User"),
    ),
    ConfigCase(
      "a database parameter",
      with_parameters([#("database", "other")]),
      DuplicateParameter("database"),
    ),
    ConfigCase(
      "a client_encoding other than UTF-8",
      with_parameters([#("client_encoding", "LATIN1")]),
      UnsupportedClientEncoding("LATIN1"),
    ),
    // The length field and the version are 8 bytes and the end of the list
    // is 1. `user`, `database`, `application_name` and `client_encoding`
    // with their values and zero bytes are 9 + 14 + 32 + 21. The names p0
    // to p2047 are 9130 bytes, and each parameter has 1048576 + 2 more.
    ConfigCase(
      "a StartupMessage longer than its length field can hold",
      with_parameters(long_startup_parameters()),
      StartupMessageTooLong(2_147_496_959),
    ),
  ]
}

// client_nonce ----------------------------------------------------------------

fn client_nonce_test() {
  it("refuses a client nonce of 17 bytes", fn() {
    // Act
    let made = client_nonce(<<0:136>>)

    // Assert
    made
    |> should
    |> be_error
    |> be_equal(ClientNonceTooShort(17))
    |> or_fail_with("Expected ClientNonceTooShort(17)")
  })
}

fn client_nonce_too_long_test() {
  it("refuses a client nonce of 1025 bytes", fn() {
    // Act
    let made = client_nonce(<<0:size(8200)>>)

    // Assert
    made
    |> should
    |> be_error
    |> be_equal(ClientNonceTooLong(1025))
    |> or_fail_with("Expected ClientNonceTooLong(1025)")
  })
}

// start -----------------------------------------------------------------------

type StartErrorCase {
  StartErrorCase(
    name: String,
    channel_binding: ChannelBindingSetting,
    client_nonce: BitArray,
    error: LoginStartError,
  )
}

fn start_error_test(test_case: StartErrorCase) {
  it(test_case.name, fn() {
    // Arrange
    let config = build(pencil(test_case.channel_binding))

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(
      nonce: test_case.client_nonce,
      certificate_file: None,
    )
    |> be_error
    |> be_equal(test_case.error)
    |> or_fail_with("Expected an error for " <> test_case.name)
  })
}

fn start_error_cases() -> List(StartErrorCase) {
  [
    StartErrorCase(
      "channel binding required on a connection with no TLS",
      RequireChannelBinding,
      nonce,
      ChannelBindingRequiresTls,
    ),
  ]
}

// Logins ----------------------------------------------------------------------

type LoginCase {
  LoginCase(
    name: String,
    settings: Settings,
    certificate_file: Option(String),
    messages: List(BackendMessage),
    expected: Result(LoginRun, LoginError),
  )
}

/// A login case that ends in a run gets a test of the run. A case that
/// ends in an error gets a test of the error.
fn login_test(test_case: LoginCase) {
  case test_case.expected {
    Ok(login_run) -> login_run_test(test_case, login_run)
    Error(error) -> login_error_test(test_case, error)
  }
}

fn login_run_test(test_case: LoginCase, expected: LoginRun) {
  it(test_case.name, fn() {
    // Arrange
    let config = build(test_case.settings)

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(nonce:, certificate_file: test_case.certificate_file)
    |> extract_login_run(test_case.messages)
    |> be_ok
    |> be_equal(expected)
    |> or_fail_with("Expected the login result of " <> test_case.name)
  })
}

fn login_error_test(test_case: LoginCase, expected: LoginError) {
  it(test_case.name, fn() {
    // Arrange
    let config = build(test_case.settings)

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(nonce:, certificate_file: test_case.certificate_file)
    |> extract_login_run(test_case.messages)
    |> be_error
    |> be_equal(expected)
    |> or_fail_with("Expected the login result of " <> test_case.name)
  })
}

fn login_cases() -> List(LoginCase) {
  [
    LoginCase(
      "no password, with each parameter, the key and the notices in order",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
      None,
      [
        NoticeResponse(first_notice),
        AuthenticationOk,
        ParameterStatus("server_version", "17.0"),
        NoticeResponse(second_notice),
        ParameterStatus("client_encoding", "UTF8"),
        BackendKeyData(42, <<1, 2, 3, 4>>),
        ReadyForQuery(Idle),
      ],
      Ok(LoginRun(
        [],
        Some(
          LoginOutcome(..ready_outcome(), notices: [first_notice, second_notice]),
        ),
      )),
    ),
    LoginCase(
      "a cleartext password",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationCleartextPassword, ..ready_messages()],
      Ok(LoginRun([password_message_bytes("pencil")], Some(ready_outcome()))),
    ),
    LoginCase(
      "a cleartext password of 65530 bytes, the longest_password",
      config_with(
        TextPassword(repeat("a", 65_530)),
        PreferChannelBinding,
        Protocol30,
      ),
      None,
      [AuthenticationCleartextPassword],
      Ok(LoginRun([password_message_bytes(repeat("a", 65_530))], None)),
    ),
    LoginCase(
      "an MD5 password",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationMd5Password(<<1, 2, 3, 4>>), ..ready_messages()],
      Ok(LoginRun(
        [password_message_bytes("md5d1b13b8314d3b5545feef5ce8ab91e15")],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "SCRAM-SHA-256 with no TLS",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        ..scram_messages(signature_without_binding)
      ],
      Ok(LoginRun(
        [sasl_first("n"), sasl_final("biws", proof_without_binding)],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "a login without a BackendKeyData",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
      None,
      [AuthenticationOk, ReadyForQuery(Idle)],
      Ok(LoginRun(
        [],
        Some(
          LoginOutcome(
            ..ready_outcome(),
            parameters: dict.new(),
            cancel_key: None,
          ),
        ),
      )),
    ),
  ]
}

fn failure_cases() -> List(LoginCase) {
  [
    LoginCase(
      "a cleartext password of 65531 bytes, one more than longest_password",
      config_with(
        TextPassword(repeat("a", 65_531)),
        PreferChannelBinding,
        Protocol30,
      ),
      None,
      [AuthenticationCleartextPassword],
      Error(PasswordTooLong(65_531)),
    ),
    LoginCase(
      "a server-first-message of 16385 bytes",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        AuthenticationSaslContinue(<<0:size(131_080)>>),
      ],
      Error(ScramServerFirstFailed(ServerFirstTooLong(16_385))),
    ),
    LoginCase(
      "a wrong password gives the server's report",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        AuthenticationSaslContinue(<<server_first:utf8>>),
        ErrorResponse(wrong_password_report),
      ],
      Error(ServerRejectedLogin(wrong_password_report)),
    ),
    LoginCase(
      "a wrong server signature",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        ..scram_messages(signature_with_flag_y)
      ],
      Error(ScramServerFinalFailed(ServerSignatureMismatch)),
    ),
    LoginCase(
      "a server-first-message that is not valid",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        AuthenticationSaslContinue(<<"x">>),
      ],
      Error(ScramServerFirstFailed(InvalidServerFirstMessage(<<"x">>))),
    ),
    LoginCase(
      "no password for a cleartext request",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
      None,
      [AuthenticationCleartextPassword],
      Error(PasswordRequired(CleartextLogin)),
    ),
    LoginCase(
      "an empty password for an MD5 request",
      config_with(TextPassword(""), PreferChannelBinding, Protocol30),
      None,
      [AuthenticationMd5Password(<<1, 2, 3, 4>>)],
      Error(PasswordRequired(Md5Login)),
    ),
    LoginCase(
      "no password for SCRAM",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        AuthenticationSaslContinue(<<server_first:utf8>>),
      ],
      Error(PasswordRequired(ScramLogin("SCRAM-SHA-256"))),
    ),
    LoginCase(
      "Kerberos V5",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationKerberosV5],
      Error(UnsupportedLoginMethod(KerberosV5Login)),
    ),
    LoginCase(
      "GSSAPI",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationGss],
      Error(UnsupportedLoginMethod(GssLogin)),
    ),
    LoginCase(
      "SSPI",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationSspi],
      Error(UnsupportedLoginMethod(SspiLogin)),
    ),
    LoginCase(
      "a SASL mechanism list with no SCRAM",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationSasl(["OAUTHBEARER"])],
      Error(UnsupportedLoginMethod(SaslLogin(["OAUTHBEARER"]))),
    ),
  ]
}

fn channel_binding_cases() -> List(LoginCase) {
  [
    LoginCase(
      "prefer, with TLS and SCRAM-SHA-256-PLUS, binds to the certificate",
      pencil(PreferChannelBinding),
      Some("rsa_sha256.der"),
      [
        AuthenticationSasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]),
        ..scram_messages(signature_with_end_point)
      ],
      Ok(LoginRun(
        [
          sasl_first("p=tls-server-end-point"),
          sasl_final(end_point_binding, proof_with_end_point),
        ],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "require, with TLS and SCRAM-SHA-256-PLUS, binds to the certificate",
      pencil(RequireChannelBinding),
      Some("rsa_sha256.der"),
      [
        AuthenticationSasl(["SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"]),
        ..scram_messages(signature_with_end_point)
      ],
      Ok(LoginRun(
        [
          sasl_first("p=tls-server-end-point"),
          sasl_final(end_point_binding, proof_with_end_point),
        ],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "prefer, with TLS and SCRAM-SHA-256 only, sends the y flag",
      pencil(PreferChannelBinding),
      Some("rsa_sha256.der"),
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        ..scram_messages(signature_with_flag_y)
      ],
      Ok(LoginRun(
        [sasl_first("y"), sasl_final("eSws", proof_with_flag_y)],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "disable, with TLS and SCRAM-SHA-256-PLUS, sends the n flag",
      pencil(DisableChannelBinding),
      Some("rsa_sha256.der"),
      [
        AuthenticationSasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]),
        ..scram_messages(signature_without_binding)
      ],
      Ok(LoginRun(
        [sasl_first("n"), sasl_final("biws", proof_without_binding)],
        Some(ready_outcome()),
      )),
    ),
    LoginCase(
      "disable, when the server offers SCRAM-SHA-256-PLUS only",
      pencil(DisableChannelBinding),
      Some("rsa_sha256.der"),
      [AuthenticationSasl(["SCRAM-SHA-256-PLUS"])],
      Error(UnsupportedLoginMethod(SaslLogin(["SCRAM-SHA-256-PLUS"]))),
    ),
    LoginCase(
      "SCRAM-SHA-256-PLUS offered with no TLS",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationSasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"])],
      Error(ChannelBindingOfferedWithoutTls),
    ),
    LoginCase(
      "require, when the server offers SCRAM-SHA-256 only",
      pencil(RequireChannelBinding),
      Some("rsa_sha256.der"),
      [AuthenticationSasl(["SCRAM-SHA-256"])],
      Error(ChannelBindingNotOffered(SaslLogin(["SCRAM-SHA-256"]))),
    ),
    LoginCase(
      "require, when the server offers no SCRAM",
      pencil(RequireChannelBinding),
      Some("rsa_sha256.der"),
      [AuthenticationSasl(["OAUTHBEARER"])],
      Error(UnsupportedLoginMethod(SaslLogin(["OAUTHBEARER"]))),
    ),
    LoginCase(
      "require refuses a cleartext request",
      pencil(RequireChannelBinding),
      Some("rsa_sha256.der"),
      [AuthenticationCleartextPassword],
      Error(ChannelBindingNotOffered(CleartextLogin)),
    ),
    LoginCase(
      "require refuses a login with no password",
      pencil(RequireChannelBinding),
      Some("rsa_sha256.der"),
      [AuthenticationOk],
      Error(ChannelBindingNotOffered(TrustLogin)),
    ),
    LoginCase(
      "a certificate with no tls-server-end-point hash",
      pencil(PreferChannelBinding),
      Some("ed25519.der"),
      [AuthenticationSasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"])],
      Error(
        CertificateHashFailed(UnsupportedSignatureAlgorithm([1, 3, 101, 112])),
      ),
    ),
  ]
}

fn protocol_cases() -> List(LoginCase) {
  [
    LoginCase(
      "a server that answers 3.0 to 3.2",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      [NegotiateProtocolVersion(3, 0, ["_pq_.dream_test"]), ..ready_messages()],
      Ok(LoginRun(
        [],
        Some(
          LoginOutcome(..ready_outcome(), unrecognized_options: [
            "_pq_.dream_test",
          ]),
        ),
      )),
    ),
    LoginCase(
      "a server that keeps 3.2 and names an unknown option",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      [NegotiateProtocolVersion(3, 2, ["_pq_.dream_test"]), ..ready_messages()],
      Ok(LoginRun(
        [],
        Some(
          LoginOutcome(
            ..ready_outcome(),
            protocol_version: Protocol32,
            unrecognized_options: ["_pq_.dream_test"],
          ),
        ),
      )),
    ),
    LoginCase(
      "a login that asks 3.2 and gets no NegotiateProtocolVersion",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      ready_messages(),
      Ok(LoginRun(
        [],
        Some(LoginOutcome(..ready_outcome(), protocol_version: Protocol32)),
      )),
    ),
    LoginCase(
      "a server that answers 3.1",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      [NegotiateProtocolVersion(3, 1, [])],
      Error(UnsupportedProtocolVersion(3, 1)),
    ),
    LoginCase(
      "a server that answers 3.2 to 3.0",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol30),
      None,
      [NegotiateProtocolVersion(3, 2, [])],
      Error(UnsupportedProtocolVersion(3, 2)),
    ),
    LoginCase(
      "a server that answers major version 4",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      [NegotiateProtocolVersion(4, 0, [])],
      Error(UnsupportedProtocolVersion(4, 0)),
    ),
  ]
}

fn unexpected_cases() -> List(LoginCase) {
  [
    LoginCase(
      "a second NegotiateProtocolVersion",
      config_with(NoPasswordGiven, PreferChannelBinding, Protocol32),
      None,
      [
        NegotiateProtocolVersion(3, 0, []),
        NegotiateProtocolVersion(3, 0, []),
      ],
      Error(UnexpectedMessage(NegotiateProtocolVersion(3, 0, []))),
    ),
    LoginCase(
      "a ReadyForQuery before the login request",
      pencil(PreferChannelBinding),
      None,
      [ReadyForQuery(Idle)],
      Error(UnexpectedMessage(ReadyForQuery(Idle))),
    ),
    LoginCase(
      "an AuthenticationOk before the server-first-message",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationSasl(["SCRAM-SHA-256"]), AuthenticationOk],
      Error(UnexpectedMessage(AuthenticationOk)),
    ),
    LoginCase(
      "an AuthenticationOk before the server-final-message",
      pencil(PreferChannelBinding),
      None,
      [
        AuthenticationSasl(["SCRAM-SHA-256"]),
        AuthenticationSaslContinue(<<server_first:utf8>>),
        AuthenticationOk,
      ],
      Error(UnexpectedMessage(AuthenticationOk)),
    ),
    LoginCase(
      "a ParameterStatus before the AuthenticationOk",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationCleartextPassword, ParameterStatus("a", "b")],
      Error(UnexpectedMessage(ParameterStatus("a", "b"))),
    ),
    LoginCase(
      "a second AuthenticationOk",
      pencil(PreferChannelBinding),
      None,
      [AuthenticationOk, AuthenticationOk],
      Error(UnexpectedMessage(AuthenticationOk)),
    ),
  ]
}

// The password function -------------------------------------------------------

fn password_read_again_test() {
  it("is checked again when the server asks", fn() {
    // Arrange
    store_password("password", "pencil")
    let config =
      build(config_with(
        FunctionPassword(fn() { stored_password("password") }),
        PreferChannelBinding,
        Protocol30,
      ))
    store_password("password", "pen\u{0000}cil")

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(nonce:, certificate_file: None)
    |> extract_login_run([AuthenticationCleartextPassword])
    |> be_error
    |> be_equal(PasswordHasZeroByte)
    |> or_fail_with("Expected the zero byte of the second read to fail")
  })
}

// The password never prints ---------------------------------------------------

type StateCase {
  StateCase(name: String, messages: List(BackendMessage))
}

fn printed_config_test() {
  it("the config", fn() {
    // Act
    let config = build(pencil(PreferChannelBinding))

    // Assert
    config
    |> should
    |> be_ok
    |> extract_printed
    |> not_contain_text("pencil")
    |> or_fail_with("Expected no password text in the config")
  })
}

fn state_test(test_case: StateCase) {
  it(test_case.name, fn() {
    // Arrange
    let config = build(pencil(PreferChannelBinding))

    // Act and Assert
    config
    |> should
    |> be_ok
    |> extract_login_start(nonce:, certificate_file: None)
    |> be_ok
    |> extract_login_state
    |> extract_state_after(test_case.messages)
    |> extract_printed
    |> not_contain_text("pencil")
    |> or_fail_with("Expected no password text in " <> test_case.name)
  })
}

fn state_cases() -> List(StateCase) {
  [
    StateCase("the state after start", [NoticeResponse(first_notice)]),
    StateCase("the state after a cleartext request", [
      AuthenticationCleartextPassword,
    ]),
    StateCase("the state after the SASL request", [
      AuthenticationSasl(["SCRAM-SHA-256"]),
    ]),
    StateCase("the state after the server-first-message", [
      AuthenticationSasl(["SCRAM-SHA-256"]),
      AuthenticationSaslContinue(<<server_first:utf8>>),
    ]),
    StateCase("the state after the server-final-message", [
      AuthenticationSasl(["SCRAM-SHA-256"]),
      AuthenticationSaslContinue(<<server_first:utf8>>),
      AuthenticationSaslFinal(<<signature_without_binding:utf8>>),
    ]),
    StateCase("the state after AuthenticationOk", [
      AuthenticationCleartextPassword,
      AuthenticationOk,
      ParameterStatus("server_version", "17.0"),
    ]),
  ]
}
