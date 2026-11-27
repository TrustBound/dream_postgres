//// Tests for COPY in `dream_postgres/driver/connection`: `copy_from` and
//// `copy_to` on the driver servers of PostgreSQL 16 to 19. The produce
//// functions and folds are in `fixtures/copy_callbacks`.

import dream_postgres/driver/connection.{
  ConnectionLost, CopyNotRunning, CopyNotStarted, DeadlinePassed, InvalidRequest,
  Outcome, SocketFailed, copy_from, copy_to, run_script, send_chunk, stop,
  transaction_status,
}
import dream_postgres/driver/message.{ZeroByteInString}
import dream_postgres/driver/transport.{SendTimedOut, SocketClosed}
import dream_postgres/internal/cell.{
  CommandResult, Idle, InFailedTransaction, Text,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/proxy.{answer_next_request, inject, reset_client}
import driver/server_connection.{
  backend_pid, caller_answer, fatal_error_bytes, pid_of, resume_connection,
  send_stray_down, start_caller, start_connection, start_proxied,
  start_proxied_with_tls, stop_proxied, suspend_connection, wait_for_message,
  wait_for_reset,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/copy_callbacks.{
  MemoryPeak, append_row, await_go, binary_copy, caller_told, close_at_first_row,
  collect_row, collect_size, copy_inside, count_and_sample, fail_at_first_row,
  fail_at_second_row, hang_after_refusal, hang_after_rows, hang_at_first_row,
  keep_sender, kept_sender, load_chunks_sampling, read_until_idle,
  send_across_close, send_across_violation, send_after_end, send_after_go,
  send_after_idle, send_bad_row, send_binary, send_csv, send_then_fail,
  send_three_rows, send_twice_after_error, send_until_error, send_until_refused,
  start_copy_caller,
}
import fixtures/driver_tls.{verify_full}
import gleam/bit_array
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None, Some}
import gleam/string.{repeat}
import matchers/extract_app_failure.{extract_app_failure}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_copy_driver_error.{extract_copy_driver_error}
import matchers/extract_driver_error_code.{extract_driver_error_code}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_first.{extract_first}
import matchers/extract_first_of_pair.{extract_first_of_pair}
import matchers/extract_loss_reason.{extract_loss_reason}
import matchers/extract_outcome_tags.{extract_outcome_tags}
import matchers/extract_protocol_violation.{extract_protocol_violation}
import matchers/extract_report_code.{extract_report_code}
import matchers/extract_sampled_peak.{extract_sampled_peak}
import matchers/extract_second_of_pair.{extract_second_of_pair}
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
    group("writes after the server's last error", write_failure_tests()),
  ])
}

fn server_tests(server: Server) {
  group(
    "PostgreSQL " <> to_string(server.version),
    list.flatten([
      store_tests(server),
      both_ways_tests(server),
      transaction_tests(server),
      refusal_tests(server),
      app_failure_tests(server),
      no_copy_tests(server),
    ]),
  )
}

