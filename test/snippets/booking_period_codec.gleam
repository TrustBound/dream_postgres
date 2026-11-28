import dream_postgres/codec.{type Codec, date, range}
import dream_postgres/range.{type Range}
import gleam/time/calendar.{type Date}

/// A codec of `daterange`.
pub fn booking_period_codec() -> Codec(Range(Date)) {
  range(date)
}
