//// Tests for the copy step of `dream_postgres/driver/query/copy_step`, fed with the
//// messages of the COPY flows of the PostgreSQL documentation ("Message
//// Flow", "COPY Operations") and with what the app does, one at a time,
//// with no server.

import dream_postgres/driver/cell.{
  CommandResult, Idle, InFailedTransaction, Text, TextFormat,
}
import dream_postgres/driver/message.{
  Bind, BindComplete, CommandComplete, CopyBothResponse, CopyDataFromServer,
  CopyDoneFromServer, CopyInResponse, DataRow, ErrorResponse, Execute,
  NoticeResponse, Parse, ParseComplete, ReadyForQuery, Sync,
}
import dream_postgres/driver/query/copy_step as query_copy_step
import dream_postgres/driver/query/step.{
  AwaitingParseComplete, CopyCompleted, CopyFrom, CopyNotSupported, CopyTo,
  CopyingIn, NoCopyStarted, Notice, Outcome, ServerError,
}
import dream_test/matchers.{be_equal, be_false, be_true, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/copy_step_inputs.{
  AppAbandons, AppFinishes, ConnectionEnded, DeadlinePasses, Finished,
  FromServer, Row, Sent, Started, Unexpected, Waited, abandoned_report,
  after_copy_in_start, after_copy_out_start, copy_done_and_sync,
  copy_fail_and_sync, copy_in_start, copy_refusal_and_sync, finished,
  invalid_row, repeated_byte, report, started_copy_in, sync,
}
import gleam/option.{Some}
import matchers/fed_to_copy_step.{fed_to_copy_step}

/// The tests of the copy step.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/query/copy_step", [
    group("COPY FROM STDIN", copy_in_tests()),
    group("COPY TO STDOUT", copy_out_tests()),
    group("other statements", other_statement_tests()),
  ])
}

