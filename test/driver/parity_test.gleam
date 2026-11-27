//// The parity tests: behaviors that the Common Test suites of the pgo fork
//// proved, run on the driver, on the driver servers of PostgreSQL 16 to
//// 19. `test/driver/PARITY.md` maps each case of the fork to its test.
////
//// Each describe has its own kind of setup: a connection, a connection
//// through a proxy, a pool, a pool through a proxy, nothing, or a
//// supervised connection. Each start is in a setup whose teardown stops it.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type StatementCaching, CacheStatements,
  ConnectionLost, Disconnected, SocketFailed, TransportRefused,
  UnnamedStatements, run, run_script, server_parameter, start,
}
import dream_postgres/driver/pool.{PoolStatus}
import dream_postgres/driver/transport.{
  AuthorityFile, AuthorityFileUnreadable, CheckAuthorityAndHost, ConnectionReset,
  DnsLookupFailed, InvalidPort, NoCertificateCheck, PostgresNegotiation,
  RequireTls, ServerRefusedTls, SocketClosed, TlsFailed, address,
}
import dream_postgres/internal/cell.{
  type Cell, Binary, BinaryFormat, Null, Text, TextFormat,
}
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_some, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/fake_server.{
  Answer, start_closing_server, start_fake_server, start_login_refusing_server,
}
import driver/proxy.{close_client, reset_client}
import driver/server_connection.{
  type ProxiedConnection, backend_pid, caching_config, connection_config,
  connection_setup, database_config, host_config, next_event,
  on_proxied_connection, parameter_config, parameters_config,
  password_function_config, pid_of, proxied_setup, query_text,
  run_failing_statement, run_failing_statement_with_parameters, run_setup_script,
  run_setup_statement, start_test_configured, start_test_proxied,
  stop_connection, stop_proxied, supervised_connection_setup, terminate_backend,
  tls_config, user_config, wait_for_proxied_reconnect, wait_for_reconnect,
}
import driver/server_pool.{
  type PoolSession, type ProxiedPool, held_backend_pid, hold_connection,
  pool_session_setup, pool_status, proxied_pool_setup, start_test_pool,
  start_test_proxied_pool, stop_pool_session, stop_proxied_pool,
  wait_for_member_free, wait_for_member_free_count, while_holding,
}
import driver/servers.{
  type Server, driver_servers, first_driver_server, server_without_tls,
}
import fixtures/driver_tls.{transport_config}
import fixtures/transport_connect.{connect_with_minute_deadline}
import gleam/bit_array
import gleam/int.{to_string}
import gleam/list.{append, map, try_map}
import gleam/option.{None}
import gleam/result.{map_error, try}
import gleam/string.{inspect, join}
import matchers/be_different_parts.{be_different_parts}
import matchers/extract_changed_column_names.{extract_changed_column_names}
import matchers/extract_client_closed.{extract_client_closed}
import matchers/extract_column_names.{extract_column_names}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_command_tag.{extract_command_tag}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_first.{extract_first}
import matchers/extract_login_refusal_code.{extract_login_refusal_code}
import matchers/extract_login_refusal_report.{extract_login_refusal_report}
import matchers/extract_outcome_tags.{extract_outcome_tags}
import matchers/extract_printed_status.{extract_printed_status}
import matchers/extract_report_code.{extract_report_code}
import matchers/extract_report_message.{extract_report_message}
import matchers/extract_report_severity.{extract_report_severity}
import matchers/extract_result_columns.{extract_result_columns}
import matchers/extract_run_failure.{extract_run_failure}
import matchers/extract_run_refusal_code.{extract_run_refusal_code}
import matchers/not_contain_text.{not_contain_text}

/// The longest time of each request.
const deadline = 5000

/// The printed form of the password `dream`, as a binary.
const printed_password = "<<\"dream\">>"

/// The tests of the parity suite. The describes run one after the other;
/// the tests of one describe run at the same time.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver parity with the pgo fork", [
    connection_tests(),
    proxied_tests(),
    pool_tests(),
    proxied_pool_tests(),
    unstarted_tests(),
    supervisor_tests(),
  ])
}

// Settings --------------------------------------------------------------------

/// A `before_each` hook that starts a connection as `dream` to `server`,
/// with the session time zone UTC and the statement caching `caching`.
fn dream_connection(
  server: Server,
  caching: StatementCaching,
) -> fn(Connection) -> Result(Connection, String) {
  start_test_configured(
    parameter_config(server.port, "TimeZone", "UTC")
    |> result.map(caching_config(_, caching)),
  )
}

/// The user `dream_md5` logs in with the password `dream`. Its own name
/// prints as `<<"dream_md5">>`, so only the password prints as
/// `<<"dream">>`.
fn md5_config() -> Result(ConnectionConfig, String) {
  user_config(first_driver_server.port, "dream_md5", servers.password)
}

// With a connection of its own ------------------------------------------------

fn connection_tests() -> TestSuite {
  describe(
    "with a connection of its own",
    connection_setup(first_driver_server),
    [
      after_each(stop_connection),
      group("on each driver server", map(driver_servers(), server_tests)),
      group("the password", [
        before_each(start_test_configured(md5_config())),
        it("stays out of the status of the connection process", fn(connection) {
          pid_of(connection)
          |> should
          |> extract_printed_status
          |> not_contain_text(printed_password)
          |> or_fail_with("Expected no password in the status")
        }),
      ]),
    ],
  )
}