fn store_tests(server: Server) {
  [
    it("stores the rows of a COPY FROM STDIN and gives their count", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE copied (id int, name text)",
          5000,
        )

      // Act
      let stored =
        copy_from(connection, "COPY copied FROM STDIN", 5000, send_three_rows)
      stop(connection)

      // Assert
      stored
      |> should
      |> be_ok
      |> be_equal(3)
      |> or_fail_with("Expected three rows stored")
    }),
    it("stores the rows that a COPY FROM STDIN sent", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE copied (id int, name text)",
          5000,
        )

      // Act
      let _stored =
        copy_from(connection, "COPY copied FROM STDIN", 5000, send_three_rows)
      let rows =
        run_script(
          connection,
          "SELECT id::text, name FROM copied ORDER BY id",
          5000,
        )
      stop(connection)

      // Assert
      rows
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([
        [Text(<<"1">>), Text(<<"one">>)],
        [Text(<<"2">>), Text(<<"two">>)],
        [Text(<<"3">>), Text(<<"three">>)],
      ])
      |> or_fail_with("Expected the three rows in the table")
    }),
    it("reads the rows of a COPY TO STDOUT one at a time", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let rows =
        copy_to(
          connection,
          "COPY (SELECT n, 'r' || n FROM generate_series(1, 3) n) TO STDOUT",
          5000,
          [],
          collect_row,
        )
      stop(connection)

      // Assert
      rows
      |> should
      |> be_ok
      |> be_equal([<<"3\tr3\n":utf8>>, <<"2\tr2\n":utf8>>, <<"1\tr1\n":utf8>>])
      |> or_fail_with("Expected each row as its own bytes")
    }),
    it("gives a row that is longer than one read of the socket", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let sizes =
        copy_to(
          connection,
          "COPY (SELECT repeat('x', 4000000)) TO STDOUT",
          5000,
          [],
          collect_size,
        )
      stop(connection)

      // Assert
      sizes
      |> should
      |> be_ok
      |> be_equal([4_000_001])
      |> or_fail_with("Expected one row of 4,000,001 bytes")
    }),
  ]
}

fn both_ways_tests(server: Server) {
  [
    it("stores the rows of a csv COPY", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE csv (id int, name text)",
          5000,
        )

      // Act
      let stored =
        copy_from(
          connection,
          "COPY csv FROM STDIN (FORMAT csv)",
          5000,
          send_csv,
        )
      stop(connection)

      // Assert
      stored
      |> should
      |> be_ok
      |> be_equal(2)
      |> or_fail_with("Expected two csv rows stored")
    }),
    it("moves the bytes of a csv COPY both ways", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE csv (id int, name text)",
          5000,
        )

      // Act
      let _stored =
        copy_from(
          connection,
          "COPY csv FROM STDIN (FORMAT csv)",
          5000,
          send_csv,
        )
      let rows =
        copy_to(
          connection,
          "COPY csv TO STDOUT (FORMAT csv)",
          5000,
          [],
          collect_row,
        )
      stop(connection)

      // Assert
      rows
      |> should
      |> be_ok
      |> be_equal([<<"2,\"b,c\"\n":utf8>>, <<"1,a\n":utf8>>])
      |> or_fail_with("Expected the csv rows back")
    }),
    it("stores the row of a binary COPY", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(connection, "CREATE TEMP TABLE b (n int4)", 5000)

      // Act
      let stored =
        copy_from(
          connection,
          "COPY b FROM STDIN (FORMAT binary)",
          5000,
          send_binary,
        )
      stop(connection)

      // Assert
      stored
      |> should
      |> be_ok
      |> be_equal(1)
      |> or_fail_with("Expected one binary row stored")
    }),
    it("moves the bytes of a binary COPY both ways", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(connection, "CREATE TEMP TABLE b (n int4)", 5000)

      // Act
      let _stored =
        copy_from(
          connection,
          "COPY b FROM STDIN (FORMAT binary)",
          5000,
          send_binary,
        )
      let data =
        copy_to(
          connection,
          "COPY b TO STDOUT (FORMAT binary)",
          5000,
          <<>>,
          append_row,
        )
      stop(connection)

      // Assert
      data
      |> should
      |> be_ok
      |> be_equal(binary_copy())
      |> or_fail_with("Expected the same binary COPY data back")
    }),
  ]
}

