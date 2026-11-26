//// Tests for the code examples in the hexdocs of the query functions, the
//// value functions and the decoders of `dream_postgres/client`. Each
//// example runs on the real PostgreSQL 16 server of docker-compose.yml.

import dream_postgres/client.{execute, numeric_text_decoder, query, returning}
import dream_postgres_client.{PostgresqlError, Returned, UnexpectedResultType}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/test_database.{with_schema}
import gleam/dynamic/decode.{DecodeError, at}
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import snippets/client_array
import snippets/client_bool
import snippets/client_bytea
import snippets/client_calendar_date
import snippets/client_calendar_time_of_day
import snippets/client_float
import snippets/client_int
import snippets/client_null
import snippets/client_nullable
import snippets/client_numeric_as_text.{exact_total}
import snippets/client_numeric_decoder
import snippets/client_numeric_text.{add_one_cent}
import snippets/client_numeric_text_decoder.{price}
import snippets/client_query
import snippets/client_text
import snippets/client_timeout
import snippets/client_timestamp
import snippets/client_transaction

pub fn tests() -> TestSuite {
  describe("dream_postgres/client query snippets", [
    query_tests(),
    value_tests(),
    time_tests(),
  ])
}

fn query_tests() {
  group("query, parameter, returning, execute, timeout and transaction", [
    it("client_query.add adds 2 and 3", fn() {
      // Act
      let result = test_database.with_schema(client_query.add(_, 2, 3))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [5])))
      |> or_fail_with("Expected one row with 5")
    }),
    it("client_timeout.one_in_a_second gives 1", fn() {
      // Act
      let result = test_database.with_schema(client_timeout.one_in_a_second)

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [1])))
      |> or_fail_with("Expected one row with 1")
    }),
    it("client_transaction.answer_in_transaction gives [42]", fn() {
      // Act
      let result =
        test_database.with_schema(client_transaction.answer_in_transaction)

      // Assert
      result
      |> should
      |> be_equal(Ok([42]))
      |> or_fail_with("Expected [42]")
    }),
  ])
}

