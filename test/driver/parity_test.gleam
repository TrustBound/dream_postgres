//// The parity tests: behaviors that the Common Test suites of the pgo fork
//// proved, run on the driver, on the driver servers of PostgreSQL 16 to
//// 19. `test/driver/PARITY.md` maps each case of the fork to its test.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type DriverError, type Outcome, type StatementCaching,
  Backoff, CacheStatements, ConnectionConfig, ConnectionLost, Disconnected,
  LoginRefused, Reconnected, ServerEndedConnection, ServerRefused,
  StatementChanged, TransportRefused, UnnamedStatements,
}
import dream_postgres/driver/login.{
  type Password, PreferChannelBinding, ServerRejectedLogin,
}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/pool.{
  type Pool, type PoolConfig, type PoolStatus, PoolConfig, PoolStatus,
}
import dream_postgres/driver/statement_cache
import dream_postgres/driver/transport.{
  type Tls, type TransportError, AuthorityFile, AuthorityFileUnreadable,
  CheckAuthorityAndHost, ConnectionReset, DnsLookupFailed, InvalidPort,
  NoCertificateCheck, NoTls, PostgresNegotiation, RequireTls, ServerRefusedTls,
  SocketClosed, TlsFailed, TransportConfig,
}
import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type Format, type ServerReport, Binary,
  BinaryFormat, Null, Text, TextFormat,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int.{to_string}
import gleam/list.{map, try_map}
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/pair
import gleam/result.{try}
import gleam/string

@external(erlang, "driver_parity_ffi", "start_login_refusing_server")
fn start_login_refusing_server() -> #(Int, FakeServer)

@external(erlang, "driver_parity_ffi", "start_closing_server")
fn start_closing_server() -> #(Int, FakeServer)

@external(erlang, "driver_parity_ffi", "client_closed")
fn parity_client_closed(server: FakeServer) -> Bool

@external(erlang, "driver_parity_ffi", "status_holds")
fn status_holds(pid: Pid, text: String) -> Bool

@external(erlang, "driver_parity_ffi", "stop_process")
fn stop_process(pid: Pid) -> Nil

@external(erlang, "driver_fake_server_ffi", "start")
fn start_fake_server(behavior: FakeBehavior) -> #(Int, FakeServer)

@external(erlang, "driver_fake_server_ffi", "client_closed")
fn fake_client_closed(server: FakeServer) -> Bool

@external(erlang, "driver_proxy_ffi", "start")
fn start_proxy(server_port: Int) -> #(Int, Proxy)

@external(erlang, "driver_proxy_ffi", "close_client")
fn close_client(proxy: Proxy) -> Nil

@external(erlang, "driver_proxy_ffi", "reset_client")
fn reset_client(proxy: Proxy) -> Nil

@external(erlang, "driver_connection_test_ffi", "pid_of")
fn pid_of(connection: Connection) -> Pid

type FakeServer

type Proxy

/// What the fake server of `driver_fake_server_ffi` does after the
/// SSLRequest.
type FakeBehavior {
  Answer(BitArray)
}

/// The longest time of each request.
const deadline = 5000

/// The PostgreSQL 16 server of the old client tests, with SSL off.
const server_without_tls = 5436

/// The printed form of the password `dream`, as a binary.
const printed_password = "<<\"dream\">>"

/// The tests of the parity suite.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver parity with the pgo fork", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("addresses", address_tests()),
    group("closed sockets", socket_tests()),
    group("the password", password_tests()),
  ])
}

// Settings --------------------------------------------------------------------

