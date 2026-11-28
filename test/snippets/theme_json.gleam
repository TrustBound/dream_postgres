import dream_postgres/json.{type Json, decode_json, gleam_json_to_json}
import gleam/dynamic/decode
import gleam/json as gleam_json

pub type Theme {
  Theme(dark: Bool, font_size: Int)
}

/// The theme as a JSON document, for a `json` or a `jsonb` parameter.
pub fn theme_document(theme: Theme) -> Json {
  gleam_json.object([
    #("dark", gleam_json.bool(theme.dark)),
    #("font_size", gleam_json.int(theme.font_size)),
  ])
  |> gleam_json_to_json
}

/// The theme of a JSON document that a `json` or a `jsonb` column gave.
pub fn theme_from_document(
  document: Json,
) -> Result(Theme, gleam_json.DecodeError) {
  decode_json(document, theme_decoder())
}

fn theme_decoder() -> decode.Decoder(Theme) {
  use dark <- decode.field("dark", decode.bool)
  use font_size <- decode.field("font_size", decode.int)
  decode.success(Theme(dark:, font_size:))
}
