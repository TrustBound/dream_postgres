import dream_postgres/codec.{type Codec}
import dream_postgres/codecs/range.{type Range, range}
import dream_postgres/codecs/time.{date}
import gleam/time/calendar.{type Date}

/// A codec of `daterange`.
pub fn booking_period_codec() -> Codec(Range(Date)) {
  range(date)
}
