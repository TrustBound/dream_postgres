//// Tests for the copy step of `dream_postgres/driver/query`, fed with the
//// messages of the COPY flows of the PostgreSQL documentation ("Message
//// Flow", "COPY Operations") and with what the app does, one at a time,
//// with no server.

import dream_postgres/driver/message.{
  BindComplete, CommandComplete, CopyBothResponse, CopyDataFromServer,
  CopyDoneFromServer, CopyInResponse, CopyOutResponse, DataRow, ErrorResponse,
  NoticeResponse, ParseComplete, ReadyForQuery,
}
import dream_postgres/driver/query.{
  type CopyDirection, type CopyResult, type CopyState, type Failure,
  type Outcome, AwaitingParseComplete, CopyCompleted, CopyConnectionEnded,
  CopyFinished, CopyFrom, CopyNotSupported, CopyRow, CopySend, CopyStarted,
  CopyTo, CopyWait, CopyingIn, NoCopyStarted, Notice, Outcome, ServerError,
  UnexpectedMessage,
}
import dream_postgres/internal/cell.{
  type ServerReport, Idle, InFailedTransaction, ServerReport, TextFormat,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array
import gleam/list.{reverse}
import gleam/option.{None, Some}

/// The tests of the copy step.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/query copy step", [
    group("COPY FROM STDIN", copy_in_tests()),
    group("COPY TO STDOUT", copy_out_tests()),
    group("other statements", other_statement_tests()),
  ])
}

// The feeding of messages ---------------------------------------------------

/// What happens next: a message of the server, or a call of the app.
type Input {
  FromServer(message: message.BackendMessage)
  AppFinishes
  AppAbandons
  DeadlinePasses
}

/// What the step gave for one input, without its state.
type Seen {
  Started
  Row(row: BitArray)
  Sent(bytes: BitArray)
  Waited
  Finished(outcome: Outcome(CopyResult, Failure))
  ConnectionEnded(report: ServerReport)
  Unexpected(phase: query.Phase)
}

/// The step after some inputs, and what it gave for each, newest first.
type Fed {
  Fed(state: CopyState, seen: List(Seen), open: Bool)
}

fn feed(direction: CopyDirection, inputs: List(Input)) -> List(Seen) {
  let start = query.start_copy("COPY t FROM STDIN", direction)
  let fed = list.fold(inputs, Fed(start.state, [], True), feed_one)
  reverse(fed.seen)
}

fn feed_one(fed: Fed, input: Input) -> Fed {
  case fed.open, input {
    False, _ -> fed
    True, FromServer(message) ->
      seen_step(fed, query.step_copy(fed.state, message))
    True, AppFinishes -> app_step(fed, query.finish_copy(fed.state))
    True, AppAbandons -> app_step(fed, query.abandon_copy(fed.state))
    True, DeadlinePasses -> app_step(fed, query.stop_at_deadline(fed.state))
  }
}

fn app_step(fed: Fed, stepped: #(CopyState, BitArray)) -> Fed {
  Fed(state: stepped.0, seen: [Sent(stepped.1), ..fed.seen], open: True)
}

fn seen_step(
  fed: Fed,
  step: Result(query.CopyStep, query.UnexpectedMessage),
) -> Fed {
  case step {
    Ok(CopyStarted(state)) -> Fed(state, [Started, ..fed.seen], True)
    Ok(CopyRow(row, state)) -> Fed(state, [Row(row), ..fed.seen], True)
    Ok(CopySend(bytes, state)) -> Fed(state, [Sent(bytes), ..fed.seen], True)
    Ok(CopyWait(state)) -> Fed(state, [Waited, ..fed.seen], True)
    Ok(CopyFinished(outcome)) ->
      Fed(..fed, seen: [Finished(outcome), ..fed.seen], open: False)
    Ok(CopyConnectionEnded(report, _messages)) ->
      Fed(..fed, seen: [ConnectionEnded(report), ..fed.seen], open: False)
    Error(UnexpectedMessage(phase:, ..)) ->
      Fed(..fed, seen: [Unexpected(phase), ..fed.seen], open: False)
  }
}

// The values of the tests ---------------------------------------------------

fn report(severity: String, code: String, text: String) -> ServerReport {
  ServerReport(
    severity:,
    localized_severity: severity,
    code:,
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
    other_fields: [],
  )
}