fn transaction_tests(server: Server) {
  [
    it("gives the count of a COPY in a transaction that rolls back", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE kept (id int, name text)",
          5000,
        )

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let rolled_back =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _rolled_back = run_script(connection, "ROLLBACK", 5000)
      stop(connection)

      // Assert
      rolled_back
      |> should
      |> be_ok
      |> be_equal(3)
      |> or_fail_with("Expected three rows copied before the ROLLBACK")
    }),
    it("commits and rolls back a COPY with its transaction", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE kept (id int, name text)",
          5000,
        )

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let _rolled_back =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _ended = run_script(connection, "ROLLBACK", 5000)
      let count =
        run_script(connection, "SELECT count(*)::text FROM kept", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row after ROLLBACK")
    }),
    it("gives the count of a COPY in a transaction that commits", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE kept (id int, name text)",
          5000,
        )
      let _begun = run_script(connection, "BEGIN", 5000)
      let _rolled_back =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _ended = run_script(connection, "ROLLBACK", 5000)

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let committed =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _committed = run_script(connection, "COMMIT", 5000)
      stop(connection)

      // Assert
      committed
      |> should
      |> be_ok
      |> be_equal(3)
      |> or_fail_with("Expected three rows copied before the COMMIT")
    }),
    it("keeps the rows of a COPY in a transaction that commits", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE kept (id int, name text)",
          5000,
        )
      let _begun = run_script(connection, "BEGIN", 5000)
      let _rolled_back =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _ended = run_script(connection, "ROLLBACK", 5000)

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let _committed =
        copy_from(connection, "COPY kept FROM STDIN", 5000, send_three_rows)
      let _ended = run_script(connection, "COMMIT", 5000)
      let count =
        run_script(connection, "SELECT count(*)::text FROM kept", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"3">>)]])
      |> or_fail_with("Expected three rows after COMMIT")
    }),
    it("fails the transaction with a COPY that the app abandoned", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE failing (id int, name text)",
          5000,
        )

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let _failed =
        copy_from(connection, "COPY failing FROM STDIN", 5000, send_then_fail)
      let status = transaction_status(connection)
      let _rolled_back = run_script(connection, "ROLLBACK", 5000)
      stop(connection)

      // Assert
      status
      |> should
      |> be_ok
      |> be_equal(InFailedTransaction)
      |> or_fail_with("Expected a failed transaction")
    }),
    it("gives the app's failure of a COPY in a transaction", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE failing (id int, name text)",
          5000,
        )

      // Act
      let _begun = run_script(connection, "BEGIN", 5000)
      let failed =
        copy_from(connection, "COPY failing FROM STDIN", 5000, send_then_fail)
      let _rolled_back = run_script(connection, "ROLLBACK", 5000)
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_app_failure
      |> be_equal("stopped")
      |> or_fail_with("Expected the app's failure")
    }),
  ]
}

fn refusal_tests(server: Server) {
  [
    it("ends the COPY at a server error in the middle and stays usable", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE refused (id int, name text)",
          5000,
        )

      // Act
      let refused =
        copy_from(
          connection,
          "COPY refused FROM STDIN",
          5000,
          send_until_refused,
        )
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_app_failure
      |> extract_driver_error_code
      |> be_equal("22P02")
      |> or_fail_with("Expected the app's failure with 22P02")
    }),
    it("stores no row of a COPY that the server refused in the middle", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE refused (id int, name text)",
          5000,
        )

      // Act
      let _refused =
        copy_from(
          connection,
          "COPY refused FROM STDIN",
          5000,
          send_until_refused,
        )
      let count =
        run_script(connection, "SELECT count(*)::text FROM refused", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row")
    }),
    it("gives the server's error when the app sent all its data", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE bad (id int, name text)",
          5000,
        )

      // Act
      let refused =
        copy_from(connection, "COPY bad FROM STDIN", 5000, send_bad_row)
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> extract_driver_error_code
      |> be_equal("22P02")
      |> or_fail_with("Expected the server's 22P02")
    }),
    it("is idle after the server's error for the app's data", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE bad (id int, name text)",
          5000,
        )

      // Act
      let _refused =
        copy_from(connection, "COPY bad FROM STDIN", 5000, send_bad_row)
      let status = transaction_status(connection)
      stop(connection)

      // Assert
      status
      |> should
      |> be_ok
      |> be_equal(Idle)
      |> or_fail_with("Expected Idle after the server's error")
    }),
    it(
      "gives the server's error for a COPY of a table that does not exist",
      fn() {
        // Arrange
        let connection = start_connection(server.port)

        // Act
        let refused =
          copy_from(
            connection,
            "COPY no_such_table FROM STDIN",
            5000,
            send_three_rows,
          )
        stop(connection)

        // Assert
        refused
        |> should
        |> be_error
        |> extract_copy_driver_error
        |> extract_driver_error_code
        |> be_equal("42P01")
        |> or_fail_with("Expected 42P01")
      },
    ),
    it("gives the end of the session in the middle of a COPY", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let control = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE ended (id int, name text)",
          5000,
        )
      let pid = backend_pid(connection)

      // Act
      let ended =
        copy_from(connection, "COPY ended FROM STDIN", 5000, send_after_end(
          _,
          control,
          pid,
        ))
      stop(connection)
      stop(control)

      // Assert
      ended
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> extract_ending_report
      |> extract_report_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the server's 57P01")
    }),
  ]
}