fn copy_in_tests() {
  [
    it("sends Parse, Bind, Execute and Sync", fn() {
      query_copy_step.start_copy("COPY t FROM STDIN", CopyFrom).messages
      |> should
      |> be_equal([
        Parse(statement: "", query: "COPY t FROM STDIN", parameter_type_ids: []),
        Bind(portal: "", statement: "", parameters: [], result_formats: []),
        Execute(portal: "", row_limit: 0),
        Sync,
      ])
      |> or_fail_with("Expected Parse, Bind, Execute and Sync")
    }),
    it(
      "tells the start, ends with CopyDone and Sync, and gives the count",
      fn() {
        after_copy_in_start([
          AppFinishes,
          FromServer(CommandComplete("COPY 2")),
          FromServer(ReadyForQuery(Idle)),
        ])
        |> should
        |> fed_to_copy_step(CopyFrom)
        |> be_equal([
          Waited,
          Waited,
          Started,
          Sent(copy_done_and_sync()),
          Waited,
          finished(Ok(CopyCompleted(2)), Idle),
        ])
        |> or_fail_with("Expected the start, CopyDone and Sync, then COPY 2")
      },
    ),
    it("sends Sync after a server error in the middle of the data", fn() {
      after_copy_in_start([
        FromServer(ErrorResponse(invalid_row())),
        AppFinishes,
        FromServer(ReadyForQuery(InFailedTransaction)),
      ])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(sync()),
        Sent(<<>>),
        finished(Error(ServerError(invalid_row())), InFailedTransaction),
      ])
      |> or_fail_with("Expected one Sync, and nothing for the app's end")
    }),
    it("sends no second Sync for an error after the CopyDone", fn() {
      after_copy_in_start([
        AppFinishes,
        FromServer(ErrorResponse(invalid_row())),
      ])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([Waited, Waited, Started, Sent(copy_done_and_sync()), Waited])
      |> or_fail_with("Expected no Sync after the error")
    }),
    it("abandons the data with CopyFail and Sync", fn() {
      after_copy_in_start([
        AppAbandons,
        FromServer(ErrorResponse(abandoned_report())),
        FromServer(ReadyForQuery(Idle)),
      ])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(copy_fail_and_sync()),
        Waited,
        finished(Error(ServerError(abandoned_report())), Idle),
      ])
      |> or_fail_with("Expected CopyFail and Sync, then the server's error")
    }),
    it("sends CopyFail and Sync at the start of an abandoned COPY", fn() {
      [AppAbandons, ..copy_in_start()]
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([Sent(<<>>), Waited, Waited, Sent(copy_fail_and_sync())])
      |> or_fail_with("Expected CopyFail and Sync instead of the start")
    }),
    it("keeps reading data after the deadline, until the app abandons it", fn() {
      // Arrange
      let started = started_copy_in()

      // Act
      let #(state, _bytes) = query_copy_step.stop_at_deadline(started)
      let accepts = query_copy_step.accepts_copy_data(state)

      // Assert
      accepts
      |> should
      |> be_true
      |> or_fail_with("Expected the COPY still reading data")
    }),
    it("sends no bytes at the deadline of a COPY FROM STDIN", fn() {
      // Arrange
      let started = started_copy_in()

      // Act
      let #(_state, bytes) = query_copy_step.stop_at_deadline(started)

      // Assert
      bytes
      |> should
      |> be_equal(<<>>)
      |> or_fail_with("Expected no bytes")
    }),
    it("takes no data before the start of a COPY FROM STDIN", fn() {
      // Act
      let start = query_copy_step.start_copy("COPY t FROM STDIN", CopyFrom)
      let accepts = query_copy_step.accepts_copy_data(start.state)

      // Assert
      accepts
      |> should
      |> be_false
      |> or_fail_with("Expected no data before the start")
    }),
    it("takes data only while the COPY reads it", fn() {
      // Arrange
      let started = started_copy_in()

      // Act
      let accepts = query_copy_step.accepts_copy_data(started)

      // Assert
      accepts
      |> should
      |> be_true
      |> or_fail_with("Expected data between the start and the end")
    }),
    it("takes no data after the app finished the COPY", fn() {
      // Arrange
      let started = started_copy_in()

      // Act
      let #(finished_state, _bytes) = query_copy_step.finish_copy(started)
      let accepts = query_copy_step.accepts_copy_data(finished_state)

      // Assert
      accepts
      |> should
      |> be_false
      |> or_fail_with("Expected no data after the end")
    }),
    it("frames a chunk as CopyData", fn() {
      query_copy_step.copy_data(<<"1\n":utf8>>)
      |> should
      |> be_equal(<<"d", 6:32, "1\n":utf8>>)
      |> or_fail_with("Expected one CopyData")
    }),
    it("frames a chunk longer than the piece limit as two CopyData", fn() {
      query_copy_step.copy_data(<<repeated_byte(65_536):bits, "x":utf8>>)
      |> should
      |> be_equal(<<
        "d",
        65_540:32,
        repeated_byte(65_536):bits,
        "d",
        5:32,
        "x":utf8,
      >>)
      |> or_fail_with("Expected a full piece, then the rest")
    }),
    it("frames an empty chunk as no message", fn() {
      query_copy_step.copy_data(<<>>)
      |> should
      |> be_equal(<<>>)
      |> or_fail_with("Expected no bytes")
    }),
    it("refuses a CommandComplete in the phase of the data", fn() {
      after_copy_in_start([AppFinishes, FromServer(CommandComplete("COPY x"))])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Started,
        Sent(copy_done_and_sync()),
        Unexpected(CopyingIn),
      ])
      |> or_fail_with("Expected an unexpected tag in the phase of the data")
    }),
    it("ends at once on a FATAL error", fn() {
      after_copy_in_start([
        FromServer(
          ErrorResponse(report("FATAL", "57P01", "terminating connection")),
        ),
      ])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Started,
        ConnectionEnded(report("FATAL", "57P01", "terminating connection")),
      ])
      |> or_fail_with("Expected the end of the connection")
    }),
    it("runs a COPY TO STDOUT to its end, with its tag and no row", fn() {
      after_copy_out_start([
        FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        FromServer(CopyDoneFromServer),
        FromServer(CommandComplete("COPY 1")),
        FromServer(ReadyForQuery(Idle)),
      ])
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Waited,
        Waited,
        Waited,
        Waited,
        finished(Ok(NoCopyStarted(CommandResult([], "COPY 1", 1))), Idle),
      ])
      |> or_fail_with("Expected the COPY TO STDOUT completed, with no row")
    }),
  ]
}