fn server_tests(server: Server) -> ContextNode(Connection) {
  group("PostgreSQL " <> to_string(server.version), [
    group("login errors", [
      before_each(start_test_configured(password_function_config(server.port))),
      it("logs in with a password from a function", fn(connection) {
        // Act
        let outcome =
          run(connection, connection.statement("SELECT 1"), [], [], deadline)

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"1">>)]])
        |> or_fail_with("Expected the login to work and the query to run")
      }),
    ]),
    group("startup parameters", map(setting_cases(), setting_test(server, _))),
    group("sessions that the server ends", [
      before_each(dream_connection(server, CacheStatements(512))),
      it(
        "gives the 57P01 of a session that the server ends during a run",
        fn(connection) {
          // Act
          let answer =
            run(
              connection,
              connection.statement(terminate_own_session),
              [],
              [],
              deadline,
            )

          // Assert
          answer
          |> should
          |> be_error
          |> extract_run_failure
          |> extract_ending_report
          |> extract_report_code
          |> be_equal("57P01")
          |> or_fail_with("Expected ServerEndedConnection with 57P01")
        },
      ),
    ]),
    group("requests", request_tests(server)),
    group("the format of each column and parameter", format_tests(server)),
    group("a column type that changes, with named statements", [
      before_each(dream_connection(server, CacheStatements(512))),
      ..map(type_changes(), cached_change_tests)
    ]),
    group("a column type that changes, with unnamed statements", [
      before_each(dream_connection(server, UnnamedStatements)),
      ..map(type_changes(), unnamed_change_tests)
    ]),
    group("statements after a schema change", schema_tests(server)),
  ])
}

const terminate_own_session = "SELECT pg_terminate_backend(pg_backend_pid())"

// Startup parameters ------------------------------------------------------------

/// A test of the settings that a connection with the startup parameters
/// `parameters` has: `sql` gives the rows `expected`.
type SettingCase {
  SettingCase(
    name: String,
    setup: String,
    parameters: List(#(String, String)),
    sql: String,
    expected: List(List(Cell)),
  )
}

fn setting_cases() -> List(SettingCase) {
  [
    SettingCase(
      name: "sets the caller's application_name",
      setup: "with application_name",
      parameters: [#("application_name", "billing")],
      sql: application_name_setting,
      expected: [[Text(<<"billing">>)]],
    ),
    SettingCase(
      name: "sets the default application_name when the caller gives none",
      setup: "with no parameter",
      parameters: [],
      sql: application_name_setting,
      expected: [[Text(<<"dream_postgres">>)]],
    ),
    SettingCase(
      name: "sets the caller's application_name in any case of its name",
      setup: "with Application_Name",
      parameters: [#("Application_Name", "billing")],
      sql: application_name_setting,
      expected: [[Text(<<"billing">>)]],
    ),
    SettingCase(
      name: "sets application_name between other parameters",
      setup: "with application_name between two parameters",
      parameters: [
        #("client_encoding", "UTF8"),
        #("application_name", "billing"),
        #("TimeZone", "Europe/Paris"),
      ],
      sql: three_settings,
      expected: three_settings_rows,
    ),
    SettingCase(
      name: "sets parameters in any order",
      setup: "with the parameters in another order",
      parameters: [
        #("TimeZone", "Europe/Paris"),
        #("application_name", "billing"),
        #("client_encoding", "UTF8"),
      ],
      sql: three_settings,
      expected: three_settings_rows,
    ),
  ]
}

const application_name_setting = "SELECT current_setting('application_name')"

const three_settings =
  "SELECT current_setting('application_name'), current_setting('client_encoding'), current_setting('TimeZone')"

const three_settings_rows = [
  [Text(<<"billing">>), Text(<<"UTF8">>), Text(<<"Europe/Paris">>)],
]

fn setting_test(
  server: Server,
  test_case: SettingCase,
) -> ContextNode(Connection) {
  group(test_case.setup, [
    before_each(
      start_test_configured(parameters_config(server.port, test_case.parameters)),
    ),
    it(test_case.name, fn(connection) {
      // Act
      let outcome =
        run(connection, connection.statement(test_case.sql), [], [], deadline)

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal(test_case.expected)
      |> or_fail_with("Expected the settings of the startup parameters")
    }),
  ])
}

// Requests ----------------------------------------------------------------------

const set_application_name = "SET application_name = 'testset'"

const unreadable_uuid = "SELECT $1::uuid"

const insert_update_statements = [
  "CREATE TEMP TABLE parity_rows (id integer PRIMARY KEY, some_text text)",
  "INSERT INTO parity_rows (id, some_text) VALUES (1, 'hello')",
  "UPDATE parity_rows SET some_text = 'hello world'",
  "INSERT INTO parity_rows (id, some_text) VALUES (2, 'hello again')",
  "UPDATE parity_rows SET some_text = 'hello world' WHERE id = 1",
  "UPDATE parity_rows SET some_text = 'goodbye, all' WHERE id = 3",
  "SELECT * FROM parity_rows WHERE id = 3",
]

fn request_tests(server: Server) -> List(ContextNode(Connection)) {
  [
    before_each(dream_connection(server, CacheStatements(512))),
    it("gives the tag SET for a SET of a reported parameter", fn(connection) {
      // Act
      let outcomes =
        run_script(
          connection,
          connection.statement(set_application_name),
          deadline,
        )

      // Assert
      outcomes
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SET"])
      |> or_fail_with("Expected the tag SET")
    }),
    group("after a SET of a reported parameter", set_tests()),
    group("with a wrong number of parameters", parameter_count_tests()),
    group("with a parameter that the server cannot read", refusal_tests()),
    group("with inserts and updates", insert_update_tests()),
    it("names each result column, so a decoder can name it", fn(connection) {
      // Act
      let outcome =
        run(
          connection,
          connection.statement(
            "SELECT 1 AS first_column, 'x' AS second_column, 2",
          ),
          [],
          [],
          deadline,
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_result_columns
      |> extract_column_names
      |> be_equal(["first_column", "second_column", "?column?"])
      |> or_fail_with("Expected the name of each column")
    }),
  ]
}

fn set_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script(set_application_name)),
    it(
      "keeps a SET of a reported parameter as the server parameter",
      fn(connection) {
        // Act
        let parameter = server_parameter(connection, "application_name")

        // Assert
        parameter
        |> should
        |> be_ok
        |> be_some
        |> be_equal("testset")
        |> or_fail_with("Expected the SET in the server parameter")
      },
    ),
    it("keeps a SET of a reported parameter as the setting", fn(connection) {
      // Act
      let outcome =
        run(
          connection,
          connection.statement(application_name_setting),
          [],
          [],
          deadline,
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"testset">>)]])
      |> or_fail_with("Expected the SET in the setting")
    }),
  ]
}

