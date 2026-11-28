//// The Gleam values of PostgreSQL's time types that `gleam_time` does not
//// have. Dates, times of day and timestamps use `gleam_time`'s own types.
////
//// The codecs of `date`, `time`, `timetz`, `timestamp`, `timestamptz` and
//// `interval`, in PostgreSQL's binary formats:
////
//// - `date`: days since 2000-01-01, as a signed 32-bit integer.
//// - `time`: microseconds since midnight, as a signed 64-bit integer.
//// - `timetz`: the time, then the offset in seconds WEST of UTC, 32 bits.
//// - `timestamp`, `timestamptz`: microseconds since 2000-01-01 00:00:00
////   (UTC for `timestamptz`), as a signed 64-bit integer.
//// - `interval`: microseconds (64 bits), days (32 bits), months (32 bits).
////
//// The largest and the smallest value of the integer are `infinity` and
//// `-infinity` for `date`, `timestamp` and `timestamptz`.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, OutOfRange, binary_bytes, is_base,
  wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/int
import gleam/result
import gleam/time/calendar.{type Date, type TimeOfDay, Date, TimeOfDay}
import gleam/time/timestamp.{type Timestamp} as gleam_timestamp

/// An `interval`, as PostgreSQL stores it: months, days and microseconds,
/// each kept apart. A month has no fixed number of days and a day has no
/// fixed number of seconds (time zones), so the three parts do not fold
/// into one duration.
pub type Interval {
  Interval(months: Int, days: Int, microseconds: Int)
}

/// A `timetz`: a time of day and its offset from UTC, in seconds east of
/// UTC. `+02:00` is an offset of 7200.
pub type TimeWithOffset {
  TimeWithOffset(time: TimeOfDay, offset_seconds: Int)
}

/// A date or a timestamp that can be infinite. PostgreSQL stores
/// `infinity` and `-infinity` in `date`, `timestamp` and `timestamptz`.
pub type MaybeInfinite(a) {
  Finite(value: a)
  PositiveInfinity
  NegativeInfinity
}

// --- Codecs ---------------------------------------------------------------------

// Seconds from 1970-01-01 to 2000-01-01, the epoch of PostgreSQL.
const postgres_epoch_unix_seconds = 946_684_800

const seconds_per_day = 86_400

const microseconds_per_second = 1_000_000

const microseconds_per_day = 86_400_000_000

const int32_largest = 2_147_483_647

const int32_smallest = -2_147_483_648

const int64_largest = 9_223_372_036_854_775_807

const int64_smallest = -9_223_372_036_854_775_808

// --- date ---------------------------------------------------------------------

/// `date`, as `gleam_time`'s `Date`. `infinity` and `-infinity` give
/// `OutOfRange`: read them with `date_or_infinite`.
pub const date =
  Codec(
    name: "date",
    gleam_type: "Date",
    format: cell.BinaryFormat,
    accepts: accepts_date,
    encode: encode_date,
    decode: decode_date,
    placeholder: Date(2000, calendar.January, 1),
  )

/// `date`, as a `MaybeInfinite(Date)`, which holds `infinity` too.
pub const date_or_infinite =
  Codec(
    name: "date or infinite",
    gleam_type: "MaybeInfinite(Date)",
    format: cell.BinaryFormat,
    accepts: accepts_date,
    encode: encode_infinite_date,
    decode: decode_infinite_date,
    placeholder: PositiveInfinity,
  )

fn accepts_date(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["date"])
}

fn encode_date(
  value: Date,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  use days <- result.try(days_of_date(value))
  Ok(Binary(<<days:size(32)>>))
}

fn encode_infinite_date(
  value: MaybeInfinite(Date),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  case value {
    Finite(value:) -> encode_date(value, description, lookup)
    PositiveInfinity -> Ok(Binary(<<int32_largest:size(32)>>))
    NegativeInfinity -> Ok(Binary(<<int32_smallest:size(32)>>))
  }
}

fn days_of_date(value: Date) -> Result(Int, String) {
  case calendar.is_valid_date(value) {
    False -> Error(date_text(value) <> " is not a valid date")
    True -> days_in_range(value)
  }
}

fn days_in_range(value: Date) -> Result(Int, String) {
  let #(seconds, _) =
    gleam_timestamp.from_calendar(
      date: value,
      time: TimeOfDay(0, 0, 0, 0),
      offset: calendar.utc_offset,
    )
    |> gleam_timestamp.to_unix_seconds_and_nanoseconds
  let days = { seconds - postgres_epoch_unix_seconds } / seconds_per_day
  case days > int32_smallest && days < int32_largest {
    True -> Ok(days)
    False -> Error(date_text(value) <> " is out of range for date")
  }
}