fn invalid_row() -> ServerReport {
  report("ERROR", "22P02", "invalid input syntax for type integer: \"x\"")
}

fn abandoned_report() -> ServerReport {
  report(
    "ERROR",
    "57014",
    "COPY from stdin failed: the client abandoned the COPY",
  )
}

fn copy_in_start() -> List(Input) {
  [
    FromServer(ParseComplete),
    FromServer(BindComplete),
    FromServer(CopyInResponse(TextFormat, [TextFormat])),
  ]
}

fn copy_out_start() -> List(Input) {
  [
    FromServer(ParseComplete),
    FromServer(BindComplete),
    FromServer(CopyOutResponse(TextFormat, [TextFormat])),
  ]
}

const sync = <<"S", 4:32>>

const copy_done = <<"c", 4:32>>

fn copy_fail() -> BitArray {
  <<"f", 34:32, "the client abandoned the COPY":utf8, 0>>
}

fn copy_refusal() -> BitArray {
  <<"f", 39:32, "COPY is not supported by this step":utf8, 0>>
}

fn repeated_byte(count: Int) -> BitArray {
  list.repeat(<<"a":utf8>>, count) |> bit_array.concat
}

fn finished(result: Result(CopyResult, Failure), status) -> Seen {
  Finished(Outcome(result:, status:, asynchronous_messages: []))
}

// COPY FROM STDIN -----------------------------------------------------------