fn parameter_count_tests() -> List(ContextNode(Connection)) {
  [
    it(
      "gives the 08P01 of the server for a wrong number of parameters",
      fn(connection) {
        // Act
        let answer =
          run(
            connection,
            connection.statement("SELECT $1::int4"),
            [],
            [],
            deadline,
          )

        // Assert
        answer
        |> should
        |> be_error
        |> extract_run_refusal_code
        |> be_equal("08P01")
        |> or_fail_with("Expected 08P01 for no parameter")
      },
    ),
    it("gives the 08P01 of the server for too many parameters", fn(connection) {
      // Act
      let answer =
        run(
          connection,
          connection.statement("SELECT $1::int4"),
          [Text(<<"1">>), Text(<<"2">>)],
          [],
          deadline,
        )

      // Assert
      answer
      |> should
      |> be_error
      |> extract_run_refusal_code
      |> be_equal("08P01")
      |> or_fail_with("Expected 08P01 for two parameters")
    }),
    group("after the refusal", [
      before_each(run_failing_statement("SELECT $1::int4")),
      it("gives the NULL of SELECT NULL after the refusal", fn(connection) {
        // Act
        let outcome =
          run(connection, connection.statement("SELECT NULL"), [], [], deadline)

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Null]])
        |> or_fail_with("Expected the NULL")
      }),
    ]),
  ]
}

fn refusal_tests() -> List(ContextNode(Connection)) {
  [
    it(
      "gives the 08P01 of the server for a parameter it cannot read",
      fn(connection) {
        // Act
        let answer =
          run(
            connection,
            connection.statement(unreadable_uuid),
            [Binary(<<1, 2, 3, 4, 5>>)],
            [],
            deadline,
          )

        // Assert
        answer
        |> should
        |> be_error
        |> extract_run_refusal_code
        |> be_equal("08P01")
        |> or_fail_with("Expected 08P01 for the parameter")
      },
    ),
    group("after the refusal", [
      before_each(
        run_failing_statement_with_parameters(unreadable_uuid, [
          Binary(<<1, 2, 3, 4, 5>>),
        ]),
      ),
      it("stays usable after the server refuses a parameter", fn(connection) {
        // Act
        let outcome =
          run(
            connection,
            connection.statement(
              "CREATE TEMP TABLE parity_after_refusal (id integer)",
            ),
            [],
            [],
            deadline,
          )

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_tag
        |> be_equal("CREATE TABLE")
        |> or_fail_with("Expected the CREATE TABLE after the refusal")
      }),
    ]),
  ]
}

fn insert_update_tests() -> List(ContextNode(Connection)) {
  [
    it(
      "gives the tag and the rows of inserts, updates and selects",
      fn(connection) {
        // Act
        let outcomes =
          insert_update_statements
          |> map(connection.statement)
          |> try_map(run(connection, _, [], [], deadline))

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_outcome_tags
        |> be_equal([
          "CREATE TABLE", "INSERT 0 1", "UPDATE 1", "INSERT 0 1", "UPDATE 1",
          "UPDATE 0", "SELECT 0",
        ])
        |> or_fail_with("Expected each tag in order")
      },
    ),
    group("after them", [
      before_each(run_setup_script(join(insert_update_statements, "; "))),
      it("gives the rows of the inserts and updates in order", fn(connection) {
        // Act
        let outcome =
          run(
            connection,
            connection.statement("SELECT * FROM parity_rows ORDER BY id"),
            [],
            [],
            deadline,
          )

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([
          [Text(<<"1">>), Text(<<"hello world">>)],
          [Text(<<"2">>), Text(<<"hello again">>)],
        ])
        |> or_fail_with("Expected the rows in order")
      }),
      it(
        "gives the columns of each row in the order of the select",
        fn(connection) {
          // Act
          let outcome =
            run(
              connection,
              connection.statement(
                "SELECT some_text, id FROM parity_rows ORDER BY id",
              ),
              [],
              [],
              deadline,
            )

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([
            [Text(<<"hello world">>), Text(<<"1">>)],
            [Text(<<"hello again">>), Text(<<"2">>)],
          ])
          |> or_fail_with("Expected the columns in the order of the select")
        },
      ),
    ]),
  ]
}

// Formats -----------------------------------------------------------------------

