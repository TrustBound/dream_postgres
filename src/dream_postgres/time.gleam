//// The Gleam values of PostgreSQL's time types that `gleam_time` does not
//// have. Dates, times of day and timestamps use `gleam_time`'s own types.

import gleam/time/calendar.{type TimeOfDay}

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
