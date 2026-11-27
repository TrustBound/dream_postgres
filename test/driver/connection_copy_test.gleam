//// Tests for COPY in `dream_postgres/driver/connection`: `copy_from` and
//// `copy_to` on the driver servers of PostgreSQL 16 to 19. The produce
//// functions, folds and COPY setup hooks are in `fixtures/copy_callbacks`.
////
//// Each describe has one kind of setup: a connection for each test, a
//// connection with a control connection for each test, a proxied
//// connection for each test, or one act that several tests check. The
//// setups and teardowns start and stop every connection, proxy and
//// caller.

import dream_postgres/driver/connection.{
  type ChunkError, type Connection, type CopyError, type Outcome,
  type ScriptError, AppFailed, ChunkCopyNotRunning, ChunkFailed, ConnectionLost,
  ConnectionProcessDown, CopyFailed, CopyNotStarted, CopyUnencodable,
  DeadlinePassed, Outcome, ScriptRequestFailed, ServerStoppedReading,
  SocketFailed, copy_from, copy_to, run_script, send_chunk, transaction_status,
}
import dream_postgres/driver/message.{ZeroByteInString}
import dream_postgres/driver/transport.{SocketClosed}
import dream_postgres/internal/cell.{
  CommandResult, Idle, InFailedTransaction, Text,
}
import dream_test/context.{type Context}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{
  type ContextNode, after_each, before_each, describe, group, it,
}
import driver/proxy.{answer_next_request, inject, reset_client}
import driver/server_connection.{
  type ActOutcome, type ControlledConnection, type ProxiedConnection, act_setup,
  caller_answer, connection_act_setup, connection_setup, controlled_act_setup,
  controlled_setup, fatal_error_bytes, pid_of, proxied_setup, resume_connection,
  run_control_script, run_controlled_setup_script, run_proxied_setup_script,
  run_setup_script, send_stray_down, start_caller, start_connection,
  start_test_connection, start_test_controlled, start_test_proxied,
  start_test_proxied_with_tls, stop_after_error, stop_connection,
  stop_controlled, stop_proxied, suspend_connection, wait_for_message,
  wait_for_reset,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import fixtures/copy_callbacks.{
  type CopyCaller, MemoryPeak, append_row, await_go, binary_copy, caller_told,
  close_at_first_row, collect_row, collect_size, copy_in_setup, copy_inside,
  copy_rows_in, count_and_sample, fail_at_first_row, fail_at_second_row,
  failing_copy_in_setup, failing_copy_out_setup, hang_after_refusal,
  hang_after_rows, hang_at_first_row, keep_sender, kept_sender,
  load_chunks_sampling, read_until_idle, send_across_close,
  send_across_violation, send_after_end, send_after_go, send_after_idle,
  send_bad_row, send_binary, send_csv, send_then_fail, send_three_rows,
  send_twice_after_error, send_until_error, send_until_refused,
  start_copy_caller, stop_then_send,
}
import fixtures/driver_tls.{verify_full}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int.{to_string}
import gleam/list.{map, try_each}
import gleam/option.{None, Some}
import gleam/result.{map_error, try}
import gleam/string.{repeat}
import matchers/extract_app_failure.{extract_app_failure}
import matchers/extract_chunk_refusal_code.{extract_chunk_refusal_code}
import matchers/extract_command_result.{extract_command_result}
import matchers/extract_command_rows.{extract_command_rows}
import matchers/extract_copy_failure.{extract_copy_failure}
import matchers/extract_copy_refusal_code.{extract_copy_refusal_code}
import matchers/extract_ending_report.{extract_ending_report}
import matchers/extract_first.{extract_first}
import matchers/extract_first_of_pair.{extract_first_of_pair}
import matchers/extract_loss_reason.{extract_loss_reason}
import matchers/extract_outcome_tags.{extract_outcome_tags}
import matchers/extract_protocol_violation.{extract_protocol_violation}
import matchers/extract_report_code.{extract_report_code}
import matchers/extract_sampled_peak.{extract_sampled_peak}
import matchers/extract_script_request_failure.{extract_script_request_failure}
import matchers/extract_second_of_pair.{extract_second_of_pair}
import matchers/within_memory.{within_memory}

/// The bound of the memory of each process during a COPY of 1,000,000
/// rows, in bytes: far less than the 16,000,000 bytes of its data.
const memory_bound = 2_000_000

/// The tests of COPY.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/connection COPY", [
    connection_tests(),
    controlled_tests(),
    proxied_tests(),
    late_copy_tests(),
    slow_produce_tests(),
    slow_fold_tests(),
    cut_off_fold_tests(),
    copy_inside_tests(),
    copy_stopping_tests(),
    rows_caller_tests(),
    refusal_caller_tests(),
    row_caller_tests(),
  ])
}

// A connection for each test --------------------------------------------------

fn connection_tests() -> TestSuite {
  describe(
    "with a connection of its own",
    connection_setup(first_driver_server),
    [
      after_each(stop_connection),
      group("on each server", map(driver_servers(), server_tests)),
      group("on the first server", [
        before_each(start_test_connection(first_driver_server)),
        group("memory", memory_tests()),
        group("callers", caller_tests()),
      ]),
    ],
  )
}

fn server_tests(server: Server) -> ContextNode(Connection) {
  group("PostgreSQL " <> to_string(server.version), [
    before_each(start_test_connection(server)),
    group("storing", store_tests()),
    group("both ways", both_ways_tests()),
    group("transactions", transaction_tests()),
    group("refusals", refusal_tests()),
    group("app failures", app_failure_tests()),
    group("no COPY", no_copy_tests()),
  ])
}