fn format_tests(server: Server) -> List(ContextNode(Connection)) {
  [
    before_each(dream_connection(server, CacheStatements(512))),
    it("gives each column in the format the caller asks for it", fn(connection) {
      // Act
      let outcome =
        run(
          connection,
          connection.statement(
            "SELECT 1::int4, 'dream=r/dream'::aclitem, '[1,2]'::int4range",
          ),
          [],
          [BinaryFormat, TextFormat, BinaryFormat],
          deadline,
        )

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([
        [
          Binary(<<1:32>>),
          Text(<<"dream=r/dream">>),
          Binary(<<2, 4:32, 1:32, 4:32, 3:32>>),
        ],
      ])
      |> or_fail_with("Expected binary, text and binary cells")
    }),
    it(
      "sends a text parameter for a type with no binary format",
      fn(connection) {
        // Act
        let outcome =
          run(
            connection,
            connection.statement("SELECT $1::aclitem::text"),
            [Text(<<"dream=r/dream">>)],
            [],
            deadline,
          )

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"dream=r/dream">>)]])
        |> or_fail_with("Expected the aclitem from its text")
      },
    ),
    it(
      "sends a NULL parameter for a type with no binary format",
      fn(connection) {
        // Act
        let outcome =
          run(
            connection,
            connection.statement("SELECT $1::aclitem"),
            [Null],
            [],
            deadline,
          )

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Null]])
        |> or_fail_with("Expected a NULL aclitem")
      },
    ),
    group("with a table of an int4 and an aclitem", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE parity_acl (id int4, acl aclitem)",
      )),
      it("writes and reads a row with binary and text cells", fn(connection) {
        // Act
        let outcome = {
          use _inserted <- try(run(
            connection,
            connection.statement(
              "INSERT INTO parity_acl (id, acl) VALUES ($1, $2)",
            ),
            [Binary(<<7:32>>), Text(<<"dream=arw/dream">>)],
            [],
            deadline,
          ))
          run(
            connection,
            connection.statement("SELECT id, acl FROM parity_acl"),
            [],
            [BinaryFormat, TextFormat],
            deadline,
          )
        }

        // Assert
        outcome
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Binary(<<7:32>>), Text(<<"dream=arw/dream">>)]])
        |> or_fail_with("Expected the row as it was written")
      }),
    ]),
  ]
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

const changing_select = "SELECT c FROM parity_change"

/// The hooks that make the table, run the select two times, and alter the
/// column.
fn change_hooks(change: TypeChange) -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script(
      "CREATE TEMP TABLE parity_change (c "
      <> change.from
      <> "); INSERT INTO parity_change VALUES ("
      <> change.value
      <> ")",
    )),
    before_each(run_setup_statement(changing_select)),
    before_each(run_setup_statement(changing_select)),
    before_each(run_setup_script(
      "ALTER TABLE parity_change ALTER COLUMN c TYPE "
      <> change.to
      <> " USING "
      <> change.using,
    )),
  ]
}

fn cached_change_tests(change: TypeChange) -> ContextNode(Connection) {
  group(
    "from " <> change_name(change),
    append(change_hooks(change), [
      it("gives StatementChanged for " <> change_name(change), fn(connection) {
        // Act
        let answer =
          run(
            connection,
            connection.statement(changing_select),
            [],
            [],
            deadline,
          )

        // Assert
        answer
        |> should
        |> be_error
        |> extract_changed_column_names
        |> be_equal(["c"])
        |> or_fail_with("Expected StatementChanged")
      }),
      group("after the StatementChanged", [
        before_each(run_failing_statement(changing_select)),
        it(
          "gives StatementChanged, then the new value, for "
            <> change_name(change),
          fn(connection) {
            // Act
            let outcome =
              run(
                connection,
                connection.statement(changing_select),
                [],
                [],
                deadline,
              )

            // Assert
            outcome
            |> should
            |> be_ok
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(bit_array.from_string(change.expected))]])
            |> or_fail_with("Expected the value of the new type")
          },
        ),
      ]),
    ]),
  )
}

fn unnamed_change_tests(change: TypeChange) -> ContextNode(Connection) {
  group(
    "from " <> change_name(change),
    append(change_hooks(change), [
      it(
        "gives the new value at once for " <> change_name(change),
        fn(connection) {
          // Act
          let outcome =
            run(
              connection,
              connection.statement(changing_select),
              [],
              [],
              deadline,
            )

          // Assert
          outcome
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(bit_array.from_string(change.expected))]])
          |> or_fail_with("Expected the value of the new type")
        },
      ),
    ]),
  )
}

// Schema changes ------------------------------------------------------------------

fn schema_tests(server: Server) -> List(ContextNode(Connection)) {
  [
    group("with a cache of 512 statements", [
      before_each(dream_connection(server, CacheStatements(512))),
      group("a changed INSERT RETURNING", cached_returning_tests()),
      group(
        "a column added to a table",
        map(added_columns(), added_column_tests),
      ),
      group("a changed statement in a transaction", transaction_tests()),
    ]),
    group("with unnamed statements", [
      before_each(dream_connection(server, UnnamedStatements)),
      group("a changed INSERT RETURNING", unnamed_returning_tests()),
      group("a column added to an aclitem column", [
        before_each(run_setup_script(
          "CREATE TEMP TABLE parity_added (c aclitem); "
          <> "INSERT INTO parity_added VALUES ('dream=r/dream')",
        )),
        before_each(run_setup_statement(added_select)),
        before_each(run_setup_script(
          "ALTER TABLE parity_added ADD COLUMN d int4 DEFAULT 3",
        )),
        it(
          "gives the added column at once with unnamed statements",
          fn(connection) {
            // Act
            let outcome =
              run(
                connection,
                connection.statement(added_select),
                [],
                [],
                deadline,
              )

            // Assert
            outcome
            |> should
            |> be_ok
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(<<"dream=r/dream">>), Text(<<"3">>)]])
            |> or_fail_with("Expected both columns")
          },
        ),
      ]),
    ]),
  ]
}

const returning_insert =
  "INSERT INTO parity_returning (v) VALUES (1) RETURNING w"

const returning_table =
  "CREATE TEMP TABLE parity_returning (v int4, w aclitem DEFAULT 'dream=r/dream')"

