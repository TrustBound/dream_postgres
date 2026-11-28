//// The time codecs against the exact bytes of PostgreSQL's binary formats.

import dream_postgres/codec
import dream_postgres/codecs/codec_type.{Malformed, NullValue, OutOfRange}
import dream_postgres/driver/cell.{Binary, Null}
import dream_postgres/time.{
  Finite, Interval, NegativeInfinity, PositiveInfinity, TimeWithOffset,
}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/interval_bytes
import fixtures/type_catalog
import gleam/time/calendar.{Date, July, November, TimeOfDay}
import gleam/time/timestamp
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}

pub fn tests() -> TestSuite {
  describe("time codecs", [
    group("date", [
      it("takes date", fn() {
        // Arrange
        let subject = codec.date

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("date"))
        |> be_true()
        |> or_fail_with("Expected date to take the type date")
      }),
      it("writes 2000-01-01 as day 0", fn() {
        // Arrange
        let value = Date(2000, calendar.January, 1)

        // Act and assert
        value
        |> should
        |> encode_as(codec.date, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<0:size(32)>>))
        |> or_fail_with("Expected 2000-01-01 to be day 0")
      }),
      it("writes 2026-11-27 as day 9827", fn() {
        // Arrange
        let value = Date(2026, November, 27)

        // Act and assert
        value
        |> should
        |> encode_as(codec.date, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<9827:size(32)>>))
        |> or_fail_with("Expected 2026-11-27 to be day 9827")
      }),
      it("writes a date before 2000 as a negative day", fn() {
        // Arrange
        let value = Date(1969, July, 20)

        // Act and assert
        value
        |> should
        |> encode_as(codec.date, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<-11_122:size(32)>>))
        |> or_fail_with("Expected 1969-07-20 to be day -11122")
      }),
      it("refuses a date that does not exist", fn() {
        // Arrange
        let value = Date(2026, calendar.February, 30)

        // Act and assert
        value
        |> should
        |> encode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal("2026-2-30 is not a valid date")
        |> or_fail_with(
          "Expected 30 February to be refused as not a valid date",
        )
      }),
      it("refuses a date too far in the future", fn() {
        // Arrange
        let value = Date(9_999_999, calendar.January, 1)

        // Act and assert
        value
        |> should
        |> encode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal("9999999-1-1 is out of range for date")
        |> or_fail_with("Expected the year 9999999 to be out of range for date")
      }),
      it("reads day 9827", fn() {
        // Arrange
        let cell = Binary(<<9827:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Date(2026, November, 27))
        |> or_fail_with("Expected day 9827 to be 2026-11-27")
      }),
      it("reads a negative day", fn() {
        // Arrange
        let cell = Binary(<<-11_122:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Date(1969, July, 20))
        |> or_fail_with("Expected day -11122 to be 1969-07-20")
      }),
      it("gives OutOfRange for infinity", fn() {
        // Arrange
        let cell = Binary(<<2_147_483_647:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal(OutOfRange("infinity"))
        |> or_fail_with("Expected the date infinity to be out of range")
      }),
      it("gives OutOfRange for -infinity", fn() {
        // Arrange
        let cell = Binary(<<-2_147_483_648:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal(OutOfRange("-infinity"))
        |> or_fail_with("Expected the date -infinity to be out of range")
      }),
      it("refuses two bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal(Malformed("2 bytes are not a date value"))
        |> or_fail_with("Expected two bytes to be a malformed date")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date, type_catalog.base("date"))
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a date")
      }),
    ]),
    group("date or infinite", [
      it("writes a finite date", fn() {
        // Arrange
        let value = Finite(Date(2026, November, 27))

        // Act and assert
        value
        |> should
        |> encode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<9827:size(32)>>))
        |> or_fail_with("Expected the finite date 2026-11-27 to be day 9827")
      }),
      it("writes infinity", fn() {
        // Arrange
        let value = PositiveInfinity

        // Act and assert
        value
        |> should
        |> encode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<2_147_483_647:size(32)>>))
        |> or_fail_with("Expected the date infinity to be the largest int4")
      }),
      it("writes -infinity", fn() {
        // Arrange
        let value = NegativeInfinity

        // Act and assert
        value
        |> should
        |> encode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Binary(<<-2_147_483_648:size(32)>>))
        |> or_fail_with("Expected the date -infinity to be the smallest int4")
      }),
      it("reads a finite date", fn() {
        // Arrange
        let cell = Binary(<<0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(Finite(Date(2000, calendar.January, 1)))
        |> or_fail_with("Expected day 0 to be the finite date 2000-01-01")
      }),
      it("reads infinity", fn() {
        // Arrange
        let cell = Binary(<<2_147_483_647:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(PositiveInfinity)
        |> or_fail_with("Expected the largest int4 to be the date infinity")
      }),
      it("reads -infinity", fn() {
        // Arrange
        let cell = Binary(<<-2_147_483_648:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_ok()
        |> be_equal(NegativeInfinity)
        |> or_fail_with("Expected the smallest int4 to be the date -infinity")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codec.date_or_infinite, type_catalog.base("date"))
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a date or infinite")
      }),
    ]),
    group("time", [
      it("takes time", fn() {
        // Arrange
        let subject = codec.time

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("time"))
        |> be_true()
        |> or_fail_with("Expected time to take the type time")
      }),
      it("writes 13:45:30.25", fn() {
        // Arrange
        let value = TimeOfDay(13, 45, 30, 250_000_000)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time, type_catalog.base("time"))
        |> be_ok()
        |> be_equal(Binary(<<49_530_250_000:size(64)>>))
        |> or_fail_with("Expected 13:45:30.25 to be 49530250000 microseconds")
      }),
      it("rounds nanoseconds to the nearest microsecond", fn() {
        // Arrange
        let value = TimeOfDay(0, 0, 0, 1500)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time, type_catalog.base("time"))
        |> be_ok()
        |> be_equal(Binary(<<2:size(64)>>))
        |> or_fail_with("Expected 1500 nanoseconds to round to 2 microseconds")
      }),
      it("writes 24:00:00", fn() {
        // Arrange
        let value = TimeOfDay(24, 0, 0, 0)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time, type_catalog.base("time"))
        |> be_ok()
        |> be_equal(Binary(<<86_400_000_000:size(64)>>))
        |> or_fail_with("Expected 24:00:00 to be 86400000000 microseconds")
      }),
      it("refuses a time after 24:00:00", fn() {
        // Arrange
        let value = TimeOfDay(24, 0, 1, 0)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time, type_catalog.base("time"))
        |> be_error()
        |> be_equal("the time of day 24:0:1.0 is out of range")
        |> or_fail_with("Expected 24:00:01 to be out of range")
      }),
      it("refuses a negative part", fn() {
        // Arrange
        let value = TimeOfDay(-1, 0, 0, 0)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time, type_catalog.base("time"))
        |> be_error()
        |> be_equal("the time of day -1:0:0.0 is out of range")
        |> or_fail_with("Expected the hour -1 to be out of range")
      }),
      it("reads 13:45:30.25", fn() {
        // Arrange
        let cell = Binary(<<49_530_250_000:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.time, type_catalog.base("time"))
        |> be_ok()
        |> be_equal(TimeOfDay(13, 45, 30, 250_000_000))
        |> or_fail_with("Expected 49530250000 microseconds to be 13:45:30.25")
      }),
      it("refuses four bytes", fn() {
        // Arrange
        let cell = Binary(<<0:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.time, type_catalog.base("time"))
        |> be_error()
        |> be_equal(Malformed("4 bytes are not a time value"))
        |> or_fail_with("Expected four bytes to be a malformed time")
      }),
    ]),
    group("time with offset", [
      it("takes timetz", fn() {
        // Arrange
        let subject = codec.time_with_offset

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("timetz"))
        |> be_true()
        |> or_fail_with("Expected time_with_offset to take the type timetz")
      }),
      it("writes the offset as seconds west of UTC", fn() {
        // Arrange
        let value = TimeWithOffset(TimeOfDay(10, 0, 0, 0), 7200)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_ok()
        |> be_equal(Binary(<<36_000_000_000:size(64), -7200:size(32)>>))
        |> or_fail_with("Expected the offset 7200 east to be written as -7200")
      }),
      it("reads the offset as seconds east of UTC", fn() {
        // Arrange
        let cell = Binary(<<36_000_000_000:size(64), 18_000:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_ok()
        |> be_equal(TimeWithOffset(TimeOfDay(10, 0, 0, 0), -18_000))
        |> or_fail_with("Expected the offset 18000 west to be read as -18000")
      }),
      it("refuses an offset of 16 hours", fn() {
        // Arrange
        let value = TimeWithOffset(TimeOfDay(10, 0, 0, 0), 57_600)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_error()
        |> be_equal("the offset of 57600 seconds is out of range for timetz")
        |> or_fail_with("Expected an offset of 16 hours to be out of range")
      }),
      it("refuses a time out of range", fn() {
        // Arrange
        let value = TimeWithOffset(TimeOfDay(25, 0, 0, 0), 0)

        // Act and assert
        value
        |> should
        |> encode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_error()
        |> be_equal("the time of day 25:0:0.0 is out of range")
        |> or_fail_with("Expected the hour 25 to be out of range")
      }),
      it("refuses eight bytes", fn() {
        // Arrange
        let cell = Binary(<<0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_error()
        |> be_equal(Malformed("8 bytes are not a timetz value"))
        |> or_fail_with("Expected eight bytes to be a malformed timetz")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codec.time_with_offset, type_catalog.base("timetz"))
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with("Expected NULL to be refused as a timetz")
      }),
    ]),
    group("timestamp", [
      it("takes timestamp", fn() {
        // Arrange
        let subject = codec.timestamp

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("timestamp"))
        |> be_true()
        |> or_fail_with("Expected timestamp to take the type timestamp")
      }),
      it("refuses timestamptz", fn() {
        // Arrange
        let subject = codec.timestamp

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("timestamptz"))
        |> be_false()
        |> or_fail_with("Expected timestamp to refuse the type timestamptz")
      }),
      it("takes timestamptz with the time zone codec", fn() {
        // Arrange
        let subject = codec.timestamp_with_time_zone

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("timestamptz"))
        |> be_true()
        |> or_fail_with(
          "Expected timestamp_with_time_zone to take the type timestamptz",
        )
      }),
      it("writes the epoch of PostgreSQL as 0", fn() {
        // Arrange
        let value = timestamp.from_unix_seconds(946_684_800)

        // Act and assert
        value
        |> should
        |> encode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_ok()
        |> be_equal(Binary(<<0:size(64)>>))
        |> or_fail_with("Expected 2000-01-01 00:00:00 to be 0 microseconds")
      }),
      it("writes half a second before it", fn() {
        // Arrange
        let value =
          timestamp.from_unix_seconds_and_nanoseconds(946_684_799, 500_000_000)

        // Act and assert
        value
        |> should
        |> encode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_ok()
        |> be_equal(Binary(<<-500_000:size(64)>>))
        |> or_fail_with(
          "Expected half a second before 2000 to be -500000 microseconds",
        )
      }),
      it("refuses a timestamp beyond the int64 range", fn() {
        // Arrange
        let value = timestamp.from_unix_seconds(9_300_000_000_000)

        // Act and assert
        value
        |> should
        |> encode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_error()
        |> be_equal("the timestamp is out of range for PostgreSQL")
        |> or_fail_with(
          "Expected a timestamp beyond int64 microseconds to be out of range",
        )
      }),
      it("reads 0 as the epoch of PostgreSQL", fn() {
        // Arrange
        let cell = Binary(<<0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_ok()
        |> be_equal(timestamp.from_unix_seconds(946_684_800))
        |> or_fail_with("Expected 0 microseconds to be 2000-01-01 00:00:00")
      }),
      it("reads half a second before it", fn() {
        // Arrange
        let cell = Binary(<<-500_000:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_ok()
        |> be_equal(timestamp.from_unix_seconds_and_nanoseconds(
          946_684_799,
          500_000_000,
        ))
        |> or_fail_with(
          "Expected -500000 microseconds to be half a second before 2000",
        )
      }),
      it("gives OutOfRange for infinity", fn() {
        // Arrange
        let cell = Binary(<<9_223_372_036_854_775_807:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_error()
        |> be_equal(OutOfRange("infinity"))
        |> or_fail_with("Expected the timestamp infinity to be out of range")
      }),
      it("gives OutOfRange for -infinity", fn() {
        // Arrange
        let cell = Binary(<<-9_223_372_036_854_775_808:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.timestamp, type_catalog.base("timestamp"))
        |> be_error()
        |> be_equal(OutOfRange("-infinity"))
        |> or_fail_with("Expected the timestamp -infinity to be out of range")
      }),
    ]),
    group("timestamp or infinite", [
      it("takes timestamptz", fn() {
        // Arrange
        let subject = codec.timestamp_with_time_zone_or_infinite

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("timestamptz"))
        |> be_true()
        |> or_fail_with(
          "Expected timestamp_with_time_zone_or_infinite to take the type timestamptz",
        )
      }),
      it("writes a finite timestamp", fn() {
        // Arrange
        let value = Finite(timestamp.from_unix_seconds(946_684_800))

        // Act and assert
        value
        |> should
        |> encode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(Binary(<<0:size(64)>>))
        |> or_fail_with(
          "Expected the finite epoch of PostgreSQL to be 0 microseconds",
        )
      }),
      it("writes infinity", fn() {
        // Arrange
        let value = PositiveInfinity

        // Act and assert
        value
        |> should
        |> encode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(Binary(<<9_223_372_036_854_775_807:size(64)>>))
        |> or_fail_with(
          "Expected the timestamp infinity to be the largest int8",
        )
      }),
      it("writes -infinity", fn() {
        // Arrange
        let value = NegativeInfinity

        // Act and assert
        value
        |> should
        |> encode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(Binary(<<-9_223_372_036_854_775_808:size(64)>>))
        |> or_fail_with(
          "Expected the timestamp -infinity to be the smallest int8",
        )
      }),
      it("reads a finite timestamp", fn() {
        // Arrange
        let cell = Binary(<<0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(Finite(timestamp.from_unix_seconds(946_684_800)))
        |> or_fail_with(
          "Expected 0 microseconds to be the finite epoch of PostgreSQL",
        )
      }),
      it("reads infinity", fn() {
        // Arrange
        let cell = Binary(<<9_223_372_036_854_775_807:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(PositiveInfinity)
        |> or_fail_with(
          "Expected the largest int8 to be the timestamp infinity",
        )
      }),
      it("reads -infinity", fn() {
        // Arrange
        let cell = Binary(<<-9_223_372_036_854_775_808:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_ok()
        |> be_equal(NegativeInfinity)
        |> or_fail_with(
          "Expected the smallest int8 to be the timestamp -infinity",
        )
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(
          codec.timestamp_or_infinite,
          type_catalog.base("timestamp"),
        )
        |> be_error()
        |> be_equal(NullValue)
        |> or_fail_with(
          "Expected NULL to be refused as a timestamp or infinite",
        )
      }),
    ]),
    group("interval", [
      it("takes interval", fn() {
        // Arrange
        let subject = codec.interval

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("interval"))
        |> be_true()
        |> or_fail_with("Expected interval to take the type interval")
      }),
      it("writes microseconds, days, months", fn() {
        // Arrange
        let value = Interval(14, 3, 4_000_000)

        // Act and assert
        value
        |> should
        |> encode_as(codec.interval, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Binary(<<4_000_000:size(64), 3:size(32), 14:size(32)>>))
        |> or_fail_with(
          "Expected the microseconds, then the days, then the months",
        )
      }),
      it("refuses months beyond 32 bits", fn() {
        // Arrange
        let value = Interval(2_147_483_648, 0, 0)

        // Act and assert
        value
        |> should
        |> encode_as(codec.interval, type_catalog.base("interval"))
        |> be_error()
        |> be_equal("a part of the interval is out of range for PostgreSQL")
        |> or_fail_with("Expected months beyond int4 to be out of range")
      }),
      it("reads negative parts", fn() {
        // Arrange
        let cell = Binary(<<-1:size(64), -2:size(32), -3:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Interval(-3, -2, -1))
        |> or_fail_with(
          "Expected the negative parts -3 months, -2 days and -1 microseconds",
        )
      }),
      it("refuses eight bytes", fn() {
        // Arrange
        let cell = Binary(<<0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval, type_catalog.base("interval"))
        |> be_error()
        |> be_equal(Malformed("8 bytes are not a interval value"))
        |> or_fail_with("Expected eight bytes to be a malformed interval")
      }),
      it(
        "refuses the largest interval, which PostgreSQL 17 reads as infinity",
        fn() {
          // Arrange
          let value =
            Interval(2_147_483_647, 2_147_483_647, 9_223_372_036_854_775_807)

          // Act and assert
          value
          |> should
          |> encode_as(codec.interval, type_catalog.base("interval"))
          |> be_error()
          |> be_equal(
            "the interval of the largest or the smallest parts is infinite in PostgreSQL 17 and later; use interval_or_infinite",
          )
          |> or_fail_with(
            "Expected the largest interval to be refused as infinite",
          )
        },
      ),
      it(
        "refuses the smallest interval, which PostgreSQL 17 reads as -infinity",
        fn() {
          // Arrange
          let value =
            Interval(-2_147_483_648, -2_147_483_648, -9_223_372_036_854_775_808)

          // Act and assert
          value
          |> should
          |> encode_as(codec.interval, type_catalog.base("interval"))
          |> be_error()
          |> be_equal(
            "the interval of the largest or the smallest parts is infinite in PostgreSQL 17 and later; use interval_or_infinite",
          )
          |> or_fail_with(
            "Expected the smallest interval to be refused as infinite",
          )
        },
      ),
      it("gives OutOfRange for an infinite interval", fn() {
        // Arrange
        let cell = Binary(interval_bytes.infinite())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval, type_catalog.base("interval"))
        |> be_error()
        |> be_equal(OutOfRange("infinity"))
        |> or_fail_with("Expected the interval infinity to be out of range")
      }),
      it("gives OutOfRange for a -infinite interval", fn() {
        // Arrange
        let cell = Binary(interval_bytes.negative_infinite())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval, type_catalog.base("interval"))
        |> be_error()
        |> be_equal(OutOfRange("-infinity"))
        |> or_fail_with("Expected the interval -infinity to be out of range")
      }),
      it("writes infinity", fn() {
        // Arrange
        let value = PositiveInfinity

        // Act and assert
        value
        |> should
        |> encode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Binary(interval_bytes.infinite()))
        |> or_fail_with(
          "Expected the interval infinity to be the largest parts",
        )
      }),
      it("writes -infinity", fn() {
        // Arrange
        let value = NegativeInfinity

        // Act and assert
        value
        |> should
        |> encode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Binary(interval_bytes.negative_infinite()))
        |> or_fail_with(
          "Expected the interval -infinity to be the smallest parts",
        )
      }),
      it("writes a finite interval or infinite", fn() {
        // Arrange
        let value = Finite(Interval(14, 3, 4_000_000))

        // Act and assert
        value
        |> should
        |> encode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Binary(<<4_000_000:size(64), 3:size(32), 14:size(32)>>))
        |> or_fail_with(
          "Expected the finite interval as microseconds, days, months",
        )
      }),
      it("reads infinity", fn() {
        // Arrange
        let cell = Binary(interval_bytes.infinite())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(PositiveInfinity)
        |> or_fail_with(
          "Expected the largest parts to be the interval infinity",
        )
      }),
      it("reads -infinity", fn() {
        // Arrange
        let cell = Binary(interval_bytes.negative_infinite())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(NegativeInfinity)
        |> or_fail_with(
          "Expected the smallest parts to be the interval -infinity",
        )
      }),
      it("reads a finite interval or infinite", fn() {
        // Arrange
        let cell = Binary(<<-1:size(64), -2:size(32), -3:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_ok()
        |> be_equal(Finite(Interval(-3, -2, -1)))
        |> or_fail_with("Expected the finite interval of negative parts")
      }),
      it("refuses eight bytes for an interval or infinite", fn() {
        // Arrange
        let cell = Binary(<<0:size(64)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.interval_or_infinite, type_catalog.base("interval"))
        |> be_error()
        |> be_equal(Malformed("8 bytes are not a interval value"))
        |> or_fail_with(
          "Expected eight bytes to be a malformed interval or infinite",
        )
      }),
    ]),
  ])
}
