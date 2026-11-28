import dream_postgres/codec.{type Codec, custom}
import gleam/list
import gleam/string

/// A path of the ltree extension, such as `top.science.physics`.
pub type Path {
  Path(labels: List(String))
}

pub fn ltree_codec() -> Codec(Path) {
  custom(
    type_name: "ltree",
    to_text: path_to_string,
    from_text: path_from_string,
    placeholder: Path([]),
  )
}

fn path_to_string(path: Path) -> String {
  string.join(path.labels, ".")
}

fn path_from_string(text: String) -> Result(Path, String) {
  let labels = string.split(text, ".")
  case list.contains(labels, "") {
    True -> Error("an ltree path has an empty label: " <> text)
    False -> Ok(Path(labels))
  }
}