fn copy_out_tests() {
  [
    it("tells the start and each row, and gives the count", fn() {
      after_copy_out_start([
        FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        FromServer(NoticeResponse(report("NOTICE", "00000", "hello"))),
        FromServer(CopyDataFromServer(<<"2\n":utf8>>)),
        FromServer(CopyDoneFromServer),
        FromServer(CommandComplete("COPY 2")),
        FromServer(ReadyForQuery(Idle)),
      ])
      |> should
      |> fed_to_copy_step(CopyTo)
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
            asynchronous_messages: [Notice(report("NOTICE", "00000", "hello"))],
          ),
        ),
      ])
      |> or_fail_with("Expected the start, two rows and COPY 2")
    }),
    it("drops the rows after the app gave up the COPY", fn() {
      after_copy_out_start([
        FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        AppFinishes,
        FromServer(CopyDataFromServer(<<"2\n":utf8>>)),
        FromServer(CopyDoneFromServer),
        FromServer(CommandComplete("COPY 2")),
        FromServer(ReadyForQuery(Idle)),
      ])
      |> should
      |> fed_to_copy_step(CopyTo)
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
      after_copy_out_start([
        DeadlinePasses,
        FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
      ])
      |> should
      |> fed_to_copy_step(CopyTo)
      |> be_equal([Waited, Waited, Started, Sent(<<>>), Waited])
      |> or_fail_with("Expected the row dropped")
    }),
    it("tells no start of a COPY that the app gave up before it", fn() {
      [
        AppAbandons,
        ..after_copy_out_start([
          FromServer(CopyDataFromServer(<<"1\n":utf8>>)),
        ])
      ]
      |> should
      |> fed_to_copy_step(CopyTo)
      |> be_equal([Sent(<<>>), Waited, Waited, Waited, Waited])
      |> or_fail_with("Expected no start and no row")
    }),
    it("refuses a COPY FROM STDIN with CopyFail and Sync", fn() {
      copy_in_start()
      |> should
      |> fed_to_copy_step(CopyTo)
      |> be_equal([Waited, Waited, Sent(copy_refusal_and_sync())])
      |> or_fail_with("Expected the refusal of the COPY")
    }),
    it("gives the refusal of a COPY FROM STDIN with the server's error", fn() {
      after_copy_in_start([
        FromServer(ErrorResponse(abandoned_report())),
        FromServer(ReadyForQuery(Idle)),
      ])
      |> should
      |> fed_to_copy_step(CopyTo)
      |> be_equal([
        Waited,
        Waited,
        Sent(copy_refusal_and_sync()),
        Waited,
        finished(Error(CopyNotSupported(Some(abandoned_report()))), Idle),
      ])
      |> or_fail_with("Expected CopyNotSupported with the server's error")
    }),
  ]
}

fn other_statement_tests() {
  [
    it("runs a statement that is not a COPY to its end, with its rows", fn() {
      [
        FromServer(ParseComplete),
        FromServer(BindComplete),
        FromServer(DataRow([Some(<<"1":utf8>>)])),
        FromServer(CommandComplete("SELECT 1")),
        FromServer(ReadyForQuery(Idle)),
      ]
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([
        Waited,
        Waited,
        Waited,
        Waited,
        finished(
          Ok(
            NoCopyStarted(CommandResult([[Text(<<"1":utf8>>)]], "SELECT 1", 1)),
          ),
          Idle,
        ),
      ])
      |> or_fail_with("Expected NoCopyStarted with the row")
    }),
    it("refuses a copy in both directions with CopyDone and Sync", fn() {
      [
        FromServer(ParseComplete),
        FromServer(BindComplete),
        FromServer(CopyBothResponse(TextFormat, [])),
      ]
      |> should
      |> fed_to_copy_step(CopyTo)
      |> be_equal([Waited, Waited, Sent(copy_done_and_sync())])
      |> or_fail_with("Expected CopyDone and Sync")
    }),
    it("refuses a CopyInResponse before the ParseComplete", fn() {
      [FromServer(CopyInResponse(TextFormat, [TextFormat]))]
      |> should
      |> fed_to_copy_step(CopyFrom)
      |> be_equal([Unexpected(AwaitingParseComplete)])
      |> or_fail_with("Expected an unexpected message")
    }),
  ]
}
