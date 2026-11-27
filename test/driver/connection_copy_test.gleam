//// Tests for COPY in `dream_postgres/driver/connection`: `copy_from` and
//// `copy_to` on the driver servers of PostgreSQL 16 to 19. The scenarios
//// are in `fixtures/copy_scenarios`.

import dream_postgres/driver/connection.{
  AppFailed, CopyNotRunning, CopyNotStarted, DriverFailed, InvalidRequest,
  Outcome,
}
import dream_postgres/driver/message.{ZeroByteInString}
import dream_postgres/internal/cell.{
  CommandResult, Idle, InFailedTransaction, Text,
}
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import fixtures/copy_scenarios
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import matchers/within_memory.{within_memory}

/// The bound of the memory of each process during a COPY of 1,000,000
/// rows, in bytes: far less than the 16,000,000 bytes of its data.
const memory_bound = 2_000_000

/// The tests of COPY.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/connection COPY", [
    group("on each server", map(driver_servers(), server_tests)),
    group("memory", memory_tests()),
    group("deadlines", deadline_tests()),
    group("callers", caller_tests()),
    group("losses", loss_tests()),
  ])
}

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("stores the rows of a COPY FROM STDIN and gives their count", fn() {
      copy_scenarios.store_three_rows(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Ok(3), ["1", "one", "2", "two", "3", "three"]))
      |> or_fail_with("Expected three rows stored")
    }),
    it("reads the rows of a COPY TO STDOUT one at a time", fn() {
      copy_scenarios.read_three_rows(server.port)
      |> should
      |> be_ok
      |> be_equal(
        Ok([<<"3\tr3\n":utf8>>, <<"2\tr2\n":utf8>>, <<"1\tr1\n":utf8>>]),
      )
      |> or_fail_with("Expected each row as its own bytes")
    }),
    it("gives a row that is longer than one read of the socket", fn() {
      copy_scenarios.read_long_row(server.port)
      |> should
      |> be_ok
      |> be_equal(Ok([4_000_001]))
      |> or_fail_with("Expected one row of 4,000,001 bytes")
    }),
    it("moves the bytes of a csv COPY both ways", fn() {
      copy_scenarios.copy_csv_both_ways(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Ok(2), Ok([<<"2,\"b,c\"\n":utf8>>, <<"1,a\n":utf8>>])))
      |> or_fail_with("Expected the csv rows back")
    }),
    it("moves the bytes of a binary COPY both ways", fn() {
      copy_scenarios.copy_binary_both_ways(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Ok(1), Ok(copy_scenarios.binary_copy())))
      |> or_fail_with("Expected the same binary COPY data back")
    }),
    it("commits and rolls back a COPY with its transaction", fn() {
      copy_scenarios.copy_in_transactions(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Ok(3), "0", Ok(3), "3"))
      |> or_fail_with("Expected no row after ROLLBACK and three after COMMIT")
    }),
    it("fails the transaction with a COPY that the app abandoned", fn() {
      copy_scenarios.abandon_in_transaction(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Error(AppFailed("stopped")), InFailedTransaction))
      |> or_fail_with("Expected the app's failure in a failed transaction")
    }),
    it("ends the COPY at a server error in the middle and stays usable", fn() {
      copy_scenarios.refuse_in_the_middle(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Error("app 22P02"), "0"))
      |> or_fail_with("Expected the app's failure with 22P02, and no row")
    }),
    it("gives the server's error when the app sent all its data", fn() {
      copy_scenarios.refuse_after_the_data(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Error("driver 22P02"), Idle))
      |> or_fail_with("Expected the server's 22P02")
    }),
    it("abandons the COPY with CopyFail when the app fails", fn() {
      copy_scenarios.abandon_on_app_failure(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Error(AppFailed("stopped")), "0"))
      |> or_fail_with("Expected the app's failure, and no row stored")
    }),
    it("reads the rest of a COPY TO STDOUT when the app fails", fn() {
      copy_scenarios.fail_the_fold(server.port)
      |> should
      |> be_ok
      |> be_equal(#(Error(AppFailed("enough")), ["SELECT 1"]))
      |> or_fail_with("Expected the app's failure, then a usable connection")
    }),
    it("gives what ran in place of the COPY", fn() {
      copy_scenarios.start_no_copy(server.port)
      |> should
      |> be_ok
      |> be_equal(#(
        Error(
          DriverFailed(
            CopyNotStarted(
              Some(Outcome(
                columns: [],
                result: CommandResult([[Text(<<"1":utf8>>)]], "SELECT 1", 1),
                notices: [],
                notifications: [],
                transaction_status: Idle,
              )),
            ),
          ),
        ),
        Error(
          DriverFailed(
            CopyNotStarted(
              Some(Outcome(
                columns: [],
                result: CommandResult([], "COPY 0", 0),
                notices: [],
                notifications: [],
                transaction_status: Idle,
              )),
            ),
          ),
        ),
        Error(DriverFailed(CopyNotStarted(None))),
        "0",
      ))
      |> or_fail_with(
        "Expected the SELECT, the COPY TO STDOUT, and no outcome for the refused COPY",
      )
    }),
    it(
      "gives the server's error for a COPY of a table that does not exist",
      fn() {
        copy_scenarios.copy_missing_table(server.port)
        |> should
        |> be_ok
        |> be_equal(Error("driver 42P01"))
        |> or_fail_with("Expected 42P01")
      },
    ),
    it("gives the end of the session in the middle of a COPY", fn() {
      copy_scenarios.end_the_session_in_the_middle(server.port)
      |> should
      |> be_ok
      |> be_equal(Error("driver ended 57P01"))
      |> or_fail_with("Expected the server's 57P01")
    }),
  ])
}

