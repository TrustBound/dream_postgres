//// The Gleam values of PostgreSQL's full text search types: `tsvector`
//// and `tsquery`.

/// The weight of a lexeme's position. `D` is the default.
pub type Weight {
  WeightA
  WeightB
  WeightC
  WeightD
}

/// A lexeme of a `tsvector`, with its positions (1 to 16383) and their
/// weights.
pub type Lexeme {
  Lexeme(word: String, positions: List(#(Int, Weight)))
}

/// A `tsvector`: its lexemes, in PostgreSQL's order.
pub type TsVector =
  List(Lexeme)

/// A `tsquery`.
pub type TsQuery {
  /// The query of no terms, which PostgreSQL makes from a text with no
  /// lexemes.
  EmptyQuery
  /// A word, with the weights it must have (none for any weight), and
  /// whether it matches as a prefix (`word:*`).
  Term(word: String, weights: List(Weight), prefix: Bool)
  Not(TsQuery)
  And(TsQuery, TsQuery)
  Or(TsQuery, TsQuery)
  /// `left <distance> right`: `right` follows `left` at `distance`.
  Phrase(distance: Int, left: TsQuery, right: TsQuery)
}