const returning_change =
  "ALTER TABLE parity_returning ALTER COLUMN w DROP DEFAULT; ALTER TABLE parity_returning ALTER COLUMN w TYPE int8 USING 1; ALTER TABLE parity_returning ALTER COLUMN w SET DEFAULT 5"

const returning_count = "SELECT count(*) FROM parity_returning"

fn cached_returning_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script(returning_table)),
    it(
      "gives the old default from an INSERT RETURNING before the change",
      fn(connection) {
        run(
          connection,
          connection.statement(returning_insert),
          [],
          [],
          deadline,
        )
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"dream=r/dream">>)]])
        |> or_fail_with("Expected the default of the aclitem column")
      },
    ),
    group("after the change", [
      before_each(run_setup_statement(returning_insert)),
      before_each(run_setup_script(returning_change)),
      before_each(run_failing_statement(returning_insert)),
      it(
        "gives the new default from a changed INSERT RETURNING after StatementChanged",
        fn(connection) {
          run(
            connection,
            connection.statement(returning_insert),
            [],
            [],
            deadline,
          )
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"5">>)]])
          |> or_fail_with("Expected the new default")
        },
      ),
      group("and the INSERT again", [
        before_each(run_setup_statement(returning_insert)),
        it(
          "inserts one row for each run of a changed INSERT RETURNING",
          fn(connection) {
            run(
              connection,
              connection.statement(returning_count),
              [],
              [],
              deadline,
            )
            |> should
            |> be_ok
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(<<"2">>)]])
            |> or_fail_with("Expected two rows in all")
          },
        ),
      ]),
    ]),
  ]
}

fn unnamed_returning_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script(returning_table)),
    it(
      "gives the old default from an INSERT RETURNING, unnamed",
      fn(connection) {
        run(
          connection,
          connection.statement(returning_insert),
          [],
          [],
          deadline,
        )
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"dream=r/dream">>)]])
        |> or_fail_with("Expected the default of the aclitem column")
      },
    ),
    group("after the change", [
      before_each(run_setup_statement(returning_insert)),
      before_each(run_setup_script(returning_change)),
      it(
        "gives the new default from a changed INSERT RETURNING, unnamed",
        fn(connection) {
          run(
            connection,
            connection.statement(returning_insert),
            [],
            [],
            deadline,
          )
          |> should
          |> be_ok
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"5">>)]])
          |> or_fail_with("Expected the new default")
        },
      ),
      group("and the INSERT again", [
        before_each(run_setup_statement(returning_insert)),
        it(
          "inserts one row for each changed INSERT RETURNING, unnamed",
          fn(connection) {
            run(
              connection,
              connection.statement(returning_count),
              [],
              [],
              deadline,
            )
            |> should
            |> be_ok
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(<<"2">>)]])
            |> or_fail_with("Expected two rows in all")
          },
        ),
      ]),
    ]),
  ]
}

const added_select = "SELECT * FROM parity_added"

/// A table with `column` and one row of `value`, that gets the column
/// `added`. The row then holds `expected`.
type AddedColumn {
  AddedColumn(
    setup: String,
    changed_name: String,
    name: String,
    column: String,
    value: String,
    added: String,
    expected: List(Cell),
  )
}

fn added_columns() -> List(AddedColumn) {
  [
    AddedColumn(
      setup: "a column added to an aclitem column",
      changed_name: "gives StatementChanged for a column added to a text column",
      name: "gives a column added to a text column after StatementChanged",
      column: "c aclitem",
      value: "'dream=r/dream'",
      added: "d int4 DEFAULT 3",
      expected: [Text(<<"dream=r/dream">>), Text(<<"3">>)],
    ),
    AddedColumn(
      setup: "an aclitem column added to an int4 column",
      changed_name: "gives StatementChanged for a text column added to a column",
      name: "gives a text column added to a column after StatementChanged",
      column: "c int4",
      value: "1",
      added: "d aclitem DEFAULT 'dream=r/dream'",
      expected: [Text(<<"1">>), Text(<<"dream=r/dream">>)],
    ),
  ]
}

fn added_column_tests(change: AddedColumn) -> ContextNode(Connection) {
  group(change.setup, [
    before_each(run_setup_script(
      "CREATE TEMP TABLE parity_added ("
      <> change.column
      <> "); INSERT INTO parity_added VALUES ("
      <> change.value
      <> ")",
    )),
    before_each(run_setup_statement(added_select)),
    before_each(run_setup_script(
      "ALTER TABLE parity_added ADD COLUMN " <> change.added,
    )),
    it(change.changed_name, fn(connection) {
      run(connection, connection.statement(added_select), [], [], deadline)
      |> should
      |> be_error
      |> extract_changed_column_names
      |> be_equal(["c", "d"])
      |> or_fail_with("Expected StatementChanged with both columns")
    }),
    group("after the StatementChanged", [
      before_each(run_failing_statement(added_select)),
      it(change.name, fn(connection) {
        run(connection, connection.statement(added_select), [], [], deadline)
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([change.expected])
        |> or_fail_with("Expected both columns")
      }),
    ]),
  ])
}

const transaction_select = "SELECT c FROM parity_in_transaction"

