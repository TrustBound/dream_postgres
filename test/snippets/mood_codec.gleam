import dream_postgres/codec.{type Codec, enum}

/// The values of the PostgreSQL enum
/// `CREATE TYPE mood AS ENUM ('happy', 'sad')`.
pub type Mood {
  Happy
  Sad
}

/// Every label of the enum, each with its value.
pub fn mood_codec() -> Codec(Mood) {
  enum("mood", #(Happy, "happy"), [#(Sad, "sad")])
}