fn decode_date(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Date, DecodeIssue) {
  use days <- result.try(int32_cell(value, description))
  case days {
    2_147_483_647 -> Error(OutOfRange("infinity"))
    -2_147_483_648 -> Error(OutOfRange("-infinity"))
    _ -> Ok(date_of_days(days))
  }
}

fn decode_infinite_date(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(MaybeInfinite(Date), DecodeIssue) {
  use days <- result.try(int32_cell(value, description))
  case days {
    2_147_483_647 -> Ok(PositiveInfinity)
    -2_147_483_648 -> Ok(NegativeInfinity)
    _ -> Ok(Finite(date_of_days(days)))
  }
}

fn date_of_days(days: Int) -> Date {
  let #(found, _) =
    gleam_timestamp.from_unix_seconds(
      postgres_epoch_unix_seconds + days * seconds_per_day,
    )
    |> gleam_timestamp.to_calendar(calendar.utc_offset)
  found
}

fn date_text(value: Date) -> String {
  int.to_string(value.year)
  <> "-"
  <> int.to_string(calendar.month_to_int(value.month))
  <> "-"
  <> int.to_string(value.day)
}

// --- time ---------------------------------------------------------------------

/// `time`, as `gleam_time`'s `TimeOfDay`, to the microsecond.
pub const time =
  Codec(
    name: "time",
    gleam_type: "TimeOfDay",
    format: cell.BinaryFormat,
    accepts: accepts_time,
    encode: encode_time,
    decode: decode_time,
    placeholder: TimeOfDay(0, 0, 0, 0),
  )

fn accepts_time(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["time"])
}

fn encode_time(
  value: TimeOfDay,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  use microseconds <- result.try(microseconds_of_time(value))
  Ok(Binary(<<microseconds:size(64)>>))
}

// A time of day as microseconds since midnight, rounded to the nearest
// microsecond. PostgreSQL takes 24:00:00, and nothing later.
fn microseconds_of_time(value: TimeOfDay) -> Result(Int, String) {
  let TimeOfDay(hours:, minutes:, seconds:, nanoseconds:) = value
  let microseconds =
    { hours * 3600 + minutes * 60 + seconds }
    * microseconds_per_second
    + round_to_microseconds(nanoseconds)
  case
    hours >= 0
    && minutes >= 0
    && seconds >= 0
    && nanoseconds >= 0
    && microseconds <= microseconds_per_day
  {
    True -> Ok(microseconds)
    False -> Error("the time of day " <> time_text(value) <> " is out of range")
  }
}

fn decode_time(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(TimeOfDay, DecodeIssue) {
  use microseconds <- result.try(int64_cell(value, description))
  Ok(time_of_microseconds(microseconds))
}

fn time_of_microseconds(microseconds: Int) -> TimeOfDay {
  let seconds = microseconds / microseconds_per_second
  TimeOfDay(
    hours: seconds / 3600,
    minutes: seconds % 3600 / 60,
    seconds: seconds % 60,
    nanoseconds: microseconds % microseconds_per_second * 1000,
  )
}

fn time_text(value: TimeOfDay) -> String {
  int.to_string(value.hours)
  <> ":"
  <> int.to_string(value.minutes)
  <> ":"
  <> int.to_string(value.seconds)
  <> "."
  <> int.to_string(value.nanoseconds)
}

// --- timetz -------------------------------------------------------------------

/// `timetz`, as a `TimeWithOffset`.
pub const time_with_offset =
  Codec(
    name: "time with offset",
    gleam_type: "TimeWithOffset",
    format: cell.BinaryFormat,
    accepts: accepts_time_with_offset,
    encode: encode_time_with_offset,
    decode: decode_time_with_offset,
    placeholder: TimeWithOffset(TimeOfDay(0, 0, 0, 0), 0),
  )

fn accepts_time_with_offset(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["timetz"])
}

fn encode_time_with_offset(
  value: TimeWithOffset,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  use microseconds <- result.try(microseconds_of_time(value.time))
  // PostgreSQL's limit for a time zone offset is 15:59:59.
  case value.offset_seconds > -57_600 && value.offset_seconds < 57_600 {
    True ->
      Ok(
        Binary(<<microseconds:size(64), { 0 - value.offset_seconds }:size(32)>>),
      )
    False ->
      Error(
        "the offset of "
        <> int.to_string(value.offset_seconds)
        <> " seconds is out of range for timetz",
      )
  }
}

fn decode_time_with_offset(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(TimeWithOffset, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<microseconds:signed-size(64), seconds_west:signed-size(32)>> ->
      Ok(TimeWithOffset(time_of_microseconds(microseconds), 0 - seconds_west))
    _ -> Error(wrong_size(description, bytes))
  }
}

// --- timestamp and timestamptz ------------------------------------------------