fn store_tests() -> List(ContextNode(Connection)) {
  [
    group("a COPY FROM STDIN", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE copied (id int, name text)",
      )),
      it(
        "stores the rows of a COPY FROM STDIN and gives their count",
        fn(connection) {
          // Act
          let stored =
            copy_from(
              connection,
              connection.statement("COPY copied FROM STDIN"),
              5000,
              send_three_rows,
            )

          // Assert
          stored
          |> should
          |> be_ok
          |> be_equal(3)
          |> or_fail_with("Expected three rows stored")
        },
      ),
      group("after it", [
        before_each(copy_in_setup("COPY copied FROM STDIN", send_three_rows)),
        it("stores the rows that a COPY FROM STDIN sent", fn(connection) {
          // Act
          let rows =
            run_script(
              connection,
              connection.statement(
                "SELECT id::text, name FROM copied ORDER BY id",
              ),
              5000,
            )

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
      ]),
    ]),
    it("reads the rows of a COPY TO STDOUT one at a time", fn(connection) {
      // Act
      let rows =
        copy_to(
          connection,
          connection.statement(
            "COPY (SELECT n, 'r' || n FROM generate_series(1, 3) n) TO STDOUT",
          ),
          5000,
          [],
          collect_row,
        )

      // Assert
      rows
      |> should
      |> be_ok
      |> be_equal([<<"3\tr3\n":utf8>>, <<"2\tr2\n":utf8>>, <<"1\tr1\n":utf8>>])
      |> or_fail_with("Expected each row as its own bytes")
    }),
    it("gives a row that is longer than one read of the socket", fn(connection) {
      // Act
      let sizes =
        copy_to(
          connection,
          connection.statement("COPY (SELECT repeat('x', 4000000)) TO STDOUT"),
          5000,
          [],
          collect_size,
        )

      // Assert
      sizes
      |> should
      |> be_ok
      |> be_equal([4_000_001])
      |> or_fail_with("Expected one row of 4,000,001 bytes")
    }),
  ]
}

fn both_ways_tests() -> List(ContextNode(Connection)) {
  [
    group("a csv COPY", [
      before_each(run_setup_script("CREATE TEMP TABLE csv (id int, name text)")),
      it("stores the rows of a csv COPY", fn(connection) {
        // Act
        let stored =
          copy_from(
            connection,
            connection.statement("COPY csv FROM STDIN (FORMAT csv)"),
            5000,
            send_csv,
          )

        // Assert
        stored
        |> should
        |> be_ok
        |> be_equal(2)
        |> or_fail_with("Expected two csv rows stored")
      }),
      group("after it", [
        before_each(copy_in_setup("COPY csv FROM STDIN (FORMAT csv)", send_csv)),
        it("moves the bytes of a csv COPY both ways", fn(connection) {
          // Act
          let rows =
            copy_to(
              connection,
              connection.statement("COPY csv TO STDOUT (FORMAT csv)"),
              5000,
              [],
              collect_row,
            )

          // Assert
          rows
          |> should
          |> be_ok
          |> be_equal([<<"2,\"b,c\"\n":utf8>>, <<"1,a\n":utf8>>])
          |> or_fail_with("Expected the csv rows back")
        }),
      ]),
    ]),
    group("a binary COPY", [
      before_each(run_setup_script("CREATE TEMP TABLE b (n int4)")),
      it("stores the row of a binary COPY", fn(connection) {
        // Act
        let stored =
          copy_from(
            connection,
            connection.statement("COPY b FROM STDIN (FORMAT binary)"),
            5000,
            send_binary,
          )

        // Assert
        stored
        |> should
        |> be_ok
        |> be_equal(1)
        |> or_fail_with("Expected one binary row stored")
      }),
      group("after it", [
        before_each(copy_in_setup(
          "COPY b FROM STDIN (FORMAT binary)",
          send_binary,
        )),
        it("moves the bytes of a binary COPY both ways", fn(connection) {
          // Act
          let data =
            copy_to(
              connection,
              connection.statement("COPY b TO STDOUT (FORMAT binary)"),
              5000,
              <<>>,
              append_row,
            )

          // Assert
          data
          |> should
          |> be_ok
          |> be_equal(binary_copy())
          |> or_fail_with("Expected the same binary COPY data back")
        }),
      ]),
    ]),
  ]
}

fn transaction_tests() -> List(ContextNode(Connection)) {
  [
    group("a COPY in a transaction", [
      before_each(run_setup_script("CREATE TEMP TABLE kept (id int, name text)")),
      before_each(run_setup_script("BEGIN")),
      it(
        "gives the count of a COPY in a transaction that rolls back",
        fn(connection) {
          // Act
          let rolled_back = {
            let copied =
              copy_from(
                connection,
                connection.statement("COPY kept FROM STDIN"),
                5000,
                send_three_rows,
              )
            use Nil <- try(run_control_script(connection, "ROLLBACK"))
            Ok(copied)
          }

          // Assert
          rolled_back
          |> should
          |> be_ok
          |> be_ok
          |> be_equal(3)
          |> or_fail_with("Expected three rows copied before the ROLLBACK")
        },
      ),
      group("rolled back", [
        before_each(copy_in_setup("COPY kept FROM STDIN", send_three_rows)),
        before_each(run_setup_script("ROLLBACK")),
        it("commits and rolls back a COPY with its transaction", fn(connection) {
          // Act
          let count =
            run_script(
              connection,
              connection.statement("SELECT count(*)::text FROM kept"),
              5000,
            )

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
        group("and a new transaction", committed_tests()),
      ]),
    ]),
    group("a COPY that fails its transaction", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE failing (id int, name text)",
      )),
      before_each(run_setup_script("BEGIN")),
      it("gives the app's failure of a COPY in a transaction", fn(connection) {
        // Act
        let failed =
          copy_from(
            connection,
            connection.statement("COPY failing FROM STDIN"),
            5000,
            send_then_fail,
          )

        // Assert
        failed
        |> should
        |> be_error
        |> extract_app_failure
        |> be_equal("stopped")
        |> or_fail_with("Expected the app's failure")
      }),
      group("after it", [
        before_each(failing_copy_in_setup(
          "COPY failing FROM STDIN",
          send_then_fail,
        )),
        it(
          "fails the transaction with a COPY that the app abandoned",
          fn(connection) {
            transaction_status(connection)
            |> should
            |> be_ok
            |> be_equal(InFailedTransaction)
            |> or_fail_with("Expected a failed transaction")
          },
        ),
      ]),
    ]),
  ]
}

