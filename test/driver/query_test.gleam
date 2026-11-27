//// Tests for `dream_postgres/driver/query`: each query step fed with the
//// messages of the flows of the PostgreSQL documentation ("Message Flow"),
//// one message at a time, with no server. Some flows come as bytes through
//// `decode_backend`.

import dream_postgres/driver/message.{
  type BackendMessage, type ResultColumn, Bind, BindComplete, Close,
  CloseComplete, CommandComplete, CopyBothResponse, CopyDataFromServer,
  CopyDoneFromServer, CopyInResponse, CopyOutResponse, DataRow, Describe,
  EmptyQueryResponse, ErrorResponse, Execute, NoData, NoticeResponse,
  NotificationResponse, ParameterDescriptions, ParameterStatus, Parse,
  ParseComplete, Portal, PortalSuspended, Query, ReadyForQuery, ResultColumn,
  RowDescription, Statement, Sync,
}
import dream_postgres/driver/query.{
  type UnexpectedMessage, AwaitingBindComplete, AwaitingCloseComplete,
  AwaitingCopyComplete, AwaitingParameterDescription, AwaitingParseComplete,
  AwaitingPortalColumns, AwaitingReadyForQuery, AwaitingReadyForQueryAfterError,
  AwaitingStatementColumns, AwaitingStatementResult, ConnectionEnded,
  CopyNotSupported, Finished, Notice, Notification, Outcome, ParameterChanged,
  ReadingCopyOut, ReadingExecuteRows, ReadingScriptRows, ScriptFailure,
  ServerError, StatementResult, UnexpectedMessage, failure_report, start_prepare,
  start_prepare_and_run, start_prepare_closing, start_run, start_simple_query,
  step_prepare, step_prepare_and_run, step_run, step_simple_query,
}
import dream_postgres/internal/cell.{
  type ColumnDescription, type Format, type ServerReport, Binary, BinaryFormat,
  ColumnDescription, CommandResult, Idle, InFailedTransaction, InTransaction,
  Null, ParameterDescription, StatementDescription, Text, TextFormat,
}
import dream_test/matchers.{
  be_equal, be_error, be_none, be_ok, be_some, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/server_report.{server_report}
import gleam/bit_array.{byte_size, concat}
import gleam/list.{map}
import gleam/option.{None, Some}
import matchers/be_wait.{be_wait}
import matchers/extract_backend_messages.{extract_backend_messages}
import matchers/extract_last_step.{extract_last_step}
import matchers/extract_query_feed.{extract_query_feed}
import matchers/extract_sent_messages.{extract_sent_messages}

/// The tests of the query steps.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/query", [
    group("prepare", prepare_tests()),
    group("run a prepared statement", run_tests()),
    group("prepare and run in one round trip", prepare_and_run_tests()),
    group("simple query", simple_query_tests()),
    group("server errors", server_error_tests()),
    group("COPY", copy_tests()),
    group("asynchronous messages", asynchronous_tests()),
    group("the row count of a command tag", map(count_cases(), count_test)),
    group("messages that a phase does not allow", unexpected_tests()),
  ])
}

// The values of the tests ---------------------------------------------------

fn column(name: String, type_id: Int, number: Int) -> ColumnDescription {
  ColumnDescription(
    name:,
    type_id:,
    type_modifier: -1,
    table_id: 16_384,
    column_number: number,
  )
}

fn result_column(
  name: String,
  type_id: Int,
  number: Int,
  format: Format,
) -> ResultColumn {
  ResultColumn(column: column(name, type_id, number), type_size: 4, format:)
}

fn unique_violation() -> ServerReport {
  server_report(
    "ERROR",
    "23505",
    "duplicate key value violates unique constraint",
  )
}

fn copy_failed() -> ServerReport {
  server_report(
    "ERROR",
    "57014",
    "COPY from stdin failed: COPY is not supported by this step",
  )
}

fn notice() -> ServerReport {
  server_report("NOTICE", "00000", "table t does not exist, skipping")
}

// Prepare -------------------------------------------------------------------