/// `timestamp`, as `gleam_time`'s `Timestamp`, read as UTC. A value is
/// rounded to the nearest microsecond, as PostgreSQL stores it.
pub const timestamp =
  Codec(
    name: "timestamp",
    gleam_type: "Timestamp",
    format: cell.BinaryFormat,
    accepts: accepts_timestamp,
    encode: encode_timestamp,
    decode: decode_timestamp,
    placeholder: gleam_timestamp.unix_epoch,
  )

/// `timestamp`, as a `MaybeInfinite(Timestamp)`, which holds `infinity` too.
pub const timestamp_or_infinite =
  Codec(
    name: "timestamp or infinite",
    gleam_type: "MaybeInfinite(Timestamp)",
    format: cell.BinaryFormat,
    accepts: accepts_timestamp,
    encode: encode_infinite_timestamp,
    decode: decode_infinite_timestamp,
    placeholder: PositiveInfinity,
  )

/// `timestamptz`, as `gleam_time`'s `Timestamp`.
pub const timestamp_with_time_zone =
  Codec(
    name: "timestamp with time zone",
    gleam_type: "Timestamp",
    format: cell.BinaryFormat,
    accepts: accepts_timestamp_with_time_zone,
    encode: encode_timestamp,
    decode: decode_timestamp,
    placeholder: gleam_timestamp.unix_epoch,
  )

/// `timestamptz`, as a `MaybeInfinite(Timestamp)`.
pub const timestamp_with_time_zone_or_infinite =
  Codec(
    name: "timestamp with time zone or infinite",
    gleam_type: "MaybeInfinite(Timestamp)",
    format: cell.BinaryFormat,
    accepts: accepts_timestamp_with_time_zone,
    encode: encode_infinite_timestamp,
    decode: decode_infinite_timestamp,
    placeholder: PositiveInfinity,
  )

fn accepts_timestamp(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["timestamp"])
}

fn accepts_timestamp_with_time_zone(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["timestamptz"])
}

// A timestamp as microseconds since the epoch of PostgreSQL, rounded to the
// nearest microsecond. The two largest and smallest values mean infinity.
fn encode_timestamp(
  value: Timestamp,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let #(seconds, nanoseconds) =
    gleam_timestamp.to_unix_seconds_and_nanoseconds(value)
  let microseconds =
    { seconds - postgres_epoch_unix_seconds }
    * microseconds_per_second
    + round_to_microseconds(nanoseconds)
  case microseconds > int64_smallest && microseconds < int64_largest {
    True -> Ok(Binary(<<microseconds:size(64)>>))
    False -> Error("the timestamp is out of range for PostgreSQL")
  }
}

fn encode_infinite_timestamp(
  value: MaybeInfinite(Timestamp),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  case value {
    Finite(value:) -> encode_timestamp(value, description, lookup)
    PositiveInfinity -> Ok(Binary(<<int64_largest:size(64)>>))
    NegativeInfinity -> Ok(Binary(<<int64_smallest:size(64)>>))
  }
}

fn decode_timestamp(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Timestamp, DecodeIssue) {
  use microseconds <- result.try(int64_cell(value, description))
  case microseconds {
    9_223_372_036_854_775_807 -> Error(OutOfRange("infinity"))
    -9_223_372_036_854_775_808 -> Error(OutOfRange("-infinity"))
    _ -> Ok(timestamp_of_microseconds(microseconds))
  }
}

fn decode_infinite_timestamp(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(MaybeInfinite(Timestamp), DecodeIssue) {
  use microseconds <- result.try(int64_cell(value, description))
  case microseconds {
    9_223_372_036_854_775_807 -> Ok(PositiveInfinity)
    -9_223_372_036_854_775_808 -> Ok(NegativeInfinity)
    _ -> Ok(Finite(timestamp_of_microseconds(microseconds)))
  }
}

// Gleam's division rounds toward zero, so a time before the epoch moves
// one second down to keep the nanoseconds positive.
fn timestamp_of_microseconds(microseconds: Int) -> Timestamp {
  let whole_seconds = microseconds / microseconds_per_second
  let rest = microseconds % microseconds_per_second
  let #(seconds, positive_rest) = case rest < 0 {
    True -> #(whole_seconds - 1, rest + microseconds_per_second)
    False -> #(whole_seconds, rest)
  }
  gleam_timestamp.from_unix_seconds_and_nanoseconds(
    postgres_epoch_unix_seconds + seconds,
    positive_rest * 1000,
  )
}

// --- interval -----------------------------------------------------------------

/// `interval`, as an `Interval` of months, days and microseconds.
pub const interval =
  Codec(
    name: "interval",
    gleam_type: "Interval",
    format: cell.BinaryFormat,
    accepts: accepts_interval,
    encode: encode_interval,
    decode: decode_interval,
    placeholder: Interval(0, 0, 0),
  )