fn login_config(
  port: Int,
  user: String,
  database: String,
  password: Password,
  parameters: List(#(String, String)),
) -> Result(ConnectionConfig, String) {
  use address <- try(
    transport.address("localhost", port) |> result.map_error(string.inspect),
  )
  use login_settings <- try(
    login.new(
      user:,
      database:,
      password:,
      parameters:,
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.map_error(string.inspect),
  )
  Ok(ConnectionConfig(
    transport: TransportConfig(address, NoTls, 5000, 5000),
    login: login_settings,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(10, 1000),
    events: None,
    notifications: None,
    statements: CacheStatements(statement_cache.default_limit),
  ))
}

/// The user `dream`, with the session time zone UTC.
fn dream_config(port: Int) -> Result(ConnectionConfig, String) {
  login_config(
    port,
    "dream",
    servers.database,
    login.password(servers.password),
    [#("TimeZone", "UTC")],
  )
}

fn with_caching(
  config: ConnectionConfig,
  caching: StatementCaching,
) -> ConnectionConfig {
  ConnectionConfig(..config, statements: caching)
}

fn with_events(
  config: ConnectionConfig,
  events: Subject(ConnectionEvent),
) -> ConnectionConfig {
  ConnectionConfig(..config, events: Some(events))
}

fn with_tls(config: ConnectionConfig, tls: Tls) -> ConnectionConfig {
  ConnectionConfig(
    ..config,
    transport: TransportConfig(..config.transport, tls:),
  )
}

fn read_password() -> String {
  servers.password
}

// Requests --------------------------------------------------------------------

fn with_connection(
  config: Result(ConnectionConfig, String),
  body: fn(Connection) -> Result(value, String),
) -> Result(value, String) {
  use settings <- try(config)
  use started <- try(
    connection.start(settings) |> result.map_error(string.inspect),
  )
  let value = body(started)
  connection.stop(started)
  value
}

fn run(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
) -> Result(Outcome, String) {
  connection.run(connection, sql, parameters, [], deadline)
  |> result.map_error(string.inspect)
}

fn rows(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
) -> Result(List(List(String)), String) {
  run(connection, sql, parameters) |> result.map(texts)
}

fn script(connection: Connection, sql: String) -> Result(List(String), String) {
  connection.run_script(connection, sql, deadline)
  |> result.map(map(_, tag))
  |> result.map_error(string.inspect)
}

fn tag(outcome: Outcome) -> String {
  outcome.result.tag
}

fn texts(outcome: Outcome) -> List(List(String)) {
  map(outcome.result.rows, row_texts)
}

fn row_texts(row: List(Cell)) -> List(String) {
  map(row, cell_text)
}

fn cell_text(cell: Cell) -> String {
  case cell {
    Text(bytes) -> bit_array.to_string(bytes) |> result.unwrap("not UTF-8")
    Binary(bytes) -> string.inspect(bytes)
    Null -> "NULL"
  }
}

/// What a run that should fail gave: the SQLSTATE of a refusal, the
/// SQLSTATE of a session that the server ended, StatementChanged, or the
/// tag of a run that worked.
fn answer_kind(answer: Result(Outcome, DriverError)) -> String {
  case answer {
    Ok(outcome) -> "ran " <> tag(outcome)
    Error(ServerRefused(report, _status)) -> report.code
    Error(ServerEndedConnection(report)) -> "ended " <> report.code
    Error(StatementChanged(_description)) -> "StatementChanged"
    Error(other) -> string.inspect(other)
  }
}

fn try_run(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
) -> String {
  connection.run(connection, sql, parameters, [], deadline) |> answer_kind
}

fn current_setting(
  connection: Connection,
  name: String,
) -> Result(String, String) {
  use answer <- try(
    rows(connection, "SELECT current_setting($1)", [
      Text(bit_array.from_string(name)),
    ]),
  )
  case answer {
    [[value]] -> Ok(value)
    _ -> Error("not one value: " <> string.inspect(answer))
  }
}

fn backend_pid(connection: Connection) -> Result(String, String) {
  current_value(connection, "SELECT pg_backend_pid()::text")
}

fn current_value(
  connection: Connection,
  sql: String,
) -> Result(String, String) {
  use answer <- try(rows(connection, sql, []))
  case answer {
    [[value]] -> Ok(value)
    _ -> Error("not one value: " <> string.inspect(answer))
  }
}

/// Waits for the event `Reconnected`, and skips the events before it.
fn wait_for_reconnect(events: Subject(ConnectionEvent)) -> Result(Nil, String) {
  case process.receive(events, 5000) {
    Ok(Reconnected) -> Ok(Nil)
    Ok(_other) -> wait_for_reconnect(events)
    Error(Nil) -> Error("no reconnect within 5 seconds")
  }
}

fn start_refusal(config: ConnectionConfig) -> Result(ServerReport, String) {
  case connection.start(config) {
    Ok(started) -> stopped_with(started, Error("the login worked"))
    Error(LoginRefused(ServerRejectedLogin(report))) -> Ok(report)
    Error(other) -> Error(string.inspect(other))
  }
}

fn stopped_with(started: Connection, value: value) -> value {
  connection.stop(started)
  value
}

fn start_error(config: ConnectionConfig) -> Result(ConnectError, String) {
  case connection.start(config) {
    Ok(started) -> stopped_with(started, Error("the connection started"))
    Error(error) -> Ok(error)
  }
}

fn severity_and_code(report: ServerReport) -> #(String, String) {
  #(report.severity, report.code)
}

fn code_and_message(report: ServerReport) -> #(String, String) {
  #(report.code, report.message)
}

fn outcome_rows(outcome: Outcome) -> List(List(Cell)) {
  outcome.result.rows
}

fn column_name(column: ColumnDescription) -> String {
  column.name
}

fn text_cell(text: String) -> Cell {
  Text(bit_array.from_string(text))
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    group("login errors", login_tests(server)),
    group("startup parameters", parameter_tests(server)),
    group("sessions that the server ends", session_tests(server)),
    group("requests", request_tests(server)),
    group("the format of each column and parameter", format_tests(server)),
    group(
      "a column type that changes, with named statements",
      map(type_changes(), cached_change_test(server, _)),
    ),
    group(
      "a column type that changes, with unnamed statements",
      map(type_changes(), unnamed_change_test(server, _)),
    ),
    group("statements after a schema change", schema_tests(server)),
    group("the pool", pool_tests(server)),
  ])
}

// Login errors ----------------------------------------------------------------

fn login_tests(server: Server) {
  [
    it("gives the FATAL 28P01 of the server for a wrong password", fn() {
      check_wrong_password(server)
    }),
    it("gives the 3D000 of the server for a database that does not exist", fn() {
      check_missing_database(server)
    }),
    it("logs in with a password from a function", fn() {
      check_password_function(server)
    }),
  ]
}