fn copy_in_tests() {
  [
    it("sends Parse, Bind, Execute and Sync", fn() {
      // Act
      let start = query.start_copy("COPY t FROM STDIN", CopyFrom)

      // Assert
      start.messages
      |> should
      |> be_equal([
        message.Parse(
          statement: "",
          query: "COPY t FROM STDIN",
          parameter_type_ids: [],
        ),
        message.Bind(
          portal: "",
          statement: "",
          parameters: [],
          result_formats: [],
        ),
        message.Execute(portal: "", row_limit: 0),
        message.Sync,
      ])
      |> or_fail_with("Expected Parse, Bind, Execute and Sync")
    }),
    it(
      "tells the start, ends with CopyDone and Sync, and gives the count",
      fn() {
        // Arrange
        let inputs =
          list.append(copy_in_start(), [
            AppFinishes,
            FromServer(CommandComplete("COPY 2")),
            FromServer(ReadyForQuery(Idle)),
          ])

        // Act
        let seen = feed(CopyFrom, inputs)

        // Assert
        seen
        |> should
        |> be_equal([
          Waited,
          Waited,
          Started,
          Sent(<<copy_done:bits, sync:bits>>),
          Waited,
          finished(Ok(CopyCompleted(2)), Idle),
        ])
        |> or_fail_with("Expected the start, CopyDone and Sync, then COPY 2")
      },
    ),
    it("sends Sync after a server error in the middle of the data", fn() {
      // Arrange
      let inputs =
        list.append(copy_in_start(), [
          FromServer(ErrorResponse(invalid_row())),
          AppFinishes,
          FromServer(ReadyForQuery(InFailedTransaction)),
        ])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(sync),
        Sent(<<>>),
        finished(Error(ServerError(invalid_row())), InFailedTransaction),
      ])
      |> or_fail_with("Expected one Sync, and nothing for the app's end")
    }),
    it("sends no second Sync for an error after the CopyDone", fn() {
      // Arrange
      let inputs =
        list.append(copy_in_start(), [
          AppFinishes,
          FromServer(ErrorResponse(invalid_row())),
        ])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(<<copy_done:bits, sync:bits>>),
        Waited,
      ])
      |> or_fail_with("Expected no Sync after the error")
    }),
    it("abandons the data with CopyFail and Sync", fn() {
      // Arrange
      let inputs =
        list.append(copy_in_start(), [
          AppAbandons,
          FromServer(ErrorResponse(abandoned_report())),
          FromServer(ReadyForQuery(Idle)),
        ])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(<<copy_fail():bits, sync:bits>>),
        Waited,
        finished(Error(ServerError(abandoned_report())), Idle),
      ])
      |> or_fail_with("Expected CopyFail and Sync, then the server's error")
    }),
    it("sends CopyFail and Sync at the start of an abandoned COPY", fn() {
      // Arrange
      let inputs = [AppAbandons, ..copy_in_start()]

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Sent(<<>>),
        Waited,
        Waited,
        Sent(<<copy_fail():bits, sync:bits>>),
      ])
      |> or_fail_with("Expected CopyFail and Sync instead of the start")
    }),
    it("keeps reading data after the deadline, until the app abandons it", fn() {
      // Arrange
      let start = query.start_copy("COPY t FROM STDIN", CopyFrom)
      let started =
        copy_in_start()
        |> list.fold(Fed(start.state, [], True), feed_one)
      let stopped = query.stop_at_deadline(started.state)

      // Act
      let answer = #(stopped.1, query.accepts_copy_data(stopped.0))

      // Assert
      answer
      |> should
      |> be_equal(#(<<>>, True))
      |> or_fail_with("Expected no bytes, and the COPY still reading data")
    }),
    it("takes data only while the COPY reads it", fn() {
      // Arrange
      let start = query.start_copy("COPY t FROM STDIN", CopyFrom)
      let before = query.accepts_copy_data(start.state)
      let started =
        copy_in_start()
        |> list.fold(Fed(start.state, [], True), feed_one)
      let during = query.accepts_copy_data(started.state)
      let finished = query.finish_copy(started.state)

      // Act
      let after = query.accepts_copy_data(finished.0)

      // Assert
      #(before, during, after)
      |> should
      |> be_equal(#(False, True, False))
      |> or_fail_with("Expected data only between the start and the end")
    }),
    it("frames a chunk as CopyData", fn() {
      // Act
      let bytes = query.copy_data(<<"1\n":utf8>>)

      // Assert
      bytes
      |> should
      |> be_equal(<<"d", 6:32, "1\n":utf8>>)
      |> or_fail_with("Expected one CopyData")
    }),
    it("frames a chunk longer than the piece limit as two CopyData", fn() {
      // Arrange
      let first = repeated_byte(65_536)

      // Act
      let bytes = query.copy_data(<<first:bits, "x":utf8>>)

      // Assert
      bytes
      |> should
      |> be_equal(<<"d", 65_540:32, first:bits, "d", 5:32, "x":utf8>>)
      |> or_fail_with("Expected a full piece, then the rest")
    }),
    it("frames an empty chunk as no message", fn() {
      // Act
      let bytes = query.copy_data(<<>>)

      // Assert
      bytes
      |> should
      |> be_equal(<<>>)
      |> or_fail_with("Expected no bytes")
    }),
    it("refuses a CommandComplete in the phase of the data", fn() {
      // Arrange
      let inputs =
        list.append(copy_in_start(), [
          AppFinishes,
          FromServer(CommandComplete("COPY x")),
        ])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> list.last
      |> should
      |> be_equal(Ok(Unexpected(CopyingIn)))
      |> or_fail_with("Expected an unexpected tag in the phase of the data")
    }),
    it("ends at once on a FATAL error", fn() {
      // Arrange
      let fatal = report("FATAL", "57P01", "terminating connection")
      let inputs =
        list.append(copy_in_start(), [FromServer(ErrorResponse(fatal))])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> list.last
      |> should
      |> be_equal(Ok(ConnectionEnded(fatal)))
      |> or_fail_with("Expected the end of the connection")
    }),
    it("refuses a COPY TO STDOUT and drops its rows", fn() {
      // Arrange
      let inputs =
        list.append(copy_out_start(), [
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
          FromServer(CopyDoneFromServer),
          FromServer(CommandComplete("COPY 1")),
          FromServer(ReadyForQuery(Idle)),
        ])

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Waited,
        Waited,
        Waited,
        Waited,
        finished(Error(CopyNotSupported(None)), Idle),
      ])
      |> or_fail_with("Expected the refusal with no row")
    }),
  ]
}

// COPY TO STDOUT ------------------------------------------------------------

