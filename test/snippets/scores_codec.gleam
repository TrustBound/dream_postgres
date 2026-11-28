import dream_postgres/codecs.{type Codec, int, nullable}
import dream_postgres/codecs/array.{array}
import gleam/option.{type Option}

/// A codec of `int4[]` whose elements can be NULL.
pub fn scores_codec() -> Codec(List(Option(Int))) {
  array(nullable(int))
}
