import dream_postgres/codecs.{type Codec, custom}
import gleam/string

/// A path of the extension type `ltree`, such as `shop.books.poetry`.
pub type CategoryPath {
  CategoryPath(labels: List(String))
}

/// Writes and reads an `ltree` value as its text.
pub fn category_path_codec() -> Codec(CategoryPath) {
  custom(
    type_name: "ltree",
    to_text: category_path_to_text,
    from_text: category_path_from_text,
    placeholder: CategoryPath(labels: []),
  )
}

fn category_path_to_text(path: CategoryPath) -> String {
  string.join(path.labels, with: ".")
}

fn category_path_from_text(text: String) -> Result(CategoryPath, String) {
  Ok(CategoryPath(labels: string.split(text, on: ".")))
}