fn committed_tests() -> List(ContextNode(Connection)) {
  [
    before_each(run_setup_script("BEGIN")),
    it(
      "gives the count of a COPY in a transaction that commits",
      fn(connection) {
        // Act
        let committed = {
          let copied =
            copy_from(
              connection,
              connection.statement("COPY kept FROM STDIN"),
              5000,
              send_three_rows,
            )
          use Nil <- try(run_control_script(connection, "COMMIT"))
          Ok(copied)
        }

        // Assert
        committed
        |> should
        |> be_ok
        |> be_ok
        |> be_equal(3)
        |> or_fail_with("Expected three rows copied before the COMMIT")
      },
    ),
    group("committed", [
      before_each(copy_in_setup("COPY kept FROM STDIN", send_three_rows)),
      before_each(run_setup_script("COMMIT")),
      it(
        "keeps the rows of a COPY in a transaction that commits",
        fn(connection) {
          // Act
          let count =
            run_script(
              connection,
              connection.statement("SELECT count(*)::text FROM kept"),
              5000,
            )

          // Assert
          count
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"3">>)]])
          |> or_fail_with("Expected three rows after COMMIT")
        },
      ),
    ]),
  ]
}

fn refusal_tests() -> List(ContextNode(Connection)) {
  [
    group("a COPY that the server refuses in the middle", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE refused (id int, name text)",
      )),
      it(
        "ends the COPY at a server error in the middle and stays usable",
        fn(connection) {
          // Act
          let refused =
            copy_from(
              connection,
              connection.statement("COPY refused FROM STDIN"),
              5000,
              send_until_refused,
            )

          // Assert
          refused
          |> should
          |> be_error
          |> extract_app_failure
          |> extract_chunk_refusal_code
          |> be_equal("22P02")
          |> or_fail_with("Expected the app's failure with 22P02")
        },
      ),
      group("after it", [
        before_each(failing_copy_in_setup(
          "COPY refused FROM STDIN",
          send_until_refused,
        )),
        it(
          "stores no row of a COPY that the server refused in the middle",
          fn(connection) {
            // Act
            let count =
              run_script(
                connection,
                connection.statement("SELECT count(*)::text FROM refused"),
                5000,
              )

            // Assert
            count
            |> should
            |> be_ok
            |> extract_first
            |> extract_command_result
            |> extract_command_rows
            |> be_equal([[Text(<<"0">>)]])
            |> or_fail_with("Expected no row")
          },
        ),
      ]),
    ]),
    group("a COPY whose data the server refuses", [
      before_each(run_setup_script("CREATE TEMP TABLE bad (id int, name text)")),
      it(
        "gives the server's error when the app sent all its data",
        fn(connection) {
          // Act
          let refused =
            copy_from(
              connection,
              connection.statement("COPY bad FROM STDIN"),
              5000,
              send_bad_row,
            )

          // Assert
          refused
          |> should
          |> be_error
          |> extract_copy_refusal_code
          |> be_equal("22P02")
          |> or_fail_with("Expected the server's 22P02")
        },
      ),
      group("after it", [
        before_each(failing_copy_in_setup("COPY bad FROM STDIN", send_bad_row)),
        it(
          "is idle after the server's error for the app's data",
          fn(connection) {
            transaction_status(connection)
            |> should
            |> be_ok
            |> be_equal(Idle)
            |> or_fail_with("Expected Idle after the server's error")
          },
        ),
      ]),
    ]),
    it(
      "gives the server's error for a COPY of a table that does not exist",
      fn(connection) {
        // Act
        let refused =
          copy_from(
            connection,
            connection.statement("COPY no_such_table FROM STDIN"),
            5000,
            send_three_rows,
          )

        // Assert
        refused
        |> should
        |> be_error
        |> extract_copy_refusal_code
        |> be_equal("42P01")
        |> or_fail_with("Expected 42P01")
      },
    ),
  ]
}

fn app_failure_tests() -> List(ContextNode(Connection)) {
  [
    group("a COPY that the app abandons", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE abandoned (id int, name text)",
      )),
      it("abandons the COPY with CopyFail when the app fails", fn(connection) {
        // Act
        let failed =
          copy_from(
            connection,
            connection.statement("COPY abandoned FROM STDIN"),
            5000,
            send_then_fail,
          )

        // Assert
        failed
        |> should
        |> be_error
        |> extract_app_failure
        |> be_equal("stopped")
        |> or_fail_with("Expected the app's failure")
      }),
      group("after it", [
        before_each(failing_copy_in_setup(
          "COPY abandoned FROM STDIN",
          send_then_fail,
        )),
        it("stores no row of a COPY that the app abandoned", fn(connection) {
          // Act
          let count =
            run_script(
              connection,
              connection.statement("SELECT count(*)::text FROM abandoned"),
              5000,
            )

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
      ]),
    ]),
    it("gives the app's failure of a fold of a COPY TO STDOUT", fn(connection) {
      // Act
      let failed =
        copy_to(
          connection,
          connection.statement(
            "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
          ),
          5000,
          0,
          fail_at_second_row,
        )

      // Assert
      failed
      |> should
      |> be_error
      |> extract_app_failure
      |> be_equal("enough")
      |> or_fail_with("Expected the app's failure")
    }),
    group("after a fold that failed", [
      before_each(failing_copy_out_setup(
        "COPY (SELECT n FROM generate_series(1, 100000) n) TO STDOUT",
        0,
        fail_at_second_row,
      )),
      it(
        "reads the rest of a COPY TO STDOUT when the app fails",
        fn(connection) {
          // Act
          let next =
            run_script(connection, connection.statement("SELECT 7"), 5000)

          // Assert
          next
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected a usable connection")
        },
      ),
    ]),
  ]
}

