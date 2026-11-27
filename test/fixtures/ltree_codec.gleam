//// A custom codec for the extension type `ltree`, in the text format.

import dream_postgres/codec.{type Codec}

/// A codec that writes and reads an `ltree` path as its text. It refuses
/// the text `bad` with the error `not an ltree`, so that tests can see the
/// parser's error.
///
/// ## Example
///
/// ```gleam
/// "a.b"
/// |> should
/// |> encode_as(ltree_codec.ltree_codec(), type_catalog.ltree())
/// ```
pub fn ltree_codec() -> Codec(String) {
  codec.custom(
    type_name: "ltree",
    to_text: fn(path) { path },
    from_text: read_path,
    placeholder: "",
  )
}

fn read_path(text: String) -> Result(String, String) {
  case text {
    "bad" -> Error("not an ltree")
    _ -> Ok(text)
  }
}