fn transaction_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script(
      "CREATE TEMP TABLE parity_in_transaction (c int8); "
      <> "INSERT INTO parity_in_transaction VALUES (5)",
    )),
    before_each(run_setup_statement(transaction_select)),
    before_each(run_setup_script(
      "ALTER TABLE parity_in_transaction ALTER COLUMN c TYPE float8; BEGIN",
    )),
    it(
      "refuses a changed statement in a transaction with 0A000",
      fn(connection) {
        run(
          connection,
          connection.statement(transaction_select),
          [],
          [],
          deadline,
        )
        |> should
        |> be_error
        |> extract_run_refusal_code
        |> be_equal("0A000")
        |> or_fail_with("Expected 0A000")
      },
    ),
    group("after the refusal", [
      before_each(run_failing_statement(transaction_select)),
      it(
        "refuses the next statement of the failed transaction with 25P02",
        fn(connection) {
          run(connection, connection.statement("SELECT 1"), [], [], deadline)
          |> should
          |> be_error
          |> extract_run_refusal_code
          |> be_equal("25P02")
          |> or_fail_with("Expected 25P02")
        },
      ),
      group("and a ROLLBACK", [
        before_each(run_failing_statement("SELECT 1")),
        before_each(run_setup_script("ROLLBACK")),
        it(
          "refuses a changed statement in a transaction, then prepares it",
          fn(connection) {
            run(
              connection,
              connection.statement(transaction_select),
              [],
              [],
              deadline,
            )
            |> should
            |> be_ok
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(<<"5">>)]])
            |> or_fail_with("Expected the float8 value")
          },
        ),
      ]),
    ]),
  ]
}

// With a proxied connection of its own --------------------------------------------

fn proxied_tests() -> TestSuite {
  describe(
    "with a proxied connection of its own",
    proxied_setup(first_driver_server, 10),
    [
      after_each(stop_proxied),
      group("on each driver server", map(driver_servers(), session_tests)),
    ],
  )
}

/// The SQL of the prepared statements of the session. A script runs with
/// the simple protocol, so it adds no statement of its own.
const prepared_statements =
  "SELECT statement FROM pg_prepared_statements ORDER BY statement"

fn session_tests(server: Server) -> ContextNode(ProxiedConnection) {
  group("PostgreSQL " <> to_string(server.version), [
    before_each(start_test_proxied(server, 10)),
    group("sessions that the server ends", [
      it(
        "connects again when the server ends an idle session",
        fn(proxied: ProxiedConnection) {
          // Act
          let backends = {
            use old <- try(backend_pid(proxied.connection))
            use _ended <- try(terminate_backend(proxied.control, old))
            use _back <- try(wait_for_reconnect(proxied.events))
            use new <- try(backend_pid(proxied.connection))
            Ok(#(old, new))
          }

          // Assert
          backends
          |> should
          |> be_ok
          |> be_different_parts
          |> or_fail_with("Expected a new backend after the reconnect")
        },
      ),
      it(
        "tells of a reset by the network as ConnectionReset",
        fn(proxied: ProxiedConnection) {
          // Act
          reset_client(proxied.proxy)
          let event = next_event(proxied.events)

          // Assert
          event
          |> should
          |> be_ok
          |> be_equal(
            Disconnected(ConnectionLost(SocketFailed(ConnectionReset))),
          )
          |> or_fail_with("Expected the loss with ConnectionReset")
        },
      ),
      it(
        "tells of a close by the network as SocketClosed",
        fn(proxied: ProxiedConnection) {
          // Act
          close_client(proxied.proxy)
          let event = next_event(proxied.events)

          // Assert
          event
          |> should
          |> be_ok
          |> be_equal(Disconnected(ConnectionLost(SocketFailed(SocketClosed))))
          |> or_fail_with("Expected the loss with SocketClosed")
        },
      ),
      group("after the server ended the session during a run", [
        before_each(on_proxied_connection(run_setup_statement("SELECT 42"))),
        before_each(
          on_proxied_connection(run_failing_statement(terminate_own_session)),
        ),
        before_each(wait_for_proxied_reconnect),
        reconnected_tests(),
      ]),
    ]),
  ])
}

fn reconnected_tests() -> ContextNode(ProxiedConnection) {
  group("and the reconnect", [
    it(
      "runs on a new session after the server ended the last one",
      fn(proxied: ProxiedConnection) {
        run(
          proxied.connection,
          connection.statement("SELECT 1"),
          [],
          [],
          deadline,
        )
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"1">>)]])
        |> or_fail_with("Expected the run on the new session")
      },
    ),
    it(
      "runs a statement again on the new session",
      fn(proxied: ProxiedConnection) {
        run(
          proxied.connection,
          connection.statement("SELECT 42"),
          [],
          [],
          deadline,
        )
        |> should
        |> be_ok
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"42">>)]])
        |> or_fail_with("Expected the statement to run again")
      },
    ),
    it(
      "prepares its statements again on the new session",
      fn(proxied: ProxiedConnection) {
        // Act
        let outcomes = {
          use _again <- try(
            run(
              proxied.connection,
              connection.statement("SELECT 42"),
              [],
              [],
              deadline,
            )
            |> map_error(inspect),
          )
          run_script(
            proxied.connection,
            connection.statement(prepared_statements),
            deadline,
          )
          |> map_error(inspect)
        }

        // Assert
        outcomes
        |> should
        |> be_ok
        |> extract_first
        |> extract_command_result
        |> extract_command_rows
        |> be_equal([[Text(<<"SELECT 42">>)]])
        |> or_fail_with("Expected one statement, prepared on the new session")
      },
    ),
  ])
}

// With a pool of its own ----------------------------------------------------------

fn pool_tests() -> TestSuite {
  describe("with a pool of its own", pool_session_setup(first_driver_server), [
    after_each(stop_pool_session),
    group("on each driver server", map(driver_servers(), pool_server_tests)),
  ])
}