fn app_failure_tests(server: Server) {
  [
    it("abandons the COPY with CopyFail when the app fails", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE abandoned (id int, name text)",
          5000,
        )

      // Act
      let failed =
        copy_from(connection, "COPY abandoned FROM STDIN", 5000, send_then_fail)
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_app_failure
      |> be_equal("stopped")
      |> or_fail_with("Expected the app's failure")
    }),
    it("stores no row of a COPY that the app abandoned", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE abandoned (id int, name text)",
          5000,
        )

      // Act
      let _failed =
        copy_from(connection, "COPY abandoned FROM STDIN", 5000, send_then_fail)
      let count =
        run_script(connection, "SELECT count(*)::text FROM abandoned", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row stored")
    }),
    it("gives the app's failure of a fold of a COPY TO STDOUT", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let failed =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
          5000,
          0,
          fail_at_second_row,
        )
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_app_failure
      |> be_equal("enough")
      |> or_fail_with("Expected the app's failure")
    }),
    it("reads the rest of a COPY TO STDOUT when the app fails", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let _failed =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
          5000,
          0,
          fail_at_second_row,
        )
      let next = run_script(connection, "SELECT 7", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected a usable connection")
    }),
  ]
}

fn no_copy_tests(server: Server) {
  [
    it("gives what ran in place of the COPY", fn() {
      // Arrange
      let connection = start_connection(server.port)

      // Act
      let select = copy_from(connection, "SELECT 1", 5000, send_three_rows)
      stop(connection)

      // Assert
      select
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(
        CopyNotStarted(
          Some(Outcome(
            columns: [],
            result: CommandResult([[Text(<<"1":utf8>>)]], "SELECT 1", 1),
            notices: [],
            notifications: [],
            transaction_status: Idle,
          )),
        ),
      )
      |> or_fail_with("Expected the SELECT")
    }),
    it("gives the COPY TO STDOUT that copy_from ran in place of a COPY", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE other (id int, name text)",
          5000,
        )

      // Act
      let out =
        copy_from(connection, "COPY other TO STDOUT", 5000, send_three_rows)
      stop(connection)

      // Assert
      out
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(
        CopyNotStarted(
          Some(Outcome(
            columns: [],
            result: CommandResult([], "COPY 0", 0),
            notices: [],
            notifications: [],
            transaction_status: Idle,
          )),
        ),
      )
      |> or_fail_with("Expected the COPY TO STDOUT")
    }),
    it("gives no outcome for a COPY FROM STDIN that copy_to refused", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE other (id int, name text)",
          5000,
        )

      // Act
      let into =
        copy_to(connection, "COPY other FROM STDIN", 5000, [], collect_row)
      stop(connection)

      // Assert
      into
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(CopyNotStarted(None))
      |> or_fail_with("Expected no outcome for the refused COPY")
    }),
    it("stores no row of a COPY that did not start", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE other (id int, name text)",
          5000,
        )

      // Act
      let _select = copy_from(connection, "SELECT 1", 5000, send_three_rows)
      let _out =
        copy_from(connection, "COPY other TO STDOUT", 5000, send_three_rows)
      let _into =
        copy_to(connection, "COPY other FROM STDIN", 5000, [], collect_row)
      let count =
        run_script(connection, "SELECT count(*)::text FROM other", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row")
    }),
  ]
}