fn memory_tests() {
  [
    it("keeps the memory flat while it loads 1,000,000 rows", fn() {
      copy_scenarios.load_million_rows()
      |> should
      |> be_ok
      |> within_memory(memory_bound, 0)
      |> be_equal(1_000_000)
      |> or_fail_with("Expected 1,000,000 rows stored")
    }),
    it("keeps the memory flat while it reads 1,000,000 rows", fn() {
      copy_scenarios.read_million_rows()
      |> should
      |> be_ok
      |> within_memory(memory_bound, 1)
      |> be_equal(1_000_000)
      |> or_fail_with("Expected 1,000,000 rows read")
    }),
  ]
}

fn deadline_tests() {
  [
    it("ends a COPY FROM STDIN at its deadline while the app sends", fn() {
      copy_scenarios.pass_the_deadline_while_sending()
      |> should
      |> be_ok
      |> be_equal(#(Error("driver deadline cancelled"), "0"))
      |> or_fail_with("Expected DeadlinePassed(True), and no row stored")
    }),
    it("cuts off a slow produce function at its deadline", fn() {
      copy_scenarios.cut_off_a_slow_producer()
      |> should
      |> be_ok
      |> be_equal(#(Error("driver deadline cancelled"), "0"))
      |> or_fail_with("Expected the end of the COPY at the deadline")
    }),
    it("cuts off a slow fold at its deadline", fn() {
      copy_scenarios.cut_off_a_slow_fold()
      |> should
      |> be_ok
      |> be_equal(#(Error("driver deadline cancelled"), ["SELECT 1"]))
      |> or_fail_with("Expected DeadlinePassed(True), then a usable connection")
    }),
    it("cuts off the reading of the rest after a failed fold", fn() {
      copy_scenarios.cut_off_the_rest_after_a_failed_fold()
      |> should
      |> be_ok
      |> be_equal(#(Error("driver deadline cancelled"), ["SELECT 1"]))
      |> or_fail_with("Expected the deadline to end the reading of the rest")
    }),
    it("serves no other request of the caller while its COPY runs", fn() {
      copy_scenarios.request_inside_a_copy()
      |> should
      |> be_ok
      |> be_equal(Error(AppFailed(#("deadline", "driver deadline"))))
      |> or_fail_with("Expected both inner requests to wait to their deadline")
    }),
  ]
}

fn caller_tests() {
  [
    it("abandons a COPY FROM STDIN when its caller ends", fn() {
      copy_scenarios.end_the_caller_while_it_sends()
      |> should
      |> be_ok
      |> be_equal(#("sent", "0"))
      |> or_fail_with("Expected no row stored, and a usable connection")
    }),
    it("drops the end of a COPY when its caller ends before it took it", fn() {
      copy_scenarios.end_the_caller_after_the_refusal()
      |> should
      |> be_ok
      |> be_equal(#("22P02", "0"))
      |> or_fail_with("Expected the refusal, then a usable connection")
    }),
    it("reads the rest of a COPY TO STDOUT when its caller ends", fn() {
      copy_scenarios.end_the_caller_while_it_reads()
      |> should
      |> be_ok
      |> be_equal(#("row", ["SELECT 1"]))
      |> or_fail_with("Expected a usable connection")
    }),
    it("ignores the DOWN of a process that it does not watch", fn() {
      copy_scenarios.send_a_stray_down()
      |> should
      |> be_ok
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the connection to work")
    }),
    it("refuses a chunk after its COPY ended", fn() {
      copy_scenarios.send_after_the_end()
      |> should
      |> be_ok
      |> be_equal(#(Ok(0), Ok(Error(CopyNotRunning))))
      |> or_fail_with("Expected CopyNotRunning")
    }),
    it("gives the error of the COPY again to a chunk after it", fn() {
      copy_scenarios.send_after_the_refusal()
      |> should
      |> be_ok
      |> be_equal(Error("app 23514, then 23514"))
      |> or_fail_with("Expected 23514 for the chunk after the error")
    }),
    it("refuses a COPY with a zero byte before it sends anything", fn() {
      copy_scenarios.copy_with_a_zero_byte()
      |> should
      |> be_ok
      |> be_equal(
        Error(DriverFailed(InvalidRequest(ZeroByteInString("query")))),
      )
      |> or_fail_with("Expected InvalidRequest")
    }),
  ]
}

fn loss_tests() {
  [
    it("gives the loss of the connection in the middle of a COPY", fn() {
      copy_scenarios.close_in_the_middle()
      |> should
      |> be_ok
      |> be_equal(Error("driver lost"))
      |> or_fail_with("Expected the loss of the connection")
    }),
    it("gives a violation in the middle of a COPY", fn() {
      copy_scenarios.break_the_protocol_in_the_middle()
      |> should
      |> be_ok
      |> be_equal(Error("driver violation"))
      |> or_fail_with("Expected the violation")
    }),
    it("loses the connection when a chunk cannot be sent in time", fn() {
      copy_scenarios.fill_the_socket()
      |> should
      |> be_ok
      |> be_equal(Error("driver lost send timeout"))
      |> or_fail_with("Expected the loss by a send timeout")
    }),
    it("gives the loss of the connection to the next row of a COPY", fn() {
      copy_scenarios.close_while_reading()
      |> should
      |> be_ok
      |> be_equal(Error("driver lost closed"))
      |> or_fail_with("Expected the loss of the connection")
    }),
    it("gives the server's last error when a write fails after it", fn() {
      copy_scenarios.fail_a_write_after_the_error()
      |> should
      |> be_ok
      |> be_equal(Error("ended 57P01"))
      |> or_fail_with("Expected the FATAL 57P01, not the failed write")
    }),
    it("gives the failure of a TLS write after a reset", fn() {
      copy_scenarios.fail_a_tls_write_after_a_reset()
      |> should
      |> be_ok
      |> be_equal(Error("lost closed"))
      |> or_fail_with("Expected the loss by the closed socket")
    }),
    it("gives the server's last error when a chunk fails after it", fn() {
      copy_scenarios.fail_a_chunk_after_the_error()
      |> should
      |> be_ok
      |> be_equal(Error("driver ended 57P01"))
      |> or_fail_with("Expected the FATAL 57P01, not the failed chunk")
    }),
  ]
}