fn no_copy_tests() -> List(ContextNode(Connection)) {
  [
    it("gives what ran in place of the COPY", fn(connection) {
      // Act
      let select =
        copy_from(
          connection,
          connection.statement("SELECT 1"),
          5000,
          send_three_rows,
        )

      // Assert
      select
      |> should
      |> be_error
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
    group("a table that no COPY reaches", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE other (id int, name text)",
      )),
      it(
        "gives the COPY TO STDOUT that copy_from ran in place of a COPY",
        fn(connection) {
          // Act
          let out =
            copy_from(
              connection,
              connection.statement("COPY other TO STDOUT"),
              5000,
              send_three_rows,
            )

          // Assert
          out
          |> should
          |> be_error
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
        },
      ),
      it(
        "gives no outcome for a COPY FROM STDIN that copy_to refused",
        fn(connection) {
          // Act
          let into =
            copy_to(
              connection,
              connection.statement("COPY other FROM STDIN"),
              5000,
              [],
              collect_row,
            )

          // Assert
          into
          |> should
          |> be_error
          |> be_equal(CopyNotStarted(None))
          |> or_fail_with("Expected no outcome for the refused COPY")
        },
      ),
      group("after COPYs that did not start", [
        before_each(failing_copy_in_setup("SELECT 1", send_three_rows)),
        before_each(failing_copy_in_setup(
          "COPY other TO STDOUT",
          send_three_rows,
        )),
        before_each(failing_copy_out_setup(
          "COPY other FROM STDIN",
          [],
          collect_row,
        )),
        it("stores no row of a COPY that did not start", fn(connection) {
          // Act
          let count =
            run_script(
              connection,
              connection.statement("SELECT count(*)::text FROM other"),
              5000,
            )

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
      ]),
    ]),
  ]
}

fn memory_tests() -> List(ContextNode(Connection)) {
  [
    group("a load", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE loaded (n int, name text)",
      )),
      it("keeps the memory flat while it loads 1,000,000 rows", fn(connection) {
        // Arrange
        let peaks = process.new_subject()
        let connection_pid = pid_of(connection)

        // Act
        let stored =
          copy_from(
            connection,
            connection.statement("COPY loaded FROM STDIN"),
            5000,
            load_chunks_sampling(_, connection_pid, peaks),
          )

        // Assert
        stored
        |> should
        |> be_ok
        |> extract_sampled_peak(from: peaks)
        |> within_memory(memory_bound, 0)
        |> be_equal(1_000_000)
        |> or_fail_with("Expected 1,000,000 rows stored")
      }),
    ]),
    it("keeps the memory flat while it reads 1,000,000 rows", fn(connection) {
      // Arrange
      let connection_pid = pid_of(connection)

      // Act
      let counted =
        copy_to(
          connection,
          connection.statement(
            "COPY (SELECT n, 'some text' FROM generate_series(1, 1000000) n) TO STDOUT",
          ),
          60_000,
          #(0, MemoryPeak(0, 0, 0)),
          fn(sampled, row) { count_and_sample(sampled, row, connection_pid) },
        )

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

fn caller_tests() -> List(ContextNode(Connection)) {
  [
    it("ignores the DOWN of a process that it does not watch", fn(connection) {
      // Act
      send_stray_down(pid_of(connection))
      let next = run_script(connection, connection.statement("SELECT 10"), 5000)

      // Assert
      next
      |> should
      |> be_ok
      |> extract_outcome_tags
      |> be_equal(["SELECT 1"])
      |> or_fail_with("Expected the connection to work")
    }),
    group("a COPY whose app keeps its sender", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE stale (id int, name text)",
      )),
      it("gives the count of a COPY whose app sent nothing", fn(connection) {
        // Arrange
        let senders = process.new_subject()

        // Act
        let stored =
          copy_from(
            connection,
            connection.statement("COPY stale FROM STDIN"),
            5000,
            keep_sender(_, senders),
          )

        // Assert
        stored
        |> should
        |> be_ok
        |> be_equal(0)
        |> or_fail_with("Expected no row stored")
      }),
      it("refuses a chunk after its COPY ended", fn(connection) {
        // Act
        let late = {
          let senders = process.new_subject()
          use _stored <- try(
            copy_rows_in(connection, "COPY stale FROM STDIN", keep_sender(
              _,
              senders,
            )),
          )
          use sender <- try(kept_sender(senders))
          Ok(send_chunk(sender, <<"1\tone\n":utf8>>))
        }

        // Assert
        late
        |> should
        |> be_ok
        |> be_error
        |> be_equal(ChunkCopyNotRunning)
        |> or_fail_with("Expected ChunkCopyNotRunning")
      }),
    ]),
    group("a COPY that a CHECK constraint refuses", [
      before_each(run_setup_script(
        "CREATE TEMP TABLE again (id int CHECK (id < 2), name text)",
      )),
      it(
        "gives the app the refusal of a row by a CHECK constraint",
        fn(connection) {
          // Act
          let refused =
            copy_from(
              connection,
              connection.statement("COPY again FROM STDIN"),
              5000,
              send_twice_after_error,
            )

          // Assert
          refused
          |> should
          |> be_error
          |> extract_app_failure
          |> extract_first_of_pair
          |> extract_chunk_refusal_code
          |> be_equal("23514")
          |> or_fail_with("Expected 23514 for the refused row")
        },
      ),
      it(
        "gives the error of the COPY again to a chunk after it",
        fn(connection) {
          // Act
          let refused =
            copy_from(
              connection,
              connection.statement("COPY again FROM STDIN"),
              5000,
              send_twice_after_error,
            )

          // Assert
          refused
          |> should
          |> be_error
          |> extract_app_failure
          |> extract_second_of_pair
          |> be_error
          |> extract_chunk_refusal_code
          |> be_equal("23514")
          |> or_fail_with("Expected 23514 for the chunk after the error")
        },
      ),
    ]),
    it(
      "refuses a COPY with a zero byte before it sends anything",
      fn(connection) {
        // Act
        let refused =
          copy_from(
            connection,
            connection.statement("COPY t FROM STDIN\u{0000}"),
            5000,
            send_three_rows,
          )

        // Assert
        refused
        |> should
        |> be_error
        |> be_equal(CopyUnencodable(ZeroByteInString("query")))
        |> or_fail_with("Expected CopyUnencodable")
      },
    ),
  ]
}

