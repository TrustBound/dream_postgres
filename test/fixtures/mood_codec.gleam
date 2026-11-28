//// An enum codec for the enum type `mood` of the test catalog.

import dream_postgres/codec.{type Codec}

/// A mood. `Angry` has no label in the codec, so the codec cannot write it.
pub type Mood {
  Happy
  Sad
  Angry
}

/// A codec for the enum `mood`, with the labels `happy` and `sad`.
///
/// ## Example
///
/// ```gleam
/// Sad
/// |> should
/// |> encode_as(mood_codec(), type_catalog.mood())
/// ```
pub fn mood_codec() -> Codec(Mood) {
  codec.enum("mood", #(Happy, "happy"), [#(Sad, "sad")])
}