fn memory_tests() {
  [
    it("keeps the memory flat while it loads 1,000,000 rows", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE loaded (n int, name text)",
          5000,
        )
      let peaks = process.new_subject()
      let connection_pid = pid_of(connection)

      // Act
      let stored =
        copy_from(
          connection,
          "COPY loaded FROM STDIN",
          5000,
          load_chunks_sampling(_, connection_pid, peaks),
        )
      stop(connection)

      // Assert
      stored
      |> should
      |> be_ok
      |> extract_sampled_peak(from: peaks)
      |> within_memory(memory_bound, 0)
      |> be_equal(1_000_000)
      |> or_fail_with("Expected 1,000,000 rows stored")
    }),
    it("keeps the memory flat while it reads 1,000,000 rows", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let connection_pid = pid_of(connection)

      // Act
      let counted =
        copy_to(
          connection,
          "COPY (SELECT n, 'some text' FROM generate_series(1, 1000000) n) TO STDOUT",
          60_000,
          #(0, MemoryPeak(0, 0, 0)),
          fn(sampled, row) { count_and_sample(sampled, row, connection_pid) },
        )
      stop(connection)

      // Assert
      counted
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
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE late (id int, name text)",
          5000,
        )
      let chunk = bit_array.from_string(repeat("1\tone\n", 1000))

      // Act
      let late =
        copy_from(connection, "COPY late FROM STDIN", 300, send_until_error(
          _,
          chunk,
          1_000_000,
        ))
      stop(connection)

      // Assert
      late
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(DeadlinePassed(cancelled: True))
      |> or_fail_with("Expected DeadlinePassed(True)")
    }),
    it("stores no row of a COPY FROM STDIN that passed its deadline", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE late (id int, name text)",
          5000,
        )
      let chunk = bit_array.from_string(repeat("1\tone\n", 1000))

      // Act
      let _late =
        copy_from(connection, "COPY late FROM STDIN", 300, send_until_error(
          _,
          chunk,
          1_000_000,
        ))
      let count =
        run_script(connection, "SELECT count(*)::text FROM late", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row stored")
    }),
    it("cuts off a slow produce function at its deadline", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let control = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE idle (id int, name text)",
          5000,
        )
      let pid = backend_pid(connection)

      // Act
      let late =
        copy_from(connection, "COPY idle FROM STDIN", 300, send_after_idle(
          _,
          control,
          pid,
        ))
      stop(connection)
      stop(control)

      // Assert
      late
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(DeadlinePassed(cancelled: True))
      |> or_fail_with("Expected the end of the COPY at the deadline")
    }),
    it("stores no row of a slow produce function", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let control = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE idle (id int, name text)",
          5000,
        )
      let pid = backend_pid(connection)

      // Act
      let _late =
        copy_from(connection, "COPY idle FROM STDIN", 300, send_after_idle(
          _,
          control,
          pid,
        ))
      let count =
        run_script(connection, "SELECT count(*)::text FROM idle", 5000)
      stop(connection)
      stop(control)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row stored")
    }),
    it("cuts off a slow fold at its deadline", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let control = start_connection(first_driver_server.port)
      let pid = backend_pid(connection)

      // Act
      let late =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
          300,
          False,
          fn(waited, row) { read_until_idle(waited, row, control, pid) },
        )
      stop(connection)
      stop(control)

      // Assert
      late
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(DeadlinePassed(cancelled: True))
      |> or_fail_with("Expected DeadlinePassed(True)")
    }),
    it("stays usable after a slow fold passed its deadline", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let control = start_connection(first_driver_server.port)
      let pid = backend_pid(connection)

      // Act
      let _late =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
          300,
          False,
          fn(waited, row) { read_until_idle(waited, row, control, pid) },
        )
      let next = run_script(connection, "SELECT 8", 5000)
      stop(connection)
      stop(control)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected a usable connection")
    }),
    it("cuts off the reading of the rest after a failed fold", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let failed =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
          300,
          0,
          fail_at_first_row,
        )
      stop(connection)

      // Assert
      failed
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(DeadlinePassed(cancelled: True))
      |> or_fail_with("Expected the deadline to end the reading of the rest")
    }),
    it("stays usable after the deadline cut off the rest of a COPY", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let _failed =
        copy_to(
          connection,
          "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
          300,
          0,
          fail_at_first_row,
        )
      let next = run_script(connection, "SELECT 9", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected a usable connection")
    }),
    it("serves no other request of the caller while its COPY runs", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE waiting (id int, name text)",
          5000,
        )

      // Act
      let answers =
        copy_from(connection, "COPY waiting FROM STDIN", 5000, copy_inside(
          _,
          connection,
        ))
      stop(connection)

      // Assert
      answers
      |> should
      |> be_error
      |> extract_app_failure
      |> extract_first_of_pair
      |> be_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected the inner script to wait to its deadline")
    }),
    it("serves no other COPY of the caller while its COPY runs", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE waiting (id int, name text)",
          5000,
        )

      // Act
      let answers =
        copy_from(connection, "COPY waiting FROM STDIN", 5000, copy_inside(
          _,
          connection,
        ))
      stop(connection)

      // Assert
      answers
      |> should
      |> be_error
      |> extract_app_failure
      |> extract_second_of_pair
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(DeadlinePassed(cancelled: False))
      |> or_fail_with("Expected the inner COPY to wait to its deadline")
    }),
  ]
}

