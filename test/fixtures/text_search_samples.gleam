//// Text search vectors and queries, and their bytes in PostgreSQL's binary
//// formats.

import dream_postgres/text_search.{
  type TsQuery, And, Not, Or, Phrase, Term, WeightA, WeightB, WeightC, WeightD,
}

/// The bytes of the text search vector `'cat':1A,3 'dog'`.
///
/// ## Example
///
/// ```gleam
/// Binary(text_search_samples.cat_and_dog_vector_bytes())
/// ```
pub fn cat_and_dog_vector_bytes() -> BitArray {
  <<
    2:size(32),
    "cat":utf8,
    0,
    2:size(16),
    0xC001:size(16),
    0x0003:size(16),
    "dog":utf8,
    0,
    0:size(16),
  >>
}

/// The bytes of the text search vector `'cat':1B,16383C`.
///
/// ## Example
///
/// ```gleam
/// Binary(text_search_samples.weights_b_and_c_vector_bytes())
/// ```
pub fn weights_b_and_c_vector_bytes() -> BitArray {
  <<
    1:size(32),
    "cat":utf8,
    0,
    2:size(16),
    0x8001:size(16),
    0x7FFF:size(16),
  >>
}

/// The text search query `cat & (dog:AC* | !fox)`.
///
/// ## Example
///
/// ```gleam
/// text_search_samples.query()
/// ```
pub fn query() -> TsQuery {
  And(
    Term("cat", [], False),
    Or(Term("dog", [WeightA, WeightC], True), Not(Term("fox", [], False))),
  )
}

/// The bytes of the text search query of `query`.
///
/// ## Example
///
/// ```gleam
/// Binary(text_search_samples.query_bytes())
/// ```
pub fn query_bytes() -> BitArray {
  <<
    6:size(32),
    2,
    2,
    2,
    3,
    2,
    1,
    1,
    0,
    0,
    "fox":utf8,
    0,
    1,
    10,
    1,
    "dog":utf8,
    0,
    1,
    0,
    0,
    "cat":utf8,
    0,
  >>
}

/// The text search query `a:ABCD <2> b:B`.
///
/// ## Example
///
/// ```gleam
/// text_search_samples.phrase()
/// ```
pub fn phrase() -> TsQuery {
  Phrase(
    2,
    Term("a", [WeightA, WeightB, WeightC, WeightD], False),
    Term("b", [WeightB], False),
  )
}

/// The bytes of the text search query of `phrase`.
///
/// ## Example
///
/// ```gleam
/// Binary(text_search_samples.phrase_bytes())
/// ```
pub fn phrase_bytes() -> BitArray {
  <<
    3:size(32),
    2,
    4,
    2:size(16),
    1,
    4,
    0,
    "b":utf8,
    0,
    1,
    15,
    0,
    "a":utf8,
    0,
  >>
}