fn copy_out_tests() {
  [
    it("tells the start and each row, and gives the count", fn() {
      // Arrange
      let inputs =
        list.append(copy_out_start(), [
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
          FromServer(NoticeResponse(report("NOTICE", "00000", "hello"))),
          FromServer(CopyDataFromServer(<<"2\n":utf8>>)),
          FromServer(CopyDoneFromServer),
          FromServer(CommandComplete("COPY 2")),
          FromServer(ReadyForQuery(Idle)),
        ])

      // Act
      let seen = feed(CopyTo, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Started,
        Row(<<"1\n":utf8>>),
        Waited,
        Row(<<"2\n":utf8>>),
        Waited,
        Waited,
        Finished(
          Outcome(
            result: Ok(CopyCompleted(2)),
            status: Idle,
            asynchronous_messages: [
              Notice(report("NOTICE", "00000", "hello")),
            ],
          ),
        ),
      ])
      |> or_fail_with("Expected the start, two rows and COPY 2")
    }),
    it("drops the rows after the app gave up the COPY", fn() {
      // Arrange
      let inputs =
        list.append(copy_out_start(), [
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
          AppFinishes,
          FromServer(CopyDataFromServer(<<"2\n":utf8>>)),
          FromServer(CopyDoneFromServer),
          FromServer(CommandComplete("COPY 2")),
          FromServer(ReadyForQuery(Idle)),
        ])

      // Act
      let seen = feed(CopyTo, inputs)

      // Assert
      seen
      |> should
      |> be_equal([
        Waited,
        Waited,
        Started,
        Row(<<"1\n":utf8>>),
        Sent(<<>>),
        Waited,
        Waited,
        Waited,
        finished(Ok(CopyCompleted(2)), Idle),
      ])
      |> or_fail_with("Expected the second row dropped")
    }),
    it("drops the rows after the deadline", fn() {
      // Arrange
      let inputs =
        list.append(copy_out_start(), [
          DeadlinePasses,
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        ])

      // Act
      let seen = feed(CopyTo, inputs)

      // Assert
      seen
      |> should
      |> be_equal([Waited, Waited, Started, Sent(<<>>), Waited])
      |> or_fail_with("Expected the row dropped")
    }),
    it("tells no start of a COPY that the app gave up before it", fn() {
      // Arrange
      let inputs =
        list.append([AppAbandons, ..copy_out_start()], [
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        ])

      // Act
      let seen = feed(CopyTo, inputs)

      // Assert
      seen
      |> should
      |> be_equal([Sent(<<>>), Waited, Waited, Waited, Waited])
      |> or_fail_with("Expected no start and no row")
    }),
    it("refuses a COPY FROM STDIN with CopyFail and Sync", fn() {
      // Act
      let seen = feed(CopyTo, copy_in_start())

      // Assert
      seen
      |> should
      |> be_equal([Waited, Waited, Sent(<<copy_refusal():bits, sync:bits>>)])
      |> or_fail_with("Expected the refusal of the COPY")
    }),
  ]
}

// Other statements ----------------------------------------------------------

fn other_statement_tests() {
  [
    it("runs a statement that is not a COPY to its end", fn() {
      // Arrange
      let inputs = [
        FromServer(ParseComplete),
        FromServer(BindComplete),
        FromServer(DataRow([Some(<<"1":utf8>>)])),
        FromServer(CommandComplete("SELECT 1")),
        FromServer(ReadyForQuery(Idle)),
      ]

      // Act
      let seen = feed(CopyFrom, inputs)

      // Assert
      seen
      |> list.last
      |> should
      |> be_equal(Ok(finished(Ok(NoCopyStarted), Idle)))
      |> or_fail_with("Expected NoCopyStarted")
    }),
    it("refuses a copy in both directions with CopyDone and Sync", fn() {
      // Arrange
      let inputs = [
        FromServer(ParseComplete),
        FromServer(BindComplete),
        FromServer(CopyBothResponse(TextFormat, [])),
      ]

      // Act
      let seen = feed(CopyTo, inputs)

      // Assert
      seen
      |> list.last
      |> should
      |> be_equal(Ok(Sent(<<copy_done:bits, sync:bits>>)))
      |> or_fail_with("Expected CopyDone and Sync")
    }),
    it("refuses a CopyInResponse before the ParseComplete", fn() {
      // Act
      let seen =
        feed(CopyFrom, [FromServer(CopyInResponse(TextFormat, [TextFormat]))])

      // Assert
      seen
      |> should
      |> be_equal([Unexpected(AwaitingParseComplete)])
      |> or_fail_with("Expected an unexpected message")
    }),
  ]
}