fn pool_server_tests(server: Server) -> ContextNode(PoolSession) {
  group("PostgreSQL " <> to_string(server.version), [
    group("the pool", [
      group("with one connection", [
        before_each(start_test_pool(server, 1)),
        it("runs a query on a held connection", fn(session: PoolSession) {
          // Act
          let answer = hold_connection(session.pool, query_text(_, "SELECT 1"))

          // Assert
          answer
          |> should
          |> be_ok
          |> be_equal("1")
          |> or_fail_with("Expected the query to run on the held connection")
        }),
      ]),
      group("with two connections", [
        before_each(start_test_pool(server, 2)),
        it(
          "gives each connection back when its hold ends",
          fn(session: PoolSession) {
            // Act
            let status = {
              use Nil <- try(wait_for_member_free_count(session.pool_events, 2))
              use _answers <- try(
                while_holding(session.pool, 2, fn(held) {
                  try_map(held, query_text(_, "SELECT 1"))
                })
                |> result.flatten,
              )
              use Nil <- try(wait_for_member_free_count(session.pool_events, 2))
              pool_status(session.pool)
            }

            // Assert
            status
            |> should
            |> be_ok
            |> be_equal(PoolStatus(
              size: 2,
              connected: 2,
              available: 2,
              held: 0,
              waiting: 0,
              last_connect_error: None,
            ))
            |> or_fail_with("Expected both connections back and free")
          },
        ),
      ]),
    ]),
  ])
}

// With a proxied pool of its own --------------------------------------------------

fn proxied_pool_tests() -> TestSuite {
  describe(
    "with a proxied pool of its own",
    proxied_pool_setup(first_driver_server),
    [
      after_each(stop_proxied_pool),
      group(
        "on each driver server",
        map(driver_servers(), proxied_pool_server_tests),
      ),
    ],
  )
}

fn proxied_pool_server_tests(server: Server) -> ContextNode(ProxiedPool) {
  group("PostgreSQL " <> to_string(server.version), [
    group("the pool", [
      before_each(start_test_proxied_pool(server)),
      it(
        "replaces an idle connection whose socket closed",
        fn(proxied: ProxiedPool) {
          // Act
          let backends = {
            use Nil <- try(wait_for_member_free(proxied.pool_events, 0))
            use first <- try(held_backend_pid(proxied.pool))
            use Nil <- try(wait_for_member_free(proxied.pool_events, 0))
            close_client(proxied.proxy)
            use _back <- try(wait_for_reconnect(proxied.events))
            use second <- try(held_backend_pid(proxied.pool))
            Ok(#(first, second))
          }

          // Assert
          backends
          |> should
          |> be_ok
          |> be_different_parts
          |> or_fail_with("Expected a new backend after the socket closed")
        },
      ),
    ]),
  ])
}

// With no setup ---------------------------------------------------------------------

fn unstarted_tests() -> TestSuite {
  describe("with no setup", context.value(Nil), [
    group("on each driver server", map(driver_servers(), login_error_tests)),
    group("addresses", address_tests()),
    group("closed sockets", socket_tests()),
  ])
}

fn login_error_tests(server: Server) -> ContextNode(Nil) {
  group("PostgreSQL " <> to_string(server.version), [
    group("login errors", [
      it(
        "gives the FATAL 28P01 of the server for a wrong password",
        fn(_nothing) {
          // Act
          let started =
            user_config(server.port, "dream", "wrong") |> result.map(start)

          // Assert
          started
          |> should
          |> be_ok
          |> be_error
          |> extract_login_refusal_code
          |> be_equal("28P01")
          |> or_fail_with("Expected the 28P01 of the server")
        },
      ),
      it(
        "gives the severity FATAL of the server for a wrong password",
        fn(_nothing) {
          // Act
          let started =
            user_config(server.port, "dream", "wrong") |> result.map(start)

          // Assert
          started
          |> should
          |> be_ok
          |> be_error
          |> extract_login_refusal_report
          |> extract_report_severity
          |> be_equal("FATAL")
          |> or_fail_with("Expected the severity FATAL")
        },
      ),
      it(
        "gives the 3D000 of the server for a database that does not exist",
        fn(_nothing) {
          // Act
          let started =
            database_config(server.port, "parity_no_such_database")
            |> result.map(start)

          // Assert
          started
          |> should
          |> be_ok
          |> be_error
          |> extract_login_refusal_code
          |> be_equal("3D000")
          |> or_fail_with("Expected the 3D000 of the server")
        },
      ),
      it(
        "gives the message of the server for a database that does not exist",
        fn(_nothing) {
          // Act
          let started =
            database_config(server.port, "parity_no_such_database")
            |> result.map(start)

          // Assert
          started
          |> should
          |> be_ok
          |> be_error
          |> extract_login_refusal_report
          |> extract_report_message
          |> be_equal("database \"parity_no_such_database\" does not exist")
          |> or_fail_with("Expected the message of the server")
        },
      ),
    ]),
  ])
}

fn address_tests() -> List(ContextNode(Nil)) {
  [
    it("refuses a negative port", fn(_nothing) {
      address("localhost", -1)
      |> should
      |> be_error
      |> be_equal(InvalidPort(-1))
      |> or_fail_with("Expected InvalidPort(-1)")
    }),
    it(
      "takes the ports 1 and 65535 and an IP address as the host",
      fn(_nothing) {
        address("127.0.0.1", 1)
        |> result.map(transport.port)
        |> should
        |> be_ok
        |> be_equal(1)
        |> or_fail_with("Expected the port 1")
      },
    ),
    it(
      "takes the IPv6 address ::1 as the host with the port 65535",
      fn(_nothing) {
        address("::1", 65_535)
        |> result.map(transport.host)
        |> should
        |> be_ok
        |> be_equal("::1")
        |> or_fail_with("Expected the host ::1")
      },
    ),
    it("gives DnsLookupFailed for a host with no address", fn(_nothing) {
      // Act
      let started =
        host_config("no-such-host.invalid", 5432) |> result.map(start)

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> be_equal(TransportRefused(DnsLookupFailed("no-such-host.invalid")))
      |> or_fail_with("Expected DnsLookupFailed with the host")
    }),
    it("gives ServerRefusedTls for a server with no TLS", fn(_nothing) {
      // Act
      let started =
        connection_config(server_without_tls)
        |> result.map(tls_config(
          _,
          RequireTls(NoCertificateCheck, PostgresNegotiation),
        ))
        |> result.map(start)

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> be_equal(TransportRefused(ServerRefusedTls))
      |> or_fail_with("Expected ServerRefusedTls")
    }),
  ]
}

// Closed sockets ----------------------------------------------------------------

const missing_authority_file = "test/fixtures/ssl/parity_missing_ca.crt"

const missing_authority_tls =
  RequireTls(
    CheckAuthorityAndHost(AuthorityFile(missing_authority_file)),
    PostgresNegotiation,
  )

const closing_tls = RequireTls(NoCertificateCheck, PostgresNegotiation)

fn socket_tests() -> List(ContextNode(Nil)) {
  [
    group("when the server refuses the login", login_refusal_tests()),
    group("when the CA file cannot be read", authority_tests()),
    group("when the server closes", closing_tests()),
  ]
}

fn login_refusal_tests() -> List(ContextNode(Nil)) {
  [
    it("closes the socket when the server refuses the login", fn(_nothing) {
      // Act
      let started = {
        use #(refusing_port, refusing_server) <- try(
          start_login_refusing_server(),
        )
        use config <- result.map(connection_config(refusing_port))
        #(start(config), refusing_server)
      }

      // Assert
      started
      |> should
      |> be_ok
      |> extract_client_closed
      |> be_true
      |> or_fail_with("Expected a closed socket")
    }),
    it("gives the 28P01 of a server that refuses the login", fn(_nothing) {
      // Act
      let started = {
        use #(refusing_port, _refusing_server) <- try(
          start_login_refusing_server(),
        )
        connection_config(refusing_port) |> result.map(start)
      }

      // Assert
      started
      |> should
      |> be_ok
      |> be_error
      |> extract_login_refusal_code
      |> be_equal("28P01")
      |> or_fail_with("Expected the 28P01 of the refusal")
    }),
    it(
      "gives the severity FATAL of a server that refuses the login",
      fn(_nothing) {
        // Act
        let started = {
          use #(refusing_port, _refusing_server) <- try(
            start_login_refusing_server(),
          )
          connection_config(refusing_port) |> result.map(start)
        }

        // Assert
        started
        |> should
        |> be_ok
        |> be_error
        |> extract_login_refusal_report
        |> extract_report_severity
        |> be_equal("FATAL")
        |> or_fail_with("Expected the severity FATAL of the refusal")
      },
    ),
  ]
}