// A connection with a control connection for each test -----------------------

fn controlled_tests() -> TestSuite {
  describe("with a control connection", controlled_setup(first_driver_server), [
    after_each(stop_controlled),
    group("on each server", map(driver_servers(), session_end_tests)),
  ])
}

fn session_end_tests(server: Server) -> ContextNode(ControlledConnection) {
  group("PostgreSQL " <> to_string(server.version), [
    before_each(start_test_controlled(server)),
    before_each(run_controlled_setup_script(
      "CREATE TEMP TABLE ended (id int, name text)",
    )),
    it(
      "gives the end of the session in the middle of a COPY",
      fn(controlled: ControlledConnection) {
        // Act
        let ended =
          copy_from(
            controlled.connection,
            connection.statement("COPY ended FROM STDIN"),
            5000,
            send_after_end(_, controlled.control, controlled.backend_pid),
          )

        // Assert
        ended
        |> should
        |> be_error
        |> extract_copy_failure
        |> extract_ending_report
        |> extract_report_code
        |> be_equal("57P01")
        |> or_fail_with("Expected the server's 57P01")
      },
    ),
  ])
}

// A proxied connection for each test ------------------------------------------

fn proxied_tests() -> TestSuite {
  describe("through a proxy", proxied_setup(first_driver_server, 60_000), [
    after_each(stop_proxied),
    group("losses", loss_tests()),
    // The server's FATAL error is in the connection process's mailbox, and
    // the socket was reset, when a request comes: its write fails.
    group("writes after the server's last error", write_failure_tests()),
    group("writes after a reset of a TLS connection", [
      before_each(start_test_proxied_with_tls(
        first_driver_server,
        60_000,
        verify_full(),
      )),
      it(
        "gives the failure of a TLS write after a reset",
        fn(proxied: ProxiedConnection) {
          // Act
          let answer = {
            let pid = pid_of(proxied.connection)
            suspend_connection(proxied.connection)
            let caller =
              start_caller(fn() {
                run_script(
                  proxied.connection,
                  connection.statement("SELECT 1"),
                  5000,
                )
              })
            use _requested <- try(wait_for_message(pid, ["request"], 1_000_000))
            reset_client(proxied.proxy)
            use _reset <- try(wait_for_message(
              pid,
              ["ssl_closed", "ssl_error"],
              1_000_000,
            ))
            resume_connection(proxied.connection)
            caller_answer(caller)
          }

          // Assert
          answer
          |> should
          |> be_ok
          |> be_error
          |> be_equal(
            ScriptRequestFailed(ConnectionLost(SocketFailed(SocketClosed))),
          )
          |> or_fail_with("Expected the loss by the closed socket")
        },
      ),
    ]),
  ])
}

fn loss_tests() -> List(ContextNode(ProxiedConnection)) {
  [
    before_each(start_test_proxied(first_driver_server, 60_000)),
    group("a COPY whose socket closes", [
      before_each(run_proxied_setup_script(
        "CREATE TEMP TABLE lost (id int, name text)",
      )),
      it(
        "gives the loss of the connection in the middle of a COPY",
        fn(proxied: ProxiedConnection) {
          copy_from(
            proxied.connection,
            connection.statement("COPY lost FROM STDIN"),
            5000,
            send_across_close(_, proxied.proxy),
          )
          |> should
          |> be_error
          |> extract_copy_failure
          |> extract_loss_reason
          |> or_fail_with("Expected the loss of the connection")
        },
      ),
    ]),
    group("a COPY that gets a message out of place", [
      before_each(run_proxied_setup_script(
        "CREATE TEMP TABLE broken (id int, name text)",
      )),
      it(
        "gives a violation in the middle of a COPY",
        fn(proxied: ProxiedConnection) {
          copy_from(
            proxied.connection,
            connection.statement("COPY broken FROM STDIN"),
            5000,
            send_across_violation(_, proxied.proxy),
          )
          |> should
          |> be_error
          |> extract_copy_failure
          |> extract_protocol_violation
          |> or_fail_with("Expected the violation")
        },
      ),
    ]),
    it(
      "refuses a chunk after the server ended its COPY",
      fn(proxied: ProxiedConnection) {
        // Arrange
        answer_next_request(proxied.proxy, <<
          "1", 4:32, "2", 4:32, "G", 7:32, 0, 0:16, "C", 11:32, "COPY 0":utf8, 0,
          "Z", 5:32, "I":utf8,
        >>)

        // Act
        let refused =
          copy_from(
            proxied.connection,
            connection.statement("COPY ended FROM STDIN"),
            5000,
            send_bad_row,
          )

        // Assert
        refused
        |> should
        |> be_error
        |> be_equal(AppFailed(ChunkCopyNotRunning))
        |> or_fail_with("Expected the chunk to meet the end of the COPY")
      },
    ),
    it(
      "loses the connection when a chunk cannot be sent in time",
      fn(proxied: ProxiedConnection) {
        // Arrange
        answer_next_request(proxied.proxy, <<
          "1", 4:32, "2", 4:32, "G", 7:32, 0, 0:16,
        >>)
        let chunk = bit_array.from_string(repeat("x", 65_536))

        // Act
        let lost =
          copy_from(
            proxied.connection,
            connection.statement("COPY t FROM STDIN"),
            5000,
            send_until_error(_, chunk, 1_000_000),
          )

        // Assert
        lost
        |> should
        |> be_error
        |> extract_copy_failure
        |> be_equal(ConnectionLost(ServerStoppedReading))
        |> or_fail_with("Expected the loss by a send timeout")
      },
    ),
    it(
      "gives the loss of the connection to the next row of a COPY",
      fn(proxied: ProxiedConnection) {
        copy_to(
          proxied.connection,
          connection.statement(
            "COPY (SELECT n FROM generate_series(1, 1000000) n) TO STDOUT",
          ),
          5000,
          False,
          fn(closed, row) { close_at_first_row(closed, row, proxied.proxy) },
        )
        |> should
        |> be_error
        |> extract_copy_failure
        |> be_equal(ConnectionLost(SocketFailed(SocketClosed)))
        |> or_fail_with("Expected the loss of the connection")
      },
    ),
  ]
}

