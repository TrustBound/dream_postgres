//// A custom text codec for the `ltree` type of the test catalog, which
//// refuses the text `bad`.

import dream_postgres/codecs.{type Codec}

/// A codec of `ltree` that keeps the text as it is, and refuses the text
/// `bad` with the reason `not an ltree`.
///
/// ## Example
///
/// ```gleam
/// codec.range(path_codec.path())
/// ```
pub fn path() -> Codec(String) {
  codecs.custom(
    type_name: "ltree",
    to_text: fn(text) { text },
    from_text: fn(text) {
      case text {
        "bad" -> Error("not an ltree")
        _ -> Ok(text)
      }
    },
    placeholder: "",
  )
}