fn caller_tests() {
  [
    it("tells that the caller sent its rows before it ends", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE hung (id int, name text)",
          5000,
        )
      let caller = start_copy_caller(hang_after_rows(connection, _))

      // Act
      let told = caller_told(caller)
      process.kill(caller.pid)
      stop(connection)

      // Assert
      told
      |> should
      |> be_ok
      |> be_equal("sent")
      |> or_fail_with("Expected the caller to send its rows")
    }),
    it("abandons a COPY FROM STDIN when its caller ends", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE hung (id int, name text)",
          5000,
        )
      let caller = start_copy_caller(hang_after_rows(connection, _))

      // Act
      let _told = caller_told(caller)
      process.kill(caller.pid)
      let count =
        run_script(connection, "SELECT count(*)::text FROM hung", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected no row stored, and a usable connection")
    }),
    it("tells the caller the server's refusal of its row", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE hung (id int, name text)",
          5000,
        )
      let caller = start_copy_caller(hang_after_refusal(connection, _))

      // Act
      let told = caller_told(caller)
      process.kill(caller.pid)
      stop(connection)

      // Assert
      told
      |> should
      |> be_ok
      |> be_error
      |> extract_driver_error_code
      |> be_equal("22P02")
      |> or_fail_with("Expected the refusal")
    }),
    it("drops the end of a COPY when its caller ends before it took it", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE hung (id int, name text)",
          5000,
        )
      let caller = start_copy_caller(hang_after_refusal(connection, _))

      // Act
      let _told = caller_told(caller)
      process.kill(caller.pid)
      let count =
        run_script(connection, "SELECT count(*)::text FROM hung", 5000)
      stop(connection)

      // Assert
      count
      |> should
      |> be_ok
      |> extract_first
      |> extract_command_result
      |> extract_command_rows
      |> be_equal([[Text(<<"0">>)]])
      |> or_fail_with("Expected a usable connection after the refusal")
    }),
    it("tells that the caller holds the first row before it ends", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let caller = start_copy_caller(hang_at_first_row(connection, _))

      // Act
      let told = caller_told(caller)
      process.kill(caller.pid)
      stop(connection)

      // Assert
      told
      |> should
      |> be_ok
      |> be_equal("row")
      |> or_fail_with("Expected the caller to hold a row")
    }),
    it("reads the rest of a COPY TO STDOUT when its caller ends", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let caller = start_copy_caller(hang_at_first_row(connection, _))

      // Act
      let _told = caller_told(caller)
      process.kill(caller.pid)
      let next = run_script(connection, "SELECT 9", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected a usable connection")
    }),
    it("ignores the DOWN of a process that it does not watch", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      send_stray_down(pid_of(connection))
      let next = run_script(connection, "SELECT 10", 5000)
      stop(connection)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the connection to work")
    }),
    it("gives the count of a COPY whose app sent nothing", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE stale (id int, name text)",
          5000,
        )
      let senders = process.new_subject()

      // Act
      let stored =
        copy_from(connection, "COPY stale FROM STDIN", 5000, keep_sender(
          _,
          senders,
        ))
      stop(connection)

      // Assert
      stored
      |> should
      |> be_ok
      |> be_equal(0)
      |> or_fail_with("Expected no row stored")
    }),
    it("refuses a chunk after its COPY ended", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE stale (id int, name text)",
          5000,
        )
      let senders = process.new_subject()
      let _stored =
        copy_from(connection, "COPY stale FROM STDIN", 5000, keep_sender(
          _,
          senders,
        ))

      // Act
      let late = send_chunk(kept_sender(senders), <<"1\tone\n":utf8>>)
      stop(connection)

      // Assert
      late
      |> should
      |> be_error
      |> be_equal(CopyNotRunning)
      |> or_fail_with("Expected CopyNotRunning")
    }),
    it("gives the app the refusal of a row by a CHECK constraint", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE again (id int CHECK (id < 2), name text)",
          5000,
        )

      // Act
      let refused =
        copy_from(
          connection,
          "COPY again FROM STDIN",
          5000,
          send_twice_after_error,
        )
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_app_failure
      |> extract_first_of_pair
      |> extract_driver_error_code
      |> be_equal("23514")
      |> or_fail_with("Expected 23514 for the refused row")
    }),
    it("gives the error of the COPY again to a chunk after it", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let _created =
        run_script(
          connection,
          "CREATE TEMP TABLE again (id int CHECK (id < 2), name text)",
          5000,
        )

      // Act
      let refused =
        copy_from(
          connection,
          "COPY again FROM STDIN",
          5000,
          send_twice_after_error,
        )
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_app_failure
      |> extract_second_of_pair
      |> be_error
      |> extract_driver_error_code
      |> be_equal("23514")
      |> or_fail_with("Expected 23514 for the chunk after the error")
    }),
    it("refuses a COPY with a zero byte before it sends anything", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)

      // Act
      let refused =
        copy_from(
          connection,
          "COPY t FROM STDIN\u{0000}",
          5000,
          send_three_rows,
        )
      stop(connection)

      // Assert
      refused
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(InvalidRequest(ZeroByteInString("query")))
      |> or_fail_with("Expected InvalidRequest")
    }),
  ]
}