fn write_failure_tests() -> List(ContextNode(ProxiedConnection)) {
  [
    before_each(start_test_proxied(first_driver_server, 60_000)),
    it(
      "gives the server's last error when a write fails after it",
      fn(proxied: ProxiedConnection) {
        // Act
        let answer = {
          let pid = pid_of(proxied.connection)
          suspend_connection(proxied.connection)
          let caller =
            start_caller(fn() {
              run_script(
                proxied.connection,
                connection.statement("SELECT 1"),
                5000,
              )
            })
          use _requested <- try(wait_for_message(pid, ["request"], 1_000_000))
          inject(proxied.proxy, fatal_error_bytes())
          use _delivered <- try(wait_for_message(pid, ["tcp"], 1_000_000))
          reset_client(proxied.proxy)
          use _reset <- try(wait_for_reset(pid, 1_000_000))
          resume_connection(proxied.connection)
          caller_answer(caller)
        }

        // Assert
        answer
        |> should
        |> be_ok
        |> be_error
        |> extract_script_request_failure
        |> extract_ending_report
        |> extract_report_code
        |> be_equal("57P01")
        |> or_fail_with("Expected the FATAL 57P01, not the failed write")
      },
    ),
    group("a COPY that waits for go", [
      before_each(run_proxied_setup_script(
        "CREATE TEMP TABLE gated (id int, name text)",
      )),
      it(
        "gives the server's last error when a chunk fails after it",
        fn(proxied: ProxiedConnection) {
          // Act
          let answer = {
            let pid = pid_of(proxied.connection)
            let started = process.new_subject()
            let caller =
              start_caller(fn() {
                copy_from(
                  proxied.connection,
                  connection.statement("COPY gated FROM STDIN"),
                  5000,
                  send_after_go(_, started),
                )
              })
            use go <- try(await_go(started))
            suspend_connection(proxied.connection)
            process.send(go, Nil)
            use _chunk_sent <- try(wait_for_message(
              pid,
              ["copy_call"],
              1_000_000,
            ))
            inject(proxied.proxy, fatal_error_bytes())
            use _delivered <- try(wait_for_message(pid, ["tcp"], 1_000_000))
            reset_client(proxied.proxy)
            use _reset <- try(wait_for_reset(pid, 1_000_000))
            resume_connection(proxied.connection)
            caller_answer(caller)
          }

          // Assert
          answer
          |> should
          |> be_ok
          |> be_error
          |> extract_copy_failure
          |> extract_ending_report
          |> extract_report_code
          |> be_equal("57P01")
          |> or_fail_with("Expected the FATAL 57P01, not the failed chunk")
        },
      ),
    ]),
  ]
}

// Deadlines: one act for two tests --------------------------------------------

/// What a COPY gave, and what the next request on its connection gave.
type CopyAndNext(value, error) {
  CopyAndNext(
    copied: Result(value, error),
    next: Result(List(Outcome), ScriptError),
  )
}

type DirectCopy(value, error) =
  ActOutcome(Connection, CopyAndNext(value, error))

type ControlledCopy(value, error) =
  ActOutcome(ControlledConnection, CopyAndNext(value, error))

/// A COPY FROM STDIN whose app sends until the deadline of 300
/// milliseconds ends it, and the count of its table after it.
fn copy_past_deadline(
  connection: Connection,
) -> Result(CopyAndNext(Int, CopyError(ChunkError)), String) {
  use Nil <- try(run_control_script(
    connection,
    "CREATE TEMP TABLE late (id int, name text)",
  ))
  let chunk = bit_array.from_string(repeat("1\tone\n", 1000))
  let copied =
    copy_from(
      connection,
      connection.statement("COPY late FROM STDIN"),
      300,
      send_until_error(_, chunk, 1_000_000),
    )
  let next =
    run_script(
      connection,
      connection.statement("SELECT count(*)::text FROM late"),
      5000,
    )
  Ok(CopyAndNext(copied:, next:))
}

fn late_copy_tests() -> TestSuite {
  describe(
    "a COPY FROM STDIN past its deadline",
    connection_act_setup(first_driver_server, copy_past_deadline),
    [
      it(
        "ends a COPY FROM STDIN at its deadline while the app sends",
        fn(shared: DirectCopy(Int, CopyError(ChunkError))) {
          shared.outcome.copied
          |> should
          |> be_error
          |> extract_copy_failure
          |> be_equal(DeadlinePassed(cancelled: True))
          |> or_fail_with("Expected DeadlinePassed(True)")
        },
      ),
      it(
        "stores no row of a COPY FROM STDIN that passed its deadline",
        fn(shared: DirectCopy(Int, CopyError(ChunkError))) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"0">>)]])
          |> or_fail_with("Expected no row stored")
        },
      ),
    ],
  )
}

/// A COPY FROM STDIN whose app sends nothing until its backend is idle,
/// past the deadline of 300 milliseconds, and the count of its table after
/// it.
fn copy_slowly(
  controlled: ControlledConnection,
) -> Result(CopyAndNext(Int, CopyError(ChunkError)), String) {
  use Nil <- try(run_control_script(
    controlled.connection,
    "CREATE TEMP TABLE idle (id int, name text)",
  ))
  let copied =
    copy_from(
      controlled.connection,
      connection.statement("COPY idle FROM STDIN"),
      300,
      send_after_idle(_, controlled.control, controlled.backend_pid),
    )
  let next =
    run_script(
      controlled.connection,
      connection.statement("SELECT count(*)::text FROM idle"),
      5000,
    )
  Ok(CopyAndNext(copied:, next:))
}