fn authority_tests() -> List(ContextNode(Nil)) {
  [
    it("closes the socket when the CA file cannot be read", fn(_nothing) {
      // Act
      let connected = {
        use #(fake_port, fake) <- result.map(start_fake_server(Answer(<<"S">>)))
        let config =
          transport_config("localhost", fake_port, missing_authority_tls)
        #(try(config, connect_with_minute_deadline), fake)
      }

      // Assert
      connected
      |> should
      |> be_ok
      |> extract_client_closed
      |> be_true
      |> or_fail_with("Expected a closed socket")
    }),
    it(
      "gives AuthorityFileUnreadable when the CA file cannot be read",
      fn(_nothing) {
        // Act
        let connected = {
          use #(fake_port, _fake) <- result.map(
            start_fake_server(Answer(<<"S">>)),
          )
          transport_config("localhost", fake_port, missing_authority_tls)
          |> try(connect_with_minute_deadline)
        }

        // Assert
        connected
        |> should
        |> be_ok
        |> be_error
        |> be_equal(
          TlsFailed(AuthorityFileUnreadable(missing_authority_file, "enoent")),
        )
        |> or_fail_with("Expected AuthorityFileUnreadable")
      },
    ),
  ]
}

fn closing_tests() -> List(ContextNode(Nil)) {
  [
    it(
      "gives SocketClosed and closes the socket when the server closes",
      fn(_nothing) {
        // Act
        let connected = {
          use #(closing_port, _closing_server) <- result.map(
            start_closing_server(),
          )
          transport_config("localhost", closing_port, closing_tls)
          |> try(connect_with_minute_deadline)
        }

        // Assert
        connected
        |> should
        |> be_ok
        |> be_error
        |> be_equal(SocketClosed)
        |> or_fail_with("Expected SocketClosed")
      },
    ),
    it(
      "closes the socket when the server closes after the SSLRequest",
      fn(_nothing) {
        // Act
        let connected = {
          use #(closing_port, closing_server) <- result.map(
            start_closing_server(),
          )
          let config = transport_config("localhost", closing_port, closing_tls)
          #(try(config, connect_with_minute_deadline), closing_server)
        }

        // Assert
        connected
        |> should
        |> be_ok
        |> extract_client_closed
        |> be_true
        |> or_fail_with("Expected a closed socket")
      },
    ),
  ]
}

// With a supervised connection of its own ---------------------------------------

fn supervisor_tests() -> TestSuite {
  describe(
    "with a supervised connection of its own",
    supervised_connection_setup(md5_config()),
    [
      group("the password", [
        it("stays out of the status of the supervisor", fn(supervisor) {
          supervisor
          |> should
          |> extract_printed_status
          |> not_contain_text(printed_password)
          |> or_fail_with("Expected no password in the status")
        }),
      ]),
    ],
  )
}
