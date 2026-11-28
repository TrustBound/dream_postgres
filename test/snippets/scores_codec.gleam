import dream_postgres/codec.{type Codec, array, int, nullable}
import gleam/option.{type Option}

/// A codec of `int4[]` whose elements can be NULL.
pub fn scores_codec() -> Codec(List(Option(Int))) {
  array(nullable(int))
}