fn slow_produce_tests() -> TestSuite {
  describe(
    "a slow produce function",
    controlled_act_setup(first_driver_server, copy_slowly),
    [
      it(
        "cuts off a slow produce function at its deadline",
        fn(shared: ControlledCopy(Int, CopyError(ChunkError))) {
          shared.outcome.copied
          |> should
          |> be_error
          |> extract_copy_failure
          |> be_equal(DeadlinePassed(cancelled: True))
          |> or_fail_with("Expected the end of the COPY at the deadline")
        },
      ),
      it(
        "stores no row of a slow produce function",
        fn(shared: ControlledCopy(Int, CopyError(ChunkError))) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"0">>)]])
          |> or_fail_with("Expected no row stored")
        },
      ),
    ],
  )
}

/// A COPY TO STDOUT whose fold holds the first row until its backend is
/// idle, past the deadline of 300 milliseconds, and a script after it.
fn read_slowly(
  controlled: ControlledConnection,
) -> Result(CopyAndNext(Bool, CopyError(ChunkError)), String) {
  let copied =
    copy_to(
      controlled.connection,
      connection.statement(
        "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
      ),
      300,
      False,
      fn(waited, row) {
        read_until_idle(waited, row, controlled.control, controlled.backend_pid)
      },
    )
  let next =
    run_script(controlled.connection, connection.statement("SELECT 8"), 5000)
  Ok(CopyAndNext(copied:, next:))
}

fn slow_fold_tests() -> TestSuite {
  describe(
    "a slow fold",
    controlled_act_setup(first_driver_server, read_slowly),
    [
      it(
        "cuts off a slow fold at its deadline",
        fn(shared: ControlledCopy(Bool, CopyError(ChunkError))) {
          shared.outcome.copied
          |> should
          |> be_error
          |> extract_copy_failure
          |> be_equal(DeadlinePassed(cancelled: True))
          |> or_fail_with("Expected DeadlinePassed(True)")
        },
      ),
      it(
        "stays usable after a slow fold passed its deadline",
        fn(shared: ControlledCopy(Bool, CopyError(ChunkError))) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected a usable connection")
        },
      ),
    ],
  )
}

/// A COPY TO STDOUT of 10,000,000 rows whose fold fails at the first row,
/// so the deadline of 300 milliseconds ends the reading of the rest, and
/// a script after it.
fn read_after_failed_fold(
  connection: Connection,
) -> Result(CopyAndNext(Int, CopyError(String)), String) {
  let copied =
    copy_to(
      connection,
      connection.statement(
        "COPY (SELECT n FROM generate_series(1, 10000000) n) TO STDOUT",
      ),
      300,
      0,
      fail_at_first_row,
    )
  let next = run_script(connection, connection.statement("SELECT 9"), 5000)
  Ok(CopyAndNext(copied:, next:))
}

fn cut_off_fold_tests() -> TestSuite {
  describe(
    "the rest of a COPY after a failed fold",
    connection_act_setup(first_driver_server, read_after_failed_fold),
    [
      it(
        "cuts off the reading of the rest after a failed fold",
        fn(shared: DirectCopy(Int, CopyError(String))) {
          shared.outcome.copied
          |> should
          |> be_error
          |> extract_copy_failure
          |> be_equal(DeadlinePassed(cancelled: True))
          |> or_fail_with(
            "Expected the deadline to end the reading of the rest",
          )
        },
      ),
      it(
        "stays usable after the deadline cut off the rest of a COPY",
        fn(shared: DirectCopy(Int, CopyError(String))) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected a usable connection")
        },
      ),
    ],
  )
}

/// The answers of a script and of a COPY that the produce function of a
/// COPY runs on the same connection.
type InnerAnswers =
  #(Result(List(Outcome), ScriptError), Result(Int, CopyError(ChunkError)))

type InsideCopy =
  ActOutcome(Connection, Result(Int, CopyError(InnerAnswers)))

/// A COPY FROM STDIN whose produce function runs a script and a second
/// COPY on the same connection, each with a deadline of 50 milliseconds.
fn copy_inside_copy(
  connection: Connection,
) -> Result(Result(Int, CopyError(InnerAnswers)), String) {
  use Nil <- try(run_control_script(
    connection,
    "CREATE TEMP TABLE waiting (id int, name text)",
  ))
  Ok(
    copy_from(
      connection,
      connection.statement("COPY waiting FROM STDIN"),
      5000,
      copy_inside(_, connection),
    ),
  )
}

fn copy_inside_tests() -> TestSuite {
  describe(
    "requests of the caller inside its COPY",
    connection_act_setup(first_driver_server, copy_inside_copy),
    [
      it(
        "serves no other request of the caller while its COPY runs",
        fn(shared: InsideCopy) {
          shared.outcome
          |> should
          |> be_error
          |> extract_app_failure
          |> extract_first_of_pair
          |> be_error
          |> be_equal(ScriptRequestFailed(DeadlinePassed(cancelled: False)))
          |> or_fail_with("Expected the inner script to wait to its deadline")
        },
      ),
      it(
        "serves no other COPY of the caller while its COPY runs",
        fn(shared: InsideCopy) {
          shared.outcome
          |> should
          |> be_error
          |> extract_app_failure
          |> extract_second_of_pair
          |> be_error
          |> extract_copy_failure
          |> be_equal(DeadlinePassed(cancelled: False))
          |> or_fail_with("Expected the inner COPY to wait to its deadline")
        },
      ),
    ],
  )
}

/// The answer of a COPY whose produce function stopped its connection, and
/// the answer of the chunk that the function sent after the stop.
type StoppedAnswers =
  #(Result(Int, CopyError(ChunkError)), Result(Result(Nil, ChunkError), Nil))

type StoppedInside =
  ActOutcome(Connection, StoppedAnswers)