fn loss_tests() {
  [
    it("gives the loss of the connection in the middle of a COPY", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _created =
        run_script(
          proxied.connection,
          "CREATE TEMP TABLE lost (id int, name text)",
          5000,
        )

      // Act
      let lost =
        copy_from(
          proxied.connection,
          "COPY lost FROM STDIN",
          5000,
          send_across_close(_, proxied.proxy),
        )
      stop_proxied(proxied)

      // Assert
      lost
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> extract_loss_reason
      |> or_fail_with("Expected the loss of the connection")
    }),
    it("gives a violation in the middle of a COPY", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _created =
        run_script(
          proxied.connection,
          "CREATE TEMP TABLE broken (id int, name text)",
          5000,
        )

      // Act
      let broken =
        copy_from(
          proxied.connection,
          "COPY broken FROM STDIN",
          5000,
          send_across_violation(_, proxied.proxy),
        )
      stop_proxied(proxied)

      // Assert
      broken
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> extract_protocol_violation
      |> or_fail_with("Expected the violation")
    }),
    it("loses the connection when a chunk cannot be sent in time", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      answer_next_request(proxied.proxy, <<
        "1", 4:32, "2", 4:32, "G", 7:32, 0, 0:16,
      >>)
      let chunk = bit_array.from_string(repeat("x", 65_536))

      // Act
      let lost =
        copy_from(
          proxied.connection,
          "COPY t FROM STDIN",
          5000,
          send_until_error(_, chunk, 1_000_000),
        )
      stop_proxied(proxied)

      // Assert
      lost
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(ConnectionLost(SocketFailed(SendTimedOut)))
      |> or_fail_with("Expected the loss by a send timeout")
    }),
    it("gives the loss of the connection to the next row of a COPY", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)

      // Act
      let lost =
        copy_to(
          proxied.connection,
          "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
          5000,
          False,
          fn(closed, row) { close_at_first_row(closed, row, proxied.proxy) },
        )
      stop_proxied(proxied)

      // Assert
      lost
      |> should
      |> be_error
      |> extract_copy_driver_error
      |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
      |> or_fail_with("Expected the loss of the connection")
    }),
  ]
}