fn value_tests() {
  group("value functions", [
    it("client_null.null_is_null gives True", fn() {
      // Act
      let result = test_database.with_schema(client_null.null_is_null)

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [True])))
      |> or_fail_with("Expected one row with True")
    }),
    it("client_bool.negate turns True into False", fn() {
      // Act
      let result = test_database.with_schema(client_bool.negate(_, True))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [False])))
      |> or_fail_with("Expected one row with False")
    }),
    it("client_int.next_number turns 41 into 42", fn() {
      // Act
      let result = test_database.with_schema(client_int.next_number(_, 41))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [42])))
      |> or_fail_with("Expected one row with 42")
    }),
    it("client_float.double turns 2.5 into 5.0", fn() {
      // Act
      let result = test_database.with_schema(client_float.double(_, 2.5))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [5.0])))
      |> or_fail_with("Expected one row with 5.0")
    }),
    it("client_text.shout turns ada into ADA", fn() {
      // Act
      let result = test_database.with_schema(client_text.shout(_, "ada"))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["ADA"])))
      |> or_fail_with("Expected one row with ADA")
    }),
    it("client_bytea.byte_count counts 3 bytes", fn() {
      // Act
      let result =
        test_database.with_schema(client_bytea.byte_count(_, <<1, 2, 3>>))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [3])))
      |> or_fail_with("Expected one row with 3")
    }),
    it("client_array.sort_numbers sorts [3, 1, 2]", fn() {
      // Act
      let result =
        test_database.with_schema(client_array.sort_numbers(_, [3, 1, 2]))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [[1, 2, 3]])))
      |> or_fail_with("Expected one row with [1, 2, 3]")
    }),
    it("client_nullable.nickname_or_none gives none for None", fn() {
      // Act
      let result =
        test_database.with_schema(client_nullable.nickname_or_none(_, None))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["none"])))
      |> or_fail_with("Expected one row with none")
    }),
    it("client_nullable.nickname_or_none gives the nickname for Some", fn() {
      // Act
      let result =
        test_database.with_schema(client_nullable.nickname_or_none(
          _,
          Some("Ace"),
        ))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["Ace"])))
      |> or_fail_with("Expected one row with Ace")
    }),
    it("client_numeric_decoder.price_with_tax turns 1000 cents into 12.5", fn() {
      // Act
      let result =
        test_database.with_schema(client_numeric_decoder.price_with_tax(_, 1000))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [12.5])))
      |> or_fail_with("Expected one row with 12.5")
    }),
    it("client_numeric_as_text.exact_total keeps every digit", fn() {
      // Act
      let result = with_schema(exact_total)

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["12345678901234567.90"])))
      |> or_fail_with("Expected one row with 12345678901234567.90")
    }),
    it("client_numeric_text_decoder.price keeps the trailing zero", fn() {
      // Act
      let result = with_schema(price)

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["1.50"])))
      |> or_fail_with("Expected one row with 1.50")
    }),
    it("client_numeric_text.add_one_cent adds a cent to an exact amount", fn() {
      // Act
      let result = with_schema(add_one_cent(_, "12345678901234567.89"))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["12345678901234567.90"])))
      |> or_fail_with("Expected one row with 12345678901234567.90")
    }),
    it("client_numeric_text.add_one_cent keeps NaN", fn() {
      // Act
      let result = with_schema(add_one_cent(_, "NaN"))

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: ["NaN"])))
      |> or_fail_with("Expected one row with NaN")
    }),
    it(
      "client_numeric_text.add_one_cent refuses a text that is not a number",
      fn() {
        // Act
        let result = with_schema(add_one_cent(_, "abc"))

        // Assert
        result
        |> should
        |> be_equal(
          Error(PostgresqlError(
            code: "22P02",
            name: "invalid_text_representation",
            message: "invalid input syntax for type numeric: \"abc\"",
          )),
        )
        |> or_fail_with("Expected the 22P02 error of PostgreSQL")
      },
    ),
    it("client_numeric_text_decoder fails without numeric_as_text", fn() {
      // Act
      let result =
        with_schema(fn(connection) {
          "SELECT 1.5::numeric"
          |> query
          |> returning(at([0], numeric_text_decoder()))
          |> execute(connection)
        })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(expected: "String", found: "Float", path: ["0"]),
          ]),
        ),
      )
      |> or_fail_with("Expected a decode error for a Float")
    }),
  ])
}

fn time_tests() {
  group("time values and decoders", [
    it("client_timestamp.one_hour_later adds one hour", fn() {
      // Arrange
      let start = timestamp.from_unix_seconds(1_764_000_000)

      // Act
      let result =
        test_database.with_schema(client_timestamp.one_hour_later(_, start))

      // Assert
      result
      |> should
      |> be_equal(
        Ok(
          Returned(count: 1, rows: [timestamp.from_unix_seconds(1_764_003_600)]),
        ),
      )
      |> or_fail_with("Expected one row one hour later")
    }),
    it("client_calendar_date.next_day goes from 31 December to 1 January", fn() {
      // Arrange
      let last_day = calendar.Date(2025, calendar.December, 31)

      // Act
      let result =
        test_database.with_schema(client_calendar_date.next_day(_, last_day))

      // Assert
      result
      |> should
      |> be_equal(
        Ok(Returned(count: 1, rows: [calendar.Date(2026, calendar.January, 1)])),
      )
      |> or_fail_with("Expected one row with 1 January 2026")
    }),
    it("client_calendar_time_of_day.one_minute_later adds one minute", fn() {
      // Arrange
      let time =
        calendar.TimeOfDay(hours: 9, minutes: 59, seconds: 30, nanoseconds: 0)

      // Act
      let result =
        test_database.with_schema(client_calendar_time_of_day.one_minute_later(
          _,
          time,
        ))

      // Assert
      result
      |> should
      |> be_equal(
        Ok(
          Returned(count: 1, rows: [
            calendar.TimeOfDay(
              hours: 10,
              minutes: 0,
              seconds: 30,
              nanoseconds: 0,
            ),
          ]),
        ),
      )
      |> or_fail_with("Expected one row with 10:00:30")
    }),
  ])
}