/// A COPY FROM STDIN whose produce function stops the connection, then
/// sends a row.
fn copy_stopping_its_connection(
  connection: Connection,
) -> Result(StoppedAnswers, String) {
  use Nil <- try(run_control_script(
    connection,
    "CREATE TEMP TABLE stopped (id int, name text)",
  ))
  let told = process.new_subject()
  let copied =
    copy_from(
      connection,
      connection.statement("COPY stopped FROM STDIN"),
      5000,
      stop_then_send(_, connection, told),
    )
  Ok(#(copied, process.receive(told, 0)))
}

fn copy_stopping_tests() -> TestSuite {
  describe(
    "a COPY whose function stops its connection",
    connection_act_setup(first_driver_server, copy_stopping_its_connection),
    [
      it(
        "gives the chunk after the stop ChunkFailed(ConnectionProcessDown)",
        fn(shared: StoppedInside) {
          shared.outcome
          |> should
          |> extract_second_of_pair
          |> be_ok
          |> be_error
          |> be_equal(ChunkFailed(ConnectionProcessDown))
          |> or_fail_with("Expected the chunk to find the process gone")
        },
      ),
      it(
        "gives the COPY CopyFailed(ConnectionProcessDown) at its end",
        fn(shared: StoppedInside) {
          shared.outcome
          |> should
          |> extract_first_of_pair
          |> be_error
          |> be_equal(CopyFailed(ConnectionProcessDown))
          |> or_fail_with("Expected the end to find the process gone")
        },
      ),
    ],
  )
}

// Callers that end in the middle of a COPY: one act for two tests -------------

/// A connection, and a caller process that runs a COPY on it and never
/// ends by itself.
type HungCopy(told) {
  HungCopy(connection: Connection, caller: CopyCaller(told))
}

/// What the function of the caller told before the caller was killed, and
/// what the next request on the connection gave after it.
type CallerEnd(told) {
  CallerEnd(told: Result(told, Nil), next: Result(List(Outcome), ScriptError))
}

type EndedCaller(told) =
  ActOutcome(HungCopy(told), CallerEnd(told))

/// The context of a describe whose tests check one caller that ends in the
/// middle of a COPY: the setup runs `scripts` on a new connection, starts
/// a caller that runs `copy` on it, waits until the caller tells what its
/// function did, kills it, and runs `next_sql`. The teardown kills the
/// caller and stops the connection.
fn hung_copy_setup(
  scripts: List(String),
  copy: fn(Connection, Subject(told)) -> answer,
  next_sql: String,
) -> Context(EndedCaller(told)) {
  act_setup(
    start: fn() { start_hung_copy(scripts, copy) },
    stop: stop_hung_copy,
    act: end_caller(_, next_sql),
  )
}

fn start_hung_copy(
  scripts: List(String),
  copy: fn(Connection, Subject(told)) -> answer,
) -> Result(HungCopy(told), String) {
  use connection <- try(start_connection(first_driver_server.port))
  use Nil <- try(
    try_each(scripts, run_control_script(connection, _))
    |> map_error(stop_after_error(connection, _)),
  )
  Ok(HungCopy(connection:, caller: start_copy_caller(copy(connection, _))))
}

fn stop_hung_copy(hung: HungCopy(told)) -> Result(Nil, String) {
  process.kill(hung.caller.pid)
  stop_connection(hung.connection)
}

fn end_caller(
  hung: HungCopy(told),
  next_sql: String,
) -> Result(CallerEnd(told), String) {
  let told = caller_told(hung.caller)
  process.kill(hung.caller.pid)
  let next = run_script(hung.connection, connection.statement(next_sql), 5000)
  Ok(CallerEnd(told:, next:))
}

fn rows_caller_tests() -> TestSuite {
  describe(
    "a caller that ends after it sent rows",
    hung_copy_setup(
      ["CREATE TEMP TABLE hung (id int, name text)"],
      hang_after_rows,
      "SELECT count(*)::text FROM hung",
    ),
    [
      it(
        "tells that the caller sent its rows before it ends",
        fn(shared: EndedCaller(String)) {
          shared.outcome.told
          |> should
          |> be_ok
          |> be_equal("sent")
          |> or_fail_with("Expected the caller to send its rows")
        },
      ),
      it(
        "abandons a COPY FROM STDIN when its caller ends",
        fn(shared: EndedCaller(String)) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"0">>)]])
          |> or_fail_with("Expected no row stored, and a usable connection")
        },
      ),
    ],
  )
}

fn refusal_caller_tests() -> TestSuite {
  describe(
    "a caller that ends after the server refused its row",
    hung_copy_setup(
      ["CREATE TEMP TABLE hung (id int, name text)"],
      hang_after_refusal,
      "SELECT count(*)::text FROM hung",
    ),
    [
      it(
        "tells the caller the server's refusal of its row",
        fn(shared: EndedCaller(Result(Nil, ChunkError))) {
          shared.outcome.told
          |> should
          |> be_ok
          |> be_error
          |> extract_chunk_refusal_code
          |> be_equal("22P02")
          |> or_fail_with("Expected the refusal")
        },
      ),
      it(
        "drops the end of a COPY when its caller ends before it took it",
        fn(shared: EndedCaller(Result(Nil, ChunkError))) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_first
          |> extract_command_result
          |> extract_command_rows
          |> be_equal([[Text(<<"0">>)]])
          |> or_fail_with("Expected a usable connection after the refusal")
        },
      ),
    ],
  )
}

fn row_caller_tests() -> TestSuite {
  describe(
    "a caller that ends while it holds a row",
    hung_copy_setup([], hang_at_first_row, "SELECT 9"),
    [
      it(
        "tells that the caller holds the first row before it ends",
        fn(shared: EndedCaller(String)) {
          shared.outcome.told
          |> should
          |> be_ok
          |> be_equal("row")
          |> or_fail_with("Expected the caller to hold a row")
        },
      ),
      it(
        "reads the rest of a COPY TO STDOUT when its caller ends",
        fn(shared: EndedCaller(String)) {
          shared.outcome.next
          |> should
          |> be_ok
          |> extract_outcome_tags
          |> be_equal(["SELECT 1"])
          |> or_fail_with("Expected a usable connection")
        },
      ),
    ],
  )
}