// The server's FATAL error is in the connection process's mailbox, and the
// socket was reset, when a request comes: its write fails.
fn write_failure_tests() {
  [
    it("gives the server's last error when a write fails after it", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let pid = pid_of(proxied.connection)
      suspend_connection(proxied.connection)
      let caller =
        start_caller(fn() { run_script(proxied.connection, "SELECT 1", 5000) })
      let _requested = wait_for_message(pid, ["request"], 1_000_000)
      inject(proxied.proxy, fatal_error_bytes())
      let _delivered = wait_for_message(pid, ["tcp"], 1_000_000)
      reset_client(proxied.proxy)
      let _reset = wait_for_reset(pid, 1_000_000)

      // Act
      resume_connection(proxied.connection)
      let answer = caller_answer(caller)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> extract_ending_report
      |> extract_report_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the FATAL 57P01, not the failed write")
    }),
    it("gives the server's last error when a chunk fails after it", fn() {
      // Arrange
      let proxied = start_proxied(first_driver_server, 60_000)
      let _created =
        run_script(
          proxied.connection,
          "CREATE TEMP TABLE gated (id int, name text)",
          5000,
        )
      let pid = pid_of(proxied.connection)
      let started = process.new_subject()
      let caller =
        start_caller(fn() {
          copy_from(
            proxied.connection,
            "COPY gated FROM STDIN",
            5000,
            send_after_go(_, started),
          )
        })
      let go = await_go(started)
      suspend_connection(proxied.connection)
      process.send(go, Nil)
      let _chunk_sent = wait_for_message(pid, ["copy_call"], 1_000_000)
      inject(proxied.proxy, fatal_error_bytes())
      let _delivered = wait_for_message(pid, ["tcp"], 1_000_000)
      reset_client(proxied.proxy)
      let _reset = wait_for_reset(pid, 1_000_000)

      // Act
      resume_connection(proxied.connection)
      let answer = caller_answer(caller)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> extract_copy_driver_error
      |> extract_ending_report
      |> extract_report_code
      |> be_equal("57P01")
      |> or_fail_with("Expected the FATAL 57P01, not the failed chunk")
    }),
    it("gives the failure of a TLS write after a reset", fn() {
      // Arrange
      let proxied =
        start_proxied_with_tls(first_driver_server, 60_000, verify_full())
      let pid = pid_of(proxied.connection)
      suspend_connection(proxied.connection)
      let caller =
        start_caller(fn() { run_script(proxied.connection, "SELECT 1", 5000) })
      let _requested = wait_for_message(pid, ["request"], 1_000_000)
      reset_client(proxied.proxy)
      let _reset = wait_for_message(pid, ["ssl_closed", "ssl_error"], 1_000_000)

      // Act
      resume_connection(proxied.connection)
      let answer = caller_answer(caller)
      stop_proxied(proxied)

      // Assert
      answer
      |> should
      |> be_ok
      |> be_error
      |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
      |> or_fail_with("Expected the loss by the closed socket")
    }),
  ]
}