/// `interval`, as a `MaybeInfinite(Interval)`, for the infinite intervals of
/// PostgreSQL 17 and later. PostgreSQL 16 has no infinite interval: it
/// reads `PositiveInfinity` as the largest finite interval.
pub const interval_or_infinite =
  Codec(
    name: "interval or infinite",
    gleam_type: "MaybeInfinite(Interval)",
    format: cell.BinaryFormat,
    accepts: accepts_interval,
    encode: encode_infinite_interval,
    decode: decode_infinite_interval,
    placeholder: PositiveInfinity,
  )

fn accepts_interval(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["interval"])
}

fn encode_interval(
  value: Interval,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let Interval(months:, days:, microseconds:) = value
  // PostgreSQL 17 reads these two values as infinity and -infinity.
  case is_infinite_interval(months, days, microseconds) {
    True ->
      Error(
        "the interval of the largest or the smallest parts is infinite in PostgreSQL 17 and later; use interval_or_infinite",
      )
    False -> encode_finite_interval(months, days, microseconds)
  }
}

fn is_infinite_interval(months: Int, days: Int, microseconds: Int) -> Bool {
  {
    months == int32_largest
    && days == int32_largest
    && microseconds == int64_largest
  }
  || {
    months == int32_smallest
    && days == int32_smallest
    && microseconds == int64_smallest
  }
}

fn encode_finite_interval(
  months: Int,
  days: Int,
  microseconds: Int,
) -> Result(Cell, String) {
  case
    in_int32(months)
    && in_int32(days)
    && microseconds >= int64_smallest
    && microseconds <= int64_largest
  {
    True ->
      Ok(Binary(<<microseconds:size(64), days:size(32), months:size(32)>>))
    False -> Error("a part of the interval is out of range for PostgreSQL")
  }
}

fn decode_interval(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Interval, DecodeIssue) {
  use #(months, days, microseconds) <- result.try(interval_parts(
    value,
    description,
  ))
  finite_interval(months, days, microseconds)
}

fn interval_parts(
  value: Cell,
  description: TypeDescription,
) -> Result(#(Int, Int, Int), DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<
      microseconds:signed-size(64),
      days:signed-size(32),
      months:signed-size(32),
    >> -> Ok(#(months, days, microseconds))
    _ -> Error(wrong_size(description, bytes))
  }
}

fn finite_interval(
  months: Int,
  days: Int,
  microseconds: Int,
) -> Result(Interval, DecodeIssue) {
  case months, days, microseconds {
    2_147_483_647, 2_147_483_647, 9_223_372_036_854_775_807 ->
      Error(OutOfRange("infinity"))
    -2_147_483_648, -2_147_483_648, -9_223_372_036_854_775_808 ->
      Error(OutOfRange("-infinity"))
    _, _, _ -> Ok(Interval(months:, days:, microseconds:))
  }
}

// PostgreSQL 16 has no infinite interval: it reads these values as the
// largest and the smallest finite intervals.
fn encode_infinite_interval(
  value: MaybeInfinite(Interval),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  case value {
    Finite(value:) -> encode_interval(value, description, lookup)
    PositiveInfinity ->
      Ok(
        Binary(<<
          int64_largest:size(64),
          int32_largest:size(32),
          int32_largest:size(32),
        >>),
      )
    NegativeInfinity ->
      Ok(
        Binary(<<
          int64_smallest:size(64),
          int32_smallest:size(32),
          int32_smallest:size(32),
        >>),
      )
  }
}

fn decode_infinite_interval(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(MaybeInfinite(Interval), DecodeIssue) {
  use #(months, days, microseconds) <- result.try(interval_parts(
    value,
    description,
  ))
  case months, days, microseconds {
    2_147_483_647, 2_147_483_647, 9_223_372_036_854_775_807 ->
      Ok(PositiveInfinity)
    -2_147_483_648, -2_147_483_648, -9_223_372_036_854_775_808 ->
      Ok(NegativeInfinity)
    _, _, _ -> Ok(Finite(Interval(months:, days:, microseconds:)))
  }
}

// --- Helpers ------------------------------------------------------------------

fn in_int32(value: Int) -> Bool {
  value >= int32_smallest && value <= int32_largest
}

// Nanoseconds to the nearest microsecond, halves away from zero.
fn round_to_microseconds(nanoseconds: Int) -> Int {
  { nanoseconds + 500 } / 1000
}

fn int32_cell(
  value: Cell,
  description: TypeDescription,
) -> Result(Int, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<number:signed-size(32)>> -> Ok(number)
    _ -> Error(wrong_size(description, bytes))
  }
}

fn int64_cell(
  value: Cell,
  description: TypeDescription,
) -> Result(Int, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<number:signed-size(64)>> -> Ok(number)
    _ -> Error(wrong_size(description, bytes))
  }
}