fn prepare_tests() {
  [
    it("closes each stale statement before the Parse, in one round trip", fn() {
      // Act
      let start = start_prepare_closing(["s1", "s2"], "s3", "SELECT 1", [])

      // Assert
      start.messages
      |> should
      |> be_equal([
        Close(Statement("s1")),
        Close(Statement("s2")),
        Parse(statement: "s3", query: "SELECT 1", parameter_type_ids: []),
        Describe(Statement("s3")),
        Sync,
      ])
      |> or_fail_with("Expected two Close messages, then the prepare")
    }),
    it("reads each CloseComplete before the ParseComplete", fn() {
      // Arrange
      let start = start_prepare_closing(["s1", "s2"], "s3", "SELECT 1", [])
      let messages = [
        CloseComplete,
        CloseComplete,
        ParseComplete,
        ParameterDescriptions([]),
        NoData,
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(StatementDescription([], [])),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the description after both CloseComplete")
    }),
    it("refuses a ParseComplete where a CloseComplete must come", fn() {
      // Arrange
      let start = start_prepare_closing(["s1"], "s2", "SELECT 1", [])

      // Act
      let step = step_prepare(start.state, ParseComplete)

      // Assert
      step
      |> should
      |> be_error
      |> be_equal(UnexpectedMessage(ParseComplete, AwaitingCloseComplete, []))
      |> or_fail_with("Expected an unexpected message in AwaitingCloseComplete")
    }),
    it("sends Parse, Describe of the statement, and Sync", fn() {
      // Act
      let start = start_prepare("s1", "SELECT $1::int4", [23])

      // Assert
      start.messages
      |> should
      |> be_equal([
        Parse(statement: "s1", query: "SELECT $1::int4", parameter_type_ids: [
          23,
        ]),
        Describe(Statement("s1")),
        Sync,
      ])
      |> or_fail_with("Expected Parse, Describe(Statement) and Sync")
    }),
    it("waits after ParseComplete", fn() {
      // Arrange
      let start = start_prepare("s1", "SELECT 1", [])

      // Act
      let step = step_prepare(start.state, ParseComplete)

      // Assert
      step
      |> should
      |> be_ok
      |> be_wait
      |> or_fail_with("Expected Wait after ParseComplete")
    }),
    it("describes each parameter and each column", fn() {
      // Arrange
      let start = start_prepare("s1", "SELECT id, name FROM users", [])
      let messages = [
        ParseComplete,
        ParameterDescriptions([
          ParameterDescription(23),
          ParameterDescription(25),
        ]),
        RowDescription([
          result_column("id", 23, 1, TextFormat),
          result_column("name", 25, 2, TextFormat),
        ]),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(
              StatementDescription(
                parameters: [
                  ParameterDescription(23),
                  ParameterDescription(25),
                ],
                columns: [column("id", 23, 1), column("name", 25, 2)],
              ),
            ),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the parameters and the columns")
    }),
    it("gives no columns for NoData", fn() {
      // Arrange
      let start = start_prepare("", "INSERT INTO t VALUES ($1)", [])
      let messages = [
        ParseComplete,
        ParameterDescriptions([ParameterDescription(23)]),
        NoData,
        ReadyForQuery(InTransaction),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(
              StatementDescription(
                parameters: [ParameterDescription(23)],
                columns: [],
              ),
            ),
            status: InTransaction,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected no columns and the status InTransaction")
    }),
    it("sends nothing more than the start messages", fn() {
      // Arrange
      let start = start_prepare("s1", "SELECT 1", [])
      let messages = [
        ParseComplete,
        ParameterDescriptions([]),
        NoData,
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_sent_messages
      |> be_equal(<<>>)
      |> or_fail_with("Expected no messages to send")
    }),
  ]
}

// Run -----------------------------------------------------------------------

fn run_tests() {
  [
    it("sends Bind, Execute with no row limit, and Sync", fn() {
      // Act
      let start =
        start_run("s1", [Binary(<<0, 0, 0, 7>>), Text(<<"a">>), Null], [
          BinaryFormat,
        ])

      // Assert
      start.messages
      |> should
      |> be_equal([
        Bind(
          portal: "",
          statement: "s1",
          parameters: [Binary(<<0, 0, 0, 7>>), Text(<<"a">>), Null],
          result_formats: [BinaryFormat],
        ),
        Execute(portal: "", row_limit: 0),
        Sync,
      ])
      |> or_fail_with("Expected Bind, Execute and Sync")
    }),
    it("tags each cell with the format of its column", fn() {
      // Arrange
      let start = start_run("s1", [], [BinaryFormat, TextFormat])
      let messages = [
        BindComplete,
        DataRow([Some(<<0, 0, 0, 1>>), Some(<<"ada">>)]),
        DataRow([Some(<<0, 0, 0, 2>>), None]),
        CommandComplete("SELECT 2"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(CommandResult(
              rows: [
                [Binary(<<0, 0, 0, 1>>), Text(<<"ada">>)],
                [Binary(<<0, 0, 0, 2>>), Null],
              ],
              tag: "SELECT 2",
              count: 2,
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the rows in their formats and the count 2")
    }),
    it("gives text for each column when Bind gives no format", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        BindComplete,
        DataRow([Some(<<"1">>), Some(<<"ada">>)]),
        CommandComplete("SELECT 1"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(CommandResult(
              rows: [[Text(<<"1">>), Text(<<"ada">>)]],
              tag: "SELECT 1",
              count: 1,
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected text cells")
    }),
    it("gives the one format of Bind to each column", fn() {
      // Arrange
      let start = start_run("s1", [], [BinaryFormat])
      let messages = [
        BindComplete,
        DataRow([Some(<<1>>), Some(<<2>>)]),
        CommandComplete("SELECT 1"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(CommandResult(
              rows: [[Binary(<<1>>), Binary(<<2>>)]],
              tag: "SELECT 1",
              count: 1,
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected binary cells")
    }),
    it("gives no rows, the empty tag and 0 for an empty query", fn() {
      // Arrange
      let start = start_run("", [], [])
      let messages = [BindComplete, EmptyQueryResponse, ReadyForQuery(Idle)]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(CommandResult(rows: [], tag: "", count: 0)),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected an empty command result")
    }),
  ]
}

// Prepare and run -------------------------------------------------------------

fn prepare_and_run_tests() {
  [
    it("sends Parse, Bind, Describe of the portal, Execute and Sync", fn() {
      // Act
      let start =
        start_prepare_and_run("SELECT $1::int4", [23], [Text(<<"5">>)], [
          BinaryFormat,
        ])

      // Assert
      start.messages
      |> should
      |> be_equal([
        Parse(statement: "", query: "SELECT $1::int4", parameter_type_ids: [23]),
        Bind(
          portal: "",
          statement: "",
          parameters: [Text(<<"5">>)],
          result_formats: [BinaryFormat],
        ),
        Describe(Portal("")),
        Execute(portal: "", row_limit: 0),
        Sync,
      ])
      |> or_fail_with("Expected the five messages of one round trip")
    }),
    it("gives the columns of the portal and the rows in their formats", fn() {
      // Arrange
      let start =
        start_prepare_and_run("SELECT id, name FROM users", [], [], [])
      let messages = [
        ParseComplete,
        BindComplete,
        RowDescription([
          result_column("id", 23, 1, BinaryFormat),
          result_column("name", 25, 2, TextFormat),
        ]),
        DataRow([Some(<<0, 0, 0, 1>>), Some(<<"ada">>)]),
        CommandComplete("SELECT 1"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare_and_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(StatementResult(
              columns: [column("id", 23, 1), column("name", 25, 2)],
              result: CommandResult(
                rows: [[Binary(<<0, 0, 0, 1>>), Text(<<"ada">>)]],
                tag: "SELECT 1",
                count: 1,
              ),
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the columns and the tagged row")
    }),
    it("gives no columns for NoData", fn() {
      // Arrange
      let start = start_prepare_and_run("INSERT INTO t VALUES (1)", [], [], [])
      let messages = [
        ParseComplete,
        BindComplete,
        NoData,
        CommandComplete("INSERT 0 1"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare_and_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(StatementResult(
              columns: [],
              result: CommandResult(rows: [], tag: "INSERT 0 1", count: 1),
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected no columns and the count 1")
    }),
  ]
}

// Simple query --------------------------------------------------------------

fn simple_query_tests() {
  [
    it("sends one Query", fn() {
      // Act
      let start = start_simple_query("SELECT 1; SELECT 2")

      // Assert
      start.messages
      |> should
      |> be_equal([Query("SELECT 1; SELECT 2")])
      |> or_fail_with("Expected one Query")
    }),
    it("gives one result for each statement, in order", fn() {
      // Arrange
      let start =
        start_simple_query(
          "CREATE TABLE t (id int); INSERT INTO t VALUES (1), (2); SELECT id FROM t",
        )
      let messages = [
        CommandComplete("CREATE TABLE"),
        CommandComplete("INSERT 0 2"),
        RowDescription([result_column("id", 23, 1, TextFormat)]),
        DataRow([Some(<<"1">>)]),
        DataRow([Some(<<"2">>)]),
        CommandComplete("SELECT 2"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok([
              StatementResult(
                columns: [],
                result: CommandResult(rows: [], tag: "CREATE TABLE", count: 0),
              ),
              StatementResult(
                columns: [],
                result: CommandResult(rows: [], tag: "INSERT 0 2", count: 2),
              ),
              StatementResult(
                columns: [column("id", 23, 1)],
                result: CommandResult(
                  rows: [[Text(<<"1">>)], [Text(<<"2">>)]],
                  tag: "SELECT 2",
                  count: 2,
                ),
              ),
            ]),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected three results in order")
    }),
    it("gives no results for an empty script", fn() {
      // Arrange
      let start = start_simple_query("  ")
      let messages = [EmptyQueryResponse, ReadyForQuery(Idle)]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(result: Ok([]), status: Idle, asynchronous_messages: []),
        ),
      )
      |> or_fail_with("Expected no results")
    }),
    it("tags the cells of a binary cursor as binary", fn() {
      // Arrange
      let start = start_simple_query("FETCH 1 FROM c")
      let messages = [
        RowDescription([result_column("id", 23, 1, BinaryFormat)]),
        DataRow([Some(<<0, 0, 0, 1>>)]),
        CommandComplete("FETCH 1"),
        ReadyForQuery(InTransaction),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok([
              StatementResult(
                columns: [column("id", 23, 1)],
                result: CommandResult(
                  rows: [[Binary(<<0, 0, 0, 1>>)]],
                  tag: "FETCH 1",
                  count: 1,
                ),
              ),
            ]),
            status: InTransaction,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected a binary cell")
    }),
    it("reads a script from the bytes of the server", fn() {
      // Arrange
      let start = start_simple_query("SELECT 1 AS n, NULL AS m")
      let bytes = select_bytes()

      // Act and Assert
      bytes
      |> should
      |> extract_backend_messages
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok([
              StatementResult(
                columns: [
                  ColumnDescription("n", 23, -1, 0, 0),
                  ColumnDescription("m", 25, -1, 0, 0),
                ],
                result: CommandResult(
                  rows: [[Text(<<"1">>), Null]],
                  tag: "SELECT 1",
                  count: 1,
                ),
              ),
            ]),
            status: Idle,
            asynchronous_messages: [
              ParameterChanged("application_name", "dream"),
            ],
          ),
        ),
      )
      |> or_fail_with("Expected the result of the decoded messages")
    }),
  ]
}

/// The answer to `SELECT 1 AS n, NULL AS m`, as the server sends it, with a
/// ParameterStatus in the middle.
fn select_bytes() -> BitArray {
  concat([
    frame("T", <<
      2:16, "n", 0, 0:32, 0:16, 23:32, 4:16, -1:32, 0:16, "m", 0, 0:32, 0:16,
      25:32, -1:16, -1:32, 0:16,
    >>),
    frame("S", <<"application_name", 0, "dream", 0>>),
    frame("D", <<2:16, 1:32, "1", -1:32>>),
    frame("C", <<"SELECT 1", 0>>),
    frame("Z", <<"I">>),
  ])
}

fn frame(type_byte: String, body: BitArray) -> BitArray {
  <<type_byte:utf8, { byte_size(body) + 4 }:32, body:bits>>
}

// Server errors -------------------------------------------------------------

fn server_error_tests() {
  [
    it("reads to ReadyForQuery after an error in Parse", fn() {
      // Arrange
      let start = start_prepare("s1", "SELEC 1", [])
      let syntax_error =
        server_report("ERROR", "42601", "syntax error at or near")
      let messages = [
        ErrorResponse(syntax_error),
        ReadyForQuery(InFailedTransaction),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ServerError(syntax_error)),
            status: InFailedTransaction,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the error and the status")
    }),
    it("keeps an error of the Sync after the last answer", fn() {
      // Arrange
      let start = start_prepare("s1", "SELECT 1", [])
      let messages = [
        ParseComplete,
        ParameterDescriptions([]),
        NoData,
        ErrorResponse(unique_violation()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ServerError(unique_violation())),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the error of the Sync")
    }),
    it("reads to ReadyForQuery after an error in Execute", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        BindComplete,
        ErrorResponse(unique_violation()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ServerError(unique_violation())),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the error of the Execute")
    }),
    it("gives the results before the error of a script", fn() {
      // Arrange
      let start =
        start_simple_query("BEGIN; INSERT INTO t VALUES (1); SELECT 1/0")
      let division = server_report("ERROR", "22012", "division by zero")
      let messages = [
        CommandComplete("BEGIN"),
        CommandComplete("INSERT 0 1"),
        RowDescription([result_column("?column?", 23, 0, TextFormat)]),
        ErrorResponse(division),
        ReadyForQuery(InFailedTransaction),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ScriptFailure(
              completed: [
                StatementResult(
                  columns: [],
                  result: CommandResult(rows: [], tag: "BEGIN", count: 0),
                ),
                StatementResult(
                  columns: [],
                  result: CommandResult(rows: [], tag: "INSERT 0 1", count: 1),
                ),
              ],
              failure: ServerError(division),
            )),
            status: InFailedTransaction,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected two results and the error")
    }),
    it("ends the step at a FATAL error", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let shutdown =
        server_report(
          "FATAL",
          "57P01",
          "terminating connection due to administrator",
        )
      let messages = [
        BindComplete,
        NoticeResponse(notice()),
        ErrorResponse(shutdown),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(ConnectionEnded(shutdown, [Notice(notice())]))
      |> or_fail_with("Expected the connection to end with the report")
    }),
    it("ends the step at a PANIC error, also after an error", fn() {
      // Arrange
      let start = start_simple_query("SELECT 1")
      let panic_report = server_report("PANIC", "XX000", "could not write")
      let messages = [
        ErrorResponse(unique_violation()),
        ErrorResponse(panic_report),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(ConnectionEnded(panic_report, []))
      |> or_fail_with("Expected the connection to end with the report")
    }),
    it("gives the report of a server error", fn() {
      // Act
      let found = failure_report(ServerError(unique_violation()))

      // Assert
      found
      |> should
      |> be_some
      |> be_equal(unique_violation())
      |> or_fail_with("Expected the report")
    }),
    it("gives no report for a COPY that ended without an error", fn() {
      // Act
      let found = failure_report(CopyNotSupported(None))

      // Assert
      found
      |> should
      |> be_none
      |> or_fail_with("Expected no report")
    }),
  ]
}

// COPY ----------------------------------------------------------------------

fn copy_tests() {
  [
    it("answers CopyInResponse with CopyFail and Sync in a run", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        BindComplete,
        CopyInResponse(TextFormat, [TextFormat]),
        ErrorResponse(copy_failed()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_sent_messages
      |> be_equal(<<
        "f", 39:32, "COPY is not supported by this step":utf8, 0, "S", 4:32,
      >>)
      |> or_fail_with("Expected CopyFail and Sync")
    }),
    it("refuses a COPY FROM STDIN with the server's error", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        BindComplete,
        CopyInResponse(TextFormat, [TextFormat]),
        ErrorResponse(copy_failed()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(CopyNotSupported(Some(copy_failed()))),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected CopyNotSupported with the error")
    }),
    it("reads a COPY TO STDOUT to its end and refuses it", fn() {
      // Arrange
      let start = start_prepare_and_run("COPY t TO STDOUT", [], [], [])
      let messages = [
        ParseComplete,
        BindComplete,
        NoData,
        CopyOutResponse(TextFormat, [TextFormat]),
        CopyDataFromServer(<<"1\n">>),
        NoticeResponse(notice()),
        CopyDataFromServer(<<"2\n">>),
        CopyDoneFromServer,
        CommandComplete("COPY 2"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare_and_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(CopyNotSupported(None)),
            status: Idle,
            asynchronous_messages: [Notice(notice())],
          ),
        ),
      )
      |> or_fail_with("Expected CopyNotSupported with no error")
    }),
    it("keeps an error during a COPY TO STDOUT", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        BindComplete,
        CopyOutResponse(TextFormat, []),
        ErrorResponse(unique_violation()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(CopyNotSupported(Some(unique_violation()))),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected CopyNotSupported with the error")
    }),
    it("answers CopyBothResponse with CopyDone and Sync in a run", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [BindComplete, CopyBothResponse(BinaryFormat, [])]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_sent_messages
      |> be_equal(<<"c", 4:32, "S", 4:32>>)
      |> or_fail_with("Expected CopyDone and Sync")
    }),
    it("answers CopyInResponse with CopyFail only in a simple query", fn() {
      // Arrange
      let start = start_simple_query("COPY t FROM STDIN")
      let messages = [
        CopyInResponse(TextFormat, [TextFormat]),
        ErrorResponse(copy_failed()),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_sent_messages
      |> be_equal(<<"f", 39:32, "COPY is not supported by this step":utf8, 0>>)
      |> or_fail_with("Expected CopyFail only")
    }),
    it("answers CopyBothResponse with CopyDone only in a simple query", fn() {
      // Arrange
      let start = start_simple_query("START_REPLICATION 0/0")
      let messages = [CopyBothResponse(BinaryFormat, [])]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_sent_messages
      |> be_equal(<<"c", 4:32>>)
      |> or_fail_with("Expected CopyDone only")
    }),
    it("goes on with the script after a COPY TO STDOUT", fn() {
      // Arrange
      let start = start_simple_query("COPY t TO STDOUT; SELECT 1")
      let messages = [
        CopyOutResponse(TextFormat, [TextFormat]),
        CopyDataFromServer(<<"1\n">>),
        CopyDoneFromServer,
        CommandComplete("COPY 1"),
        RowDescription([result_column("?column?", 23, 0, TextFormat)]),
        DataRow([Some(<<"1">>)]),
        CommandComplete("SELECT 1"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_simple_query)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ScriptFailure(
              completed: [
                StatementResult(
                  columns: [column("?column?", 23, 0)],
                  result: CommandResult(
                    rows: [[Text(<<"1">>)]],
                    tag: "SELECT 1",
                    count: 1,
                  ),
                ),
              ],
              failure: CopyNotSupported(None),
            )),
            status: Idle,
            asynchronous_messages: [],
          ),
        ),
      )
      |> or_fail_with("Expected the later result and CopyNotSupported")
    }),
  ]
}

// Asynchronous messages -----------------------------------------------------

fn asynchronous_tests() {
  [
    it("gives back each asynchronous message in order", fn() {
      // Arrange
      let start = start_prepare("s1", "SELECT 1", [])
      let messages = [
        ParameterStatus("TimeZone", "UTC"),
        ParseComplete,
        NoticeResponse(notice()),
        ParameterDescriptions([]),
        NotificationResponse(42, "jobs", "start"),
        NoData,
        ParameterStatus("is_superuser", "off"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_prepare)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Ok(StatementDescription(parameters: [], columns: [])),
            status: Idle,
            asynchronous_messages: [
              ParameterChanged("TimeZone", "UTC"),
              Notice(notice()),
              Notification(42, "jobs", "start"),
              ParameterChanged("is_superuser", "off"),
            ],
          ),
        ),
      )
      |> or_fail_with("Expected the four asynchronous messages in order")
    }),
    it("gives back an asynchronous message after an error", fn() {
      // Arrange
      let start = start_run("s1", [], [])
      let messages = [
        ErrorResponse(unique_violation()),
        ParameterStatus("TimeZone", "UTC"),
        ReadyForQuery(Idle),
      ]

      // Act and Assert
      messages
      |> should
      |> extract_query_feed(start.state, step_run)
      |> extract_last_step
      |> be_ok
      |> be_equal(
        Finished(
          Outcome(
            result: Error(ServerError(unique_violation())),
            status: Idle,
            asynchronous_messages: [ParameterChanged("TimeZone", "UTC")],
          ),
        ),
      )
      |> or_fail_with("Expected the ParameterStatus with the error")
    }),
  ]
}

// Row counts ----------------------------------------------------------------

type CountCase {
  CountCase(tag: String, count: Int)
}

fn count_cases() -> List(CountCase) {
  [
    CountCase("INSERT 0 3", 3),
    CountCase("UPDATE 2", 2),
    CountCase("DELETE 1", 1),
    CountCase("MERGE 4", 4),
    CountCase("SELECT 5", 5),
    CountCase("MOVE 6", 6),
    CountCase("FETCH 7", 7),
    CountCase("COPY 8", 8),
    CountCase("CREATE TABLE", 0),
    CountCase("BEGIN", 0),
    CountCase("", 0),
  ]
}

fn count_test(test_case: CountCase) {
  it("gives " <> test_case.tag <> " the count of its tag", fn() {
    // Arrange
    let start = start_run("s1", [], [])
    let messages = [
      BindComplete,
      CommandComplete(test_case.tag),
      ReadyForQuery(Idle),
    ]

    // Act and Assert
    messages
    |> should
    |> extract_query_feed(start.state, step_run)
    |> extract_last_step
    |> be_ok
    |> be_equal(
      Finished(
        Outcome(
          result: Ok(CommandResult(
            rows: [],
            tag: test_case.tag,
            count: test_case.count,
          )),
          status: Idle,
          asynchronous_messages: [],
        ),
      ),
    )
    |> or_fail_with("Expected the count of " <> test_case.tag)
  })
}

// Unexpected messages -------------------------------------------------------

fn prepare_unexpected_test(
  name: String,
  messages: List(BackendMessage),
  error: UnexpectedMessage,
) {
  it(name, fn() {
    // Arrange
    let start = start_prepare("s1", "SELECT 1", [])

    // Act and Assert
    messages
    |> should
    |> extract_query_feed(start.state, step_prepare)
    |> extract_last_step
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the UnexpectedMessage of " <> name)
  })
}

fn run_unexpected_test(
  name: String,
  result_formats: List(Format),
  messages: List(BackendMessage),
  error: UnexpectedMessage,
) {
  it(name, fn() {
    // Arrange
    let start = start_run("s1", [], result_formats)

    // Act and Assert
    messages
    |> should
    |> extract_query_feed(start.state, step_run)
    |> extract_last_step
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the UnexpectedMessage of " <> name)
  })
}

fn prepare_and_run_unexpected_test(
  name: String,
  messages: List(BackendMessage),
  error: UnexpectedMessage,
) {
  it(name, fn() {
    // Arrange
    let start = start_prepare_and_run("SELECT 1", [], [], [])

    // Act and Assert
    messages
    |> should
    |> extract_query_feed(start.state, step_prepare_and_run)
    |> extract_last_step
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the UnexpectedMessage of " <> name)
  })
}

fn script_unexpected_test(
  name: String,
  messages: List(BackendMessage),
  error: UnexpectedMessage,
) {
  it(name, fn() {
    // Arrange
    let start = start_simple_query("SELECT 1")

    // Act and Assert
    messages
    |> should
    |> extract_query_feed(start.state, step_simple_query)
    |> extract_last_step
    |> be_error
    |> be_equal(error)
    |> or_fail_with("Expected the UnexpectedMessage of " <> name)
  })
}

fn unexpected_tests() {
  [
    prepare_unexpected_test(
      "BindComplete before ParseComplete",
      [BindComplete],
      UnexpectedMessage(BindComplete, AwaitingParseComplete, []),
    ),
    prepare_unexpected_test(
      "RowDescription before ParameterDescription",
      [ParseComplete, RowDescription([])],
      UnexpectedMessage(RowDescription([]), AwaitingParameterDescription, []),
    ),
    prepare_unexpected_test(
      "DataRow in the description of a statement",
      [ParseComplete, ParameterDescriptions([]), DataRow([])],
      UnexpectedMessage(DataRow([]), AwaitingStatementColumns, []),
    ),
    prepare_unexpected_test(
      "ParseComplete after the last answer, with the asynchronous messages",
      [
        ParseComplete,
        ParameterDescriptions([]),
        NoData,
        ParameterStatus("TimeZone", "UTC"),
        ParseComplete,
      ],
      UnexpectedMessage(ParseComplete, AwaitingReadyForQuery, [
        ParameterChanged("TimeZone", "UTC"),
      ]),
    ),
    run_unexpected_test(
      "ParseComplete before BindComplete",
      [],
      [ParseComplete],
      UnexpectedMessage(ParseComplete, AwaitingBindComplete, []),
    ),
    run_unexpected_test(
      "PortalSuspended with no row limit",
      [],
      [BindComplete, PortalSuspended],
      UnexpectedMessage(PortalSuspended, ReadingExecuteRows, []),
    ),
    run_unexpected_test(
      "a DataRow with more values than the formats of Bind",
      [BinaryFormat, TextFormat],
      [
        BindComplete,
        DataRow([None, None, None]),
      ],
      UnexpectedMessage(DataRow([None, None, None]), ReadingExecuteRows, []),
    ),
    run_unexpected_test(
      "a tag whose count is not a number",
      [],
      [BindComplete, CommandComplete("SELECT x")],
      UnexpectedMessage(CommandComplete("SELECT x"), ReadingExecuteRows, []),
    ),
    run_unexpected_test(
      "a counted tag with no count",
      [],
      [BindComplete, CommandComplete("SELECT")],
      UnexpectedMessage(CommandComplete("SELECT"), ReadingExecuteRows, []),
    ),
    run_unexpected_test(
      "CloseComplete after an error",
      [],
      [ErrorResponse(unique_violation()), CloseComplete],
      UnexpectedMessage(CloseComplete, AwaitingReadyForQueryAfterError, []),
    ),
    run_unexpected_test(
      "a second ErrorResponse",
      [],
      [
        ErrorResponse(unique_violation()),
        ErrorResponse(unique_violation()),
      ],
      UnexpectedMessage(
        ErrorResponse(unique_violation()),
        AwaitingReadyForQueryAfterError,
        [],
      ),
    ),
    run_unexpected_test(
      "DataRow in a COPY TO STDOUT",
      [],
      [BindComplete, CopyOutResponse(TextFormat, []), DataRow([])],
      UnexpectedMessage(DataRow([]), ReadingCopyOut, []),
    ),
    run_unexpected_test(
      "DataRow at the end of a COPY",
      [],
      [
        BindComplete,
        CopyOutResponse(TextFormat, []),
        CopyDoneFromServer,
        DataRow([]),
      ],
      UnexpectedMessage(DataRow([]), AwaitingCopyComplete, []),
    ),
    prepare_and_run_unexpected_test(
      "BindComplete in the description of a portal",
      [ParseComplete, BindComplete, BindComplete],
      UnexpectedMessage(BindComplete, AwaitingPortalColumns, []),
    ),
    prepare_and_run_unexpected_test(
      "a DataRow with other values than the columns of the portal",
      [
        ParseComplete,
        BindComplete,
        NoData,
        DataRow([Some(<<"1">>)]),
      ],
      UnexpectedMessage(DataRow([Some(<<"1">>)]), ReadingExecuteRows, []),
    ),
    script_unexpected_test(
      "DataRow before RowDescription in a script",
      [DataRow([])],
      UnexpectedMessage(DataRow([]), AwaitingStatementResult, []),
    ),
    script_unexpected_test(
      "ReadyForQuery inside the rows of a script",
      [RowDescription([]), ReadyForQuery(Idle)],
      UnexpectedMessage(ReadyForQuery(Idle), ReadingScriptRows, []),
    ),
    script_unexpected_test(
      "a DataRow with more values than the columns of a script",
      [
        RowDescription([result_column("n", 23, 1, TextFormat)]),
        DataRow([None, None]),
      ],
      UnexpectedMessage(DataRow([None, None]), ReadingScriptRows, []),
    ),
    script_unexpected_test(
      "a tag whose count is not a number in a script",
      [CommandComplete("INSERT 0 many")],
      UnexpectedMessage(
        CommandComplete("INSERT 0 many"),
        AwaitingStatementResult,
        [],
      ),
    ),
  ]
}