fn check_wrong_password(server: Server) {
  // Arrange
  let config =
    login_config(
      server.port,
      "dream",
      servers.database,
      login.password("wrong"),
      [],
    )

  // Act
  let refusal = config |> try(start_refusal) |> result.map(severity_and_code)

  // Assert
  refusal
  |> should
  |> be_equal(Ok(#("FATAL", "28P01")))
  |> or_fail_with("Expected the FATAL 28P01 of the server")
}

fn check_missing_database(server: Server) {
  // Arrange
  let config =
    login_config(
      server.port,
      "dream",
      "parity_no_such_database",
      login.password(servers.password),
      [],
    )

  // Act
  let refusal = config |> try(start_refusal) |> result.map(code_and_message)

  // Assert
  refusal
  |> should
  |> be_equal(
    Ok(#("3D000", "database \"parity_no_such_database\" does not exist")),
  )
  |> or_fail_with("Expected the 3D000 of the server")
}

fn check_password_function(server: Server) {
  // Arrange
  let config =
    login_config(
      server.port,
      "dream",
      servers.database,
      login.password_function(read_password),
      [],
    )

  // Act
  let answer = {
    use connection <- with_connection(config)
    rows(connection, "SELECT 1", [])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([["1"]]))
  |> or_fail_with("Expected the login to work and the query to run")
}

// Startup parameters ------------------------------------------------------------

fn parameter_tests(server: Server) {
  [
    it("sets the caller's application_name", fn() {
      check_settings(server, [#("application_name", "billing")], [
        #("application_name", "billing"),
      ])
    }),
    it("sets the default application_name when the caller gives none", fn() {
      check_settings(server, [], [#("application_name", "dream_postgres")])
    }),
    it("sets the caller's application_name in any case of its name", fn() {
      check_settings(server, [#("Application_Name", "billing")], [
        #("application_name", "billing"),
      ])
    }),
    it("sets application_name between other parameters", fn() {
      check_settings(
        server,
        [
          #("client_encoding", "UTF8"),
          #("application_name", "billing"),
          #("TimeZone", "Europe/Paris"),
        ],
        expected_settings(),
      )
    }),
    it("sets parameters in any order", fn() {
      check_settings(
        server,
        [
          #("TimeZone", "Europe/Paris"),
          #("application_name", "billing"),
          #("client_encoding", "UTF8"),
        ],
        expected_settings(),
      )
    }),
  ]
}

fn expected_settings() -> List(#(String, String)) {
  [
    #("application_name", "billing"),
    #("client_encoding", "UTF8"),
    #("TimeZone", "Europe/Paris"),
  ]
}

fn check_settings(
  server: Server,
  parameters: List(#(String, String)),
  expected: List(#(String, String)),
) {
  // Arrange
  let config =
    login_config(
      server.port,
      "dream",
      servers.database,
      login.password(servers.password),
      parameters,
    )
  let names = map(expected, setting_name)

  // Act
  let settings = {
    use connection <- with_connection(config)
    try_map(names, named_setting(connection, _))
  }

  // Assert
  settings
  |> should
  |> be_equal(Ok(expected))
  |> or_fail_with("Expected the settings of the startup parameters")
}

fn setting_name(setting: #(String, String)) -> String {
  setting.0
}

fn named_setting(
  connection: Connection,
  name: String,
) -> Result(#(String, String), String) {
  current_setting(connection, name) |> result.map(pair.new(name, _))
}

// Sessions that the server ends --------------------------------------------------

fn session_tests(server: Server) {
  [
    it("gives the 57P01 of a session that the server ends during a run", fn() {
      check_session_ended_in_run(server)
    }),
    it("runs on a new session after the server ended the last one", fn() {
      check_run_after_end(server)
    }),
    it("connects again when the server ends an idle session", fn() {
      check_idle_session_ended(server)
    }),
    it("prepares its statements again on the new session", fn() {
      check_reconnect_starts_empty(server)
    }),
    it("tells of a reset by the network as ConnectionReset", fn() {
      check_network_loss(server, reset_client, ConnectionReset)
    }),
    it("tells of a close by the network as SocketClosed", fn() {
      check_network_loss(server, close_client, SocketClosed)
    }),
  ]
}

const terminate_own_session = "SELECT pg_terminate_backend(pg_backend_pid())"

fn check_session_ended_in_run(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    Ok(try_run(connection, terminate_own_session, []))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok("ended 57P01"))
  |> or_fail_with("Expected ServerEndedConnection with 57P01")
}

fn check_run_after_end(server: Server) {
  // Arrange
  let events = process.new_subject()
  let config = dream_config(server.port) |> result.map(with_events(_, events))

  // Act
  let answer = {
    use connection <- with_connection(config)
    let _ended = try_run(connection, terminate_own_session, [])
    use Nil <- try(wait_for_reconnect(events))
    rows(connection, "SELECT 1", [])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([["1"]]))
  |> or_fail_with("Expected the run on the new session")
}

fn check_idle_session_ended(server: Server) {
  // Arrange
  let events = process.new_subject()
  let config = dream_config(server.port) |> result.map(with_events(_, events))

  // Act
  let answer = {
    use connection <- with_connection(config)
    use control <- with_connection(dream_config(server.port))
    use old_pid <- try(backend_pid(connection))
    use _ended <- try(
      rows(control, "SELECT pg_terminate_backend($1::int4)", [
        text_cell(old_pid),
      ]),
    )
    use Nil <- try(wait_for_reconnect(events))
    use new_pid <- try(backend_pid(connection))
    Ok(new_pid != old_pid)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend after the reconnect")
}

fn check_network_loss(
  server: Server,
  breaking: fn(Proxy) -> Nil,
  expected: TransportError,
) {
  // Arrange
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  let config = dream_config(port) |> result.map(with_events(_, events))

  // Act
  let event = {
    use _connection <- with_connection(config)
    breaking(proxy)
    process.receive(events, 5000) |> result.replace_error("no event")
  }

  // Assert
  event
  |> should
  |> be_equal(Ok(Disconnected(ConnectionLost(expected))))
  |> or_fail_with("Expected the loss with its typed error")
}

fn check_reconnect_starts_empty(server: Server) {
  // Arrange
  let events = process.new_subject()
  let config = dream_config(server.port) |> result.map(with_events(_, events))

  // Act
  let answer = {
    use connection <- with_connection(config)
    use _first <- try(rows(connection, "SELECT 42", []))
    let _ended = try_run(connection, terminate_own_session, [])
    use Nil <- try(wait_for_reconnect(events))
    use again <- try(rows(connection, "SELECT 42", []))
    use statements <- try(prepared_statements(connection))
    Ok(#(again, statements))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#([["42"]], ["SELECT 42"])))
  |> or_fail_with("Expected one statement, prepared on the new session")
}

/// The SQL of the prepared statements of the session. A script runs with
/// the simple protocol, so it adds no statement of its own.
fn prepared_statements(connection: Connection) -> Result(List(String), String) {
  connection.run_script(
    connection,
    "SELECT statement FROM pg_prepared_statements ORDER BY statement",
    deadline,
  )
  |> result.map(list.flat_map(_, texts))
  |> result.map(list.flatten)
  |> result.map_error(string.inspect)
}

// Requests ----------------------------------------------------------------------

fn request_tests(server: Server) {
  [
    it("keeps a SET of a reported parameter as the server parameter", fn() {
      check_set_parameter(server)
    }),
    it("gives the 08P01 of the server for a wrong number of parameters", fn() {
      check_parameter_count(server)
    }),
    it("stays usable after the server refuses a parameter", fn() {
      check_refused_parameter(server)
    }),
    it("gives the tag and the rows of inserts, updates and selects", fn() {
      check_insert_update(server)
    }),
    it("names each result column, so a decoder can name it", fn() {
      check_column_names(server)
    }),
  ]
}

fn check_set_parameter(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use tags <- try(script(connection, "SET application_name = 'testset'"))
    use setting <- try(current_setting(connection, "application_name"))
    use parameter <- try(
      connection.server_parameter(connection, "application_name")
      |> result.map_error(string.inspect),
    )
    Ok(#(tags, setting, parameter))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#(["SET"], "testset", Some("testset"))))
  |> or_fail_with("Expected the SET in the setting and the server parameter")
}

fn check_parameter_count(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    let none = try_run(connection, "SELECT $1::int4", [])
    let two =
      try_run(connection, "SELECT $1::int4", [text_cell("1"), text_cell("2")])
    use null <- try(run(connection, "SELECT NULL", []))
    Ok(#(none, two, null.result.rows))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#("08P01", "08P01", [[Null]])))
  |> or_fail_with("Expected 08P01 two times, then the NULL")
}

fn check_refused_parameter(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    let refused =
      try_run(connection, "SELECT $1::uuid", [Binary(<<1, 2, 3, 4, 5>>)])
    use created <- try(
      run(connection, "CREATE TEMP TABLE parity_after_refusal (id integer)", []),
    )
    Ok(#(refused, tag(created)))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#("08P01", "CREATE TABLE")))
  |> or_fail_with("Expected 08P01, then the CREATE TABLE")
}

const insert_update_statements = [
  "CREATE TEMP TABLE parity_rows (id integer PRIMARY KEY, some_text text)",
  "INSERT INTO parity_rows (id, some_text) VALUES (1, 'hello')",
  "UPDATE parity_rows SET some_text = 'hello world'",
  "INSERT INTO parity_rows (id, some_text) VALUES (2, 'hello again')",
  "UPDATE parity_rows SET some_text = 'hello world' WHERE id = 1",
  "UPDATE parity_rows SET some_text = 'goodbye, all' WHERE id = 3",
  "SELECT * FROM parity_rows WHERE id = 3",
]

fn check_insert_update(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use outcomes <- try(
      try_map(insert_update_statements, run(connection, _, [])),
    )
    use all <- try(
      rows(connection, "SELECT * FROM parity_rows ORDER BY id", []),
    )
    use swapped <- try(
      rows(connection, "SELECT some_text, id FROM parity_rows ORDER BY id", []),
    )
    Ok(#(map(outcomes, tag), all, swapped))
  }

  // Assert
  answer
  |> should
  |> be_equal(
    Ok(
      #(
        [
          "CREATE TABLE", "INSERT 0 1", "UPDATE 1", "INSERT 0 1", "UPDATE 1",
          "UPDATE 0", "SELECT 0",
        ],
        [["1", "hello world"], ["2", "hello again"]],
        [["hello world", "1"], ["hello again", "2"]],
      ),
    ),
  )
  |> or_fail_with("Expected each tag and the rows in order")
}

fn check_column_names(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use outcome <- try(
      run(connection, "SELECT 1 AS first_column, 'x' AS second_column, 2", []),
    )
    Ok(map(outcome.columns, column_name))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(["first_column", "second_column", "?column?"]))
  |> or_fail_with("Expected the name of each column")
}

// Formats -----------------------------------------------------------------------

fn format_tests(server: Server) {
  [
    it("gives each column in the format the caller asks for it", fn() {
      check_mixed_formats(server)
    }),
    it("sends a text parameter for a type with no binary format", fn() {
      check_text_parameter(server)
    }),
    it("sends a NULL parameter for a type with no binary format", fn() {
      check_null_parameter(server)
    }),
    it("writes and reads a row with binary and text cells", fn() {
      check_round_trip(server)
    }),
  ]
}

fn run_formats(
  connection: Connection,
  sql: String,
  parameters: List(Cell),
  formats: List(Format),
) -> Result(List(List(Cell)), String) {
  connection.run(connection, sql, parameters, formats, deadline)
  |> result.map(outcome_rows)
  |> result.map_error(string.inspect)
}

fn check_mixed_formats(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    run_formats(
      connection,
      "SELECT 1::int4, 'dream=r/dream'::aclitem, '[1,2]'::int4range",
      [],
      [BinaryFormat, TextFormat, BinaryFormat],
    )
  }

  // Assert
  answer
  |> should
  |> be_equal(
    Ok([
      [
        Binary(<<1:32>>),
        Text(<<"dream=r/dream">>),
        Binary(<<2, 4:32, 1:32, 4:32, 3:32>>),
      ],
    ]),
  )
  |> or_fail_with("Expected binary, text and binary cells")
}

fn check_text_parameter(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    rows(connection, "SELECT $1::aclitem::text", [text_cell("dream=r/dream")])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([["dream=r/dream"]]))
  |> or_fail_with("Expected the aclitem from its text")
}

fn check_null_parameter(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    run_formats(connection, "SELECT $1::aclitem", [Null], [])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([[Null]]))
  |> or_fail_with("Expected a NULL aclitem")
}

fn check_round_trip(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use _created <- try(script(
      connection,
      "CREATE TEMP TABLE parity_acl (id int4, acl aclitem)",
    ))
    use _inserted <- try(
      run(connection, "INSERT INTO parity_acl (id, acl) VALUES ($1, $2)", [
        Binary(<<7:32>>),
        text_cell("dream=arw/dream"),
      ]),
    )
    run_formats(connection, "SELECT id, acl FROM parity_acl", [], [
      BinaryFormat,
      TextFormat,
    ])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([[Binary(<<7:32>>), Text(<<"dream=arw/dream">>)]]))
  |> or_fail_with("Expected the row as it was written")
}

// Column type changes -------------------------------------------------------------

/// A column of type `from` with `value`, altered to `to` with `using`. The
/// value of the new type as text is `expected`.
type TypeChange {
  TypeChange(
    from: String,
    value: String,
    to: String,
    using: String,
    expected: String,
  )
}

fn type_changes() -> List(TypeChange) {
  [
    TypeChange("int8", "5", "float8", "c::float8", "5"),
    TypeChange(
      "timestamp",
      "'2020-01-02 03:04:05'",
      "timestamptz",
      "c::timestamptz",
      "2020-01-02 03:04:05+00",
    ),
    TypeChange(
      "int8",
      "1600000000",
      "timestamp",
      "to_timestamp(c)::timestamp",
      "2020-09-13 12:26:40",
    ),
    TypeChange(
      "int8",
      "5",
      "aclitem",
      "'dream=r/dream'::aclitem",
      "dream=r/dream",
    ),
    TypeChange("aclitem", "'dream=r/dream'", "int8", "1", "1"),
    TypeChange("int4", "7", "text", "c::text", "7"),
    TypeChange("float8", "1.5", "int8", "c::int8", "2"),
    TypeChange("int4", "7", "int8", "c::int8", "7"),
    TypeChange("int8", "7", "text", "c::text", "7"),
    TypeChange("int4", "7", "numeric", "c::numeric", "7"),
    TypeChange("text", "'top.a'", "ltree", "c::ltree", "top.a"),
  ]
}

fn change_name(change: TypeChange) -> String {
  change.from <> " to " <> change.to
}

fn cached_change_test(server: Server, change: TypeChange) {
  it(
    "gives StatementChanged, then the new value, for " <> change_name(change),
    fn() { check_cached_change(server, change) },
  )
}

fn unnamed_change_test(server: Server, change: TypeChange) {
  it("gives the new value at once for " <> change_name(change), fn() {
    check_unnamed_change(server, change)
  })
}

const changing_select = "SELECT c FROM parity_change"

/// Makes the table, runs the select two times, and alters the column.
fn prepare_change(
  connection: Connection,
  change: TypeChange,
) -> Result(Nil, String) {
  use _created <- try(script(
    connection,
    "CREATE TEMP TABLE parity_change (c "
      <> change.from
      <> "); INSERT INTO parity_change VALUES ("
      <> change.value
      <> ")",
  ))
  use _first <- try(run(connection, changing_select, []))
  use _second <- try(run(connection, changing_select, []))
  script(
    connection,
    "ALTER TABLE parity_change ALTER COLUMN c TYPE "
      <> change.to
      <> " USING "
      <> change.using,
  )
  |> result.replace(Nil)
}

fn check_cached_change(server: Server, change: TypeChange) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use Nil <- try(prepare_change(connection, change))
    let changed = try_run(connection, changing_select, [])
    use again <- try(rows(connection, changing_select, []))
    Ok(#(changed, again))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#("StatementChanged", [[change.expected]])))
  |> or_fail_with("Expected StatementChanged, then the value of the new type")
}

fn check_unnamed_change(server: Server, change: TypeChange) {
  // Arrange
  let config =
    dream_config(server.port) |> result.map(with_caching(_, UnnamedStatements))

  // Act
  let answer = {
    use connection <- with_connection(config)
    use Nil <- try(prepare_change(connection, change))
    rows(connection, changing_select, [])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([[change.expected]]))
  |> or_fail_with("Expected the value of the new type")
}

// Schema changes ------------------------------------------------------------------

fn schema_tests(server: Server) {
  [
    it("inserts one row for each run of a changed INSERT RETURNING", fn() {
      check_insert_returning(server, CacheStatements(512))
    }),
    it("inserts one row for each changed INSERT RETURNING, unnamed", fn() {
      check_insert_returning(server, UnnamedStatements)
    }),
    it("gives a column added to a text column after StatementChanged", fn() {
      check_added_column(
        server,
        AddedColumn("c aclitem", "'dream=r/dream'", "d int4 DEFAULT 3", [
          "dream=r/dream", "3",
        ]),
      )
    }),
    it("gives a text column added to a column after StatementChanged", fn() {
      check_added_column(
        server,
        AddedColumn("c int4", "1", "d aclitem DEFAULT 'dream=r/dream'", [
          "1", "dream=r/dream",
        ]),
      )
    }),
    it("gives the added column at once with unnamed statements", fn() {
      check_unnamed_added_column(server)
    }),
    it("refuses a changed statement in a transaction, then prepares it", fn() {
      check_change_in_transaction(server)
    }),
  ]
}

const returning_insert =
  "INSERT INTO parity_returning (v) VALUES (1) RETURNING w"

fn check_insert_returning(server: Server, caching: StatementCaching) {
  // Arrange
  let config = dream_config(server.port) |> result.map(with_caching(_, caching))

  // Act
  let answer = {
    use connection <- with_connection(config)
    use _created <- try(script(
      connection,
      "CREATE TEMP TABLE parity_returning (v int4, w aclitem DEFAULT 'dream=r/dream')",
    ))
    use first <- try(rows(connection, returning_insert, []))
    use _altered <- try(script(
      connection,
      "ALTER TABLE parity_returning ALTER COLUMN w DROP DEFAULT; "
        <> "ALTER TABLE parity_returning ALTER COLUMN w TYPE int8 USING 1; "
        <> "ALTER TABLE parity_returning ALTER COLUMN w SET DEFAULT 5",
    ))
    use after <- try(returned_after_change(connection))
    use count <- try(
      rows(connection, "SELECT count(*) FROM parity_returning", []),
    )
    Ok(#(first, after, count))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#([["dream=r/dream"]], [["5"]], [["2"]])))
  |> or_fail_with("Expected the new value and two rows in all")
}

/// The rows of the INSERT after the change. A StatementChanged means that
/// the INSERT did not run: the caller runs it again.
fn returned_after_change(
  connection: Connection,
) -> Result(List(List(String)), String) {
  case connection.run(connection, returning_insert, [], [], deadline) {
    Ok(outcome) -> Ok(texts(outcome))
    Error(StatementChanged(_description)) ->
      rows(connection, returning_insert, [])
    Error(other) -> Error(string.inspect(other))
  }
}

/// A table with `column` and one row of `value`, that gets the column
/// `added`. The row then holds `expected`.
type AddedColumn {
  AddedColumn(
    column: String,
    value: String,
    added: String,
    expected: List(String),
  )
}

fn check_added_column(server: Server, change: AddedColumn) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use _created <- try(script(
      connection,
      "CREATE TEMP TABLE parity_added ("
        <> change.column
        <> "); INSERT INTO parity_added VALUES ("
        <> change.value
        <> ")",
    ))
    use _first <- try(run(connection, "SELECT * FROM parity_added", []))
    use _altered <- try(script(
      connection,
      "ALTER TABLE parity_added ADD COLUMN " <> change.added,
    ))
    let changed = try_run(connection, "SELECT * FROM parity_added", [])
    use again <- try(rows(connection, "SELECT * FROM parity_added", []))
    Ok(#(changed, list.flatten(again)))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#("StatementChanged", change.expected)))
  |> or_fail_with("Expected StatementChanged, then both columns")
}

fn check_unnamed_added_column(server: Server) {
  // Arrange
  let config =
    dream_config(server.port) |> result.map(with_caching(_, UnnamedStatements))

  // Act
  let answer = {
    use connection <- with_connection(config)
    use _created <- try(script(
      connection,
      "CREATE TEMP TABLE parity_added (c aclitem); "
        <> "INSERT INTO parity_added VALUES ('dream=r/dream')",
    ))
    use _first <- try(run(connection, "SELECT * FROM parity_added", []))
    use _altered <- try(script(
      connection,
      "ALTER TABLE parity_added ADD COLUMN d int4 DEFAULT 3",
    ))
    rows(connection, "SELECT * FROM parity_added", [])
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([["dream=r/dream", "3"]]))
  |> or_fail_with("Expected both columns")
}

fn check_change_in_transaction(server: Server) {
  // Act
  let answer = {
    use connection <- with_connection(dream_config(server.port))
    use _created <- try(script(
      connection,
      "CREATE TEMP TABLE parity_in_transaction (c int8); "
        <> "INSERT INTO parity_in_transaction VALUES (5)",
    ))
    use _first <- try(
      run(connection, "SELECT c FROM parity_in_transaction", []),
    )
    use _altered <- try(script(
      connection,
      "ALTER TABLE parity_in_transaction ALTER COLUMN c TYPE float8; BEGIN",
    ))
    let refused = try_run(connection, "SELECT c FROM parity_in_transaction", [])
    let next = try_run(connection, "SELECT 1", [])
    use _rolled_back <- try(script(connection, "ROLLBACK"))
    use after <- try(
      rows(connection, "SELECT c FROM parity_in_transaction", []),
    )
    Ok(#(refused, next, after))
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok(#("0A000", "25P02", [["5"]])))
  |> or_fail_with("Expected 0A000, 25P02, then the float8 value")
}

// Addresses ---------------------------------------------------------------------

fn address_tests() {
  [
    it("refuses a negative port", fn() {
      // Act
      let refused = transport.address("localhost", -1) |> result.replace(Nil)

      // Assert
      refused
      |> should
      |> be_equal(Error(InvalidPort(-1)))
      |> or_fail_with("Expected InvalidPort(-1)")
    }),
    it("takes the ports 1 and 65535 and an IP address as the host", fn() {
      // Act
      let taken = #(
        transport.address("127.0.0.1", 1) |> result.map(transport.port),
        transport.address("::1", 65_535) |> result.map(transport.host),
      )

      // Assert
      taken
      |> should
      |> be_equal(#(Ok(1), Ok("::1")))
      |> or_fail_with("Expected both addresses")
    }),
    it("gives DnsLookupFailed for a host with no address", fn() {
      // Arrange
      let config = {
        use address <- try(
          transport.address("no-such-host.invalid", 5432)
          |> result.map_error(string.inspect),
        )
        use settings <- try(dream_config(5441))
        Ok(
          ConnectionConfig(
            ..settings,
            transport: TransportConfig(..settings.transport, address:),
          ),
        )
      }

      // Act
      let failed = config |> try(start_error)

      // Assert
      failed
      |> should
      |> be_equal(Ok(TransportRefused(DnsLookupFailed("no-such-host.invalid"))))
      |> or_fail_with("Expected DnsLookupFailed with the host")
    }),
    it("gives ServerRefusedTls for a server with no TLS", fn() {
      // Arrange
      let config =
        dream_config(server_without_tls)
        |> result.map(with_tls(
          _,
          RequireTls(NoCertificateCheck, PostgresNegotiation),
        ))

      // Act
      let failed = config |> try(start_error)

      // Assert
      failed
      |> should
      |> be_equal(Ok(TransportRefused(ServerRefusedTls)))
      |> or_fail_with("Expected ServerRefusedTls")
    }),
  ]
}

// Closed sockets ----------------------------------------------------------------

const missing_authority_file = "test/fixtures/ssl/parity_missing_ca.crt"

const unreadable_authority =
  TlsFailed(AuthorityFileUnreadable(missing_authority_file, "enoent"))

fn socket_tests() {
  [
    it("closes the socket when the server refuses the login", fn() {
      // Arrange
      let #(port, server) = start_login_refusing_server()
      let config = dream_config(port)

      // Act
      let refusal =
        config |> try(start_refusal) |> result.map(severity_and_code)
      let closed = parity_client_closed(server)

      // Assert
      #(refusal, closed)
      |> should
      |> be_equal(#(Ok(#("FATAL", "28P01")), True))
      |> or_fail_with("Expected the refusal and a closed socket")
    }),
    it("closes the socket when the CA file cannot be read", fn() {
      // Arrange
      let #(port, server) = start_fake_server(Answer(<<"S">>))
      let tls =
        RequireTls(
          CheckAuthorityAndHost(AuthorityFile(missing_authority_file)),
          PostgresNegotiation,
        )

      // Act
      let failed = connect_only(port, tls)
      let closed = fake_client_closed(server)

      // Assert
      #(failed, closed)
      |> should
      |> be_equal(#(Error(string.inspect(unreadable_authority)), True))
      |> or_fail_with("Expected AuthorityFileUnreadable and a closed socket")
    }),
    it("gives SocketClosed and closes the socket when the server closes", fn() {
      // Arrange
      let #(port, server) = start_closing_server()

      // Act
      let failed =
        connect_only(port, RequireTls(NoCertificateCheck, PostgresNegotiation))
      let closed = parity_client_closed(server)

      // Assert
      #(failed, closed)
      |> should
      |> be_equal(#(Error(string.inspect(SocketClosed)), True))
      |> or_fail_with("Expected SocketClosed and a closed socket")
    }),
  ]
}

fn connect_only(port: Int, tls: Tls) -> Result(Nil, String) {
  use address <- try(
    transport.address("localhost", port) |> result.map_error(string.inspect),
  )
  transport.connect(TransportConfig(address, tls, 5000, 5000))
  |> result.map(transport.close)
  |> result.map_error(string.inspect)
}

// The password ------------------------------------------------------------------

/// The user `dream_md5` logs in with the password `dream`. Its own name
/// prints as `<<"dream_md5">>`, so only the password prints as
/// `<<"dream">>`.
fn md5_config() -> Result(ConnectionConfig, String) {
  login_config(
    5441,
    "dream_md5",
    servers.database,
    login.password(servers.password),
    [],
  )
}

fn password_tests() {
  [
    it("stays out of the status of the connection process", fn() {
      // Act
      let shown = {
        use connection <- with_connection(md5_config())
        Ok(status_holds(pid_of(connection), printed_password))
      }

      // Assert
      shown
      |> should
      |> be_equal(Ok(False))
      |> or_fail_with("Expected no password in the status")
    }),
    it("stays out of the status of the supervisor", fn() {
      // Act
      let shown = {
        use config <- try(md5_config())
        use started <- try(
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.add(connection.supervised(config))
          |> static_supervisor.start
          |> result.map_error(string.inspect),
        )
        let holds = status_holds(started.pid, printed_password)
        stop_process(started.pid)
        Ok(holds)
      }

      // Assert
      shown
      |> should
      |> be_equal(Ok(False))
      |> or_fail_with("Expected no password in the status")
    }),
  ]
}

// The pool ----------------------------------------------------------------------

fn pool_config(
  connection: ConnectionConfig,
  extra: extra,
) -> PoolConfig(extra) {
  PoolConfig(
    connection:,
    health_check_interval_milliseconds: 60_000,
    health_check_deadline_milliseconds: 5000,
    rollback_deadline_milliseconds: 5000,
    shutdown_deadline_milliseconds: 5000,
    extra:,
  )
}

fn with_pool(
  config: Result(PoolConfig(extra), String),
  size: Int,
  body: fn(Pool(extra)) -> Result(value, String),
) -> Result(value, String) {
  use settings <- try(config)
  use started <- try(
    pool.start(settings, size) |> result.map_error(string.inspect),
  )
  let value = body(started)
  pool.stop(started, 1000)
  value
}

fn held(
  pool: Pool(extra),
  body: fn(Connection) -> Result(value, String),
) -> Result(value, String) {
  pool.hold(pool, deadline, body)
  |> result.map_error(string.inspect)
  |> result.flatten
}

fn held_backend_pid(pool: Pool(extra)) -> Result(String, String) {
  held(pool, backend_pid)
}

fn held_one(connection: Connection) -> Result(List(List(String)), String) {
  rows(connection, "SELECT 1", [])
}

fn held_two(
  pool: Pool(extra),
  first: Connection,
) -> Result(List(List(String)), String) {
  use first_rows <- try(held_one(first))
  use second_rows <- try(held(pool, held_one))
  Ok(list.append(first_rows, second_rows))
}

/// Asks for the status until all connections are available: no sleep.
fn wait_for_available(
  pool: Pool(extra),
  wanted: Int,
  attempts: Int,
) -> Result(PoolStatus, String) {
  use current <- try(pool.status(pool) |> result.map_error(string.inspect))
  case current.available == wanted, attempts {
    True, _ -> Ok(current)
    False, 0 -> Error("the connections did not come back")
    False, _ -> wait_for_available(pool, wanted, attempts - 1)
  }
}

fn pool_tests(server: Server) {
  [
    it("runs a query on a held connection", fn() { check_held_query(server) }),
    it("gives each connection back when its hold ends", fn() {
      check_holds_end(server)
    }),
    it("replaces an idle connection whose socket closed", fn() {
      check_idle_socket_closed(server)
    }),
  ]
}

fn check_held_query(server: Server) {
  // Arrange
  let config = dream_config(server.port) |> result.map(pool_config(_, Nil))

  // Act
  let answer = {
    use pool <- with_pool(config, 1)
    held(pool, held_one)
  }

  // Assert
  answer
  |> should
  |> be_equal(Ok([["1"]]))
  |> or_fail_with("Expected the query to run on the held connection")
}

fn check_holds_end(server: Server) {
  // Arrange
  let config = dream_config(server.port) |> result.map(pool_config(_, Nil))

  // Act
  let status = {
    use pool <- with_pool(config, 2)
    use _rows <- try(held(pool, held_two(pool, _)))
    wait_for_available(pool, 2, 1000)
  }

  // Assert
  status
  |> should
  |> be_equal(
    Ok(PoolStatus(
      size: 2,
      connected: 2,
      available: 2,
      held: 0,
      waiting: 0,
      last_connect_error: None,
    )),
  )
  |> or_fail_with("Expected both connections back and free")
}

fn check_idle_socket_closed(server: Server) {
  // Arrange
  let #(port, proxy) = start_proxy(server.port)
  let events = process.new_subject()
  let config =
    dream_config(port)
    |> result.map(with_events(_, events))
    |> result.map(pool_config(_, Nil))

  // Act
  let changed = {
    use pool <- with_pool(config, 1)
    use first <- try(held_backend_pid(pool))
    close_client(proxy)
    use Nil <- try(wait_for_reconnect(events))
    use second <- try(held_backend_pid(pool))
    Ok(first != second)
  }

  // Assert
  changed
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected a new backend after the socket closed")
}
