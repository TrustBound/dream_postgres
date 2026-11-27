//// Proves where each notice goes: to the notices subscriber as it
//// arrives, during the login, while idle and during any request, and with
//// an outcome only when it arrived during that outcome's request. No
//// notice goes with a later request.

import dream_postgres/driver/connection.{
  copy_to, prepare, run, run_housekeeping_script, statement, stop,
}
import dream_postgres/driver/housekeeping_sql.{rollback}
import dream_test/matchers.{be_equal, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/fake_server.{Answer, start_fake_server}
import driver/server_connection.{run_control_script, start_connection}
import driver/server_notices.{next_notice, start_noticed_connection}
import driver/servers.{first_driver_server}
import fixtures/copy_callbacks.{collect_row}
import fixtures/expected_failure.{expect_failure}
import fixtures/notice_bytes.{warning_notice_bytes}
import gleam/bit_array
import gleam/erlang/process
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_notice_codes.{extract_notice_codes}
import matchers/extract_report_code.{extract_report_code}

/// The tests of the notices.
pub fn tests() -> TestSuite {
  describe("the notices of a connection", [
    subscriber_tests(),
    carry_over_tests(),
  ])
}

/// A statement that warns, then fails.
const warns_then_fails_sql =
  "DO $$BEGIN RAISE WARNING 'disk almost full'; RAISE EXCEPTION 'boom'; END$$"

/// A statement whose parse warns with 22P06 when standard_conforming_strings
/// is off.
const backslash_sql = "SELECT 'a\\\\b'"

/// Makes the parse of `backslash_sql` warn.
const nonstandard_strings_sql =
  "SET standard_conforming_strings = off; SET escape_string_warning = on"

/// Makes a function that warns, for a COPY of its result.
const warning_function_sql =
  "CREATE OR REPLACE FUNCTION pg_temp.warn() RETURNS int LANGUAGE plpgsql AS $$BEGIN RAISE WARNING 'copied'; RETURN 1; END$$"

fn subscriber_tests() {
  group("the notices subscriber gets", [
    it("a notice of the login", fn() {
      // Act
      let notice = {
        let notices = process.new_subject()
        let login_answer =
          bit_array.concat([
            <<"R":utf8, 8:32, 0:32>>,
            warning_notice_bytes("01000", "at login"),
            <<"Z":utf8, 5:32, "I":utf8>>,
          ])
        use #(port, _fake_server) <- try(
          start_fake_server(Answer(login_answer)),
        )
        use connection <- try(start_noticed_connection(port, notices))
        let notice = next_notice(notices)
        stop(connection)
        notice
      }

      // Assert
      notice
      |> should
      |> be_ok
      |> extract_report_code
      |> be_equal("01000")
      |> or_fail_with("Expected the notice of the login")
    }),
    it("a notice that arrives while the connection is idle", fn() {
      // Act
      let notice = {
        let notices = process.new_subject()
        let login_answer =
          bit_array.concat([
            <<"R":utf8, 8:32, 0:32, "Z":utf8, 5:32, "I":utf8>>,
            warning_notice_bytes("01004", "while idle"),
          ])
        use #(port, _fake_server) <- try(
          start_fake_server(Answer(login_answer)),
        )
        use connection <- try(start_noticed_connection(port, notices))
        let notice = next_notice(notices)
        stop(connection)
        notice
      }

      // Assert
      notice
      |> should
      |> be_ok
      |> extract_report_code
      |> be_equal("01004")
      |> or_fail_with("Expected the notice of the idle time")
    }),
    it("the warning of a failed statement", fn() {
      // Act
      let notice = {
        let notices = process.new_subject()
        use connection <- try(start_noticed_connection(
          first_driver_server.port,
          notices,
        ))
        use Nil <- try(
          expect_failure(run(
            connection,
            statement(warns_then_fails_sql),
            [],
            [],
            5000,
          )),
        )
        let notice = next_notice(notices)
        stop(connection)
        notice
      }

      // Assert
      notice
      |> should
      |> be_ok
      |> extract_report_code
      |> be_equal("01000")
      |> or_fail_with("Expected the warning of the failed statement")
    }),
    it("the notice of a prepare", fn() {
      // Act
      let notice = {
        let notices = process.new_subject()
        use connection <- try(start_noticed_connection(
          first_driver_server.port,
          notices,
        ))
        use Nil <- try(run_control_script(connection, nonstandard_strings_sql))
        use _description <- try(
          prepare(connection, statement(backslash_sql), 5000)
          |> map_error(inspect),
        )
        let notice = next_notice(notices)
        stop(connection)
        notice
      }

      // Assert
      notice
      |> should
      |> be_ok
      |> extract_report_code
      |> be_equal("22P06")
      |> or_fail_with("Expected the notice of the prepare")
    }),
    it("the warning of a COPY", fn() {
      // Act
      let notice = {
        let notices = process.new_subject()
        use connection <- try(start_noticed_connection(
          first_driver_server.port,
          notices,
        ))
        use Nil <- try(run_control_script(connection, warning_function_sql))
        use _rows <- try(
          copy_to(
            connection,
            statement("COPY (SELECT pg_temp.warn()) TO STDOUT"),
            5000,
            [],
            collect_row,
          )
          |> map_error(inspect),
        )
        let notice = next_notice(notices)
        stop(connection)
        notice
      }

      // Assert
      notice
      |> should
      |> be_ok
      |> extract_report_code
      |> be_equal("01000")
      |> or_fail_with("Expected the warning of the COPY")
    }),
  ])
}

fn carry_over_tests() {
  group("with no subscriber, the next outcome gets no notice", [
    it("of a prepare", fn() {
      // Act
      let outcome = {
        use connection <- try(start_connection(first_driver_server.port))
        use Nil <- try(run_control_script(connection, nonstandard_strings_sql))
        use _description <- try(
          prepare(connection, statement(backslash_sql), 5000)
          |> map_error(inspect),
        )
        let outcome =
          run(connection, statement("SELECT 1"), [], [], 5000)
          |> map_error(inspect)
        stop(connection)
        outcome
      }

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_notice_codes
      |> be_equal([])
      |> or_fail_with("Expected no notice of the prepare")
    }),
    it("of a failed statement", fn() {
      // Act
      let outcome = {
        use connection <- try(start_connection(first_driver_server.port))
        use Nil <- try(
          expect_failure(run(
            connection,
            statement(warns_then_fails_sql),
            [],
            [],
            5000,
          )),
        )
        let outcome =
          run(connection, statement("SELECT 1"), [], [], 5000)
          |> map_error(inspect)
        stop(connection)
        outcome
      }

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_notice_codes
      |> be_equal([])
      |> or_fail_with("Expected no warning of the failed statement")
    }),
    it("of a housekeeping ROLLBACK", fn() {
      // Act
      let outcome = {
        use connection <- try(start_connection(first_driver_server.port))
        use _outcomes <- try(
          run_housekeeping_script(connection, rollback, 5000)
          |> map_error(inspect),
        )
        let outcome =
          run(connection, statement("SELECT 1"), [], [], 5000)
          |> map_error(inspect)
        stop(connection)
        outcome
      }

      // Assert
      outcome
      |> should
      |> be_ok
      |> extract_notice_codes
      |> be_equal([])
      |> or_fail_with("Expected no warning of the ROLLBACK")
    }),
  ])
}
