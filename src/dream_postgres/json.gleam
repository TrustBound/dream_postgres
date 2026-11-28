//// A JSON document, as PostgreSQL stores it in a `json` or `jsonb` column.
////
//// The type is opaque, so a value of it always holds valid JSON: it is made
//// from a `gleam/json` value, or from a text that parses.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/result

/// A valid JSON document.
pub opaque type Json {
  Json(text: String)
}

/// The JSON document `null`.
pub const null = Json("null")

/// The document of a `gleam/json` value.
pub fn gleam_json_to_json(value: json.Json) -> Json {
  Json(json.to_string(value))
}

/// The document of a text, if the text is valid JSON.
pub fn parse_json(text: String) -> Result(Json, json.DecodeError) {
  json.parse(text, decode.dynamic)
  |> result.replace(Json(text))
}

/// The text of a document.
pub fn json_to_string(value: Json) -> String {
  value.text
}

/// Decodes a document with a `gleam/dynamic/decode` decoder.
pub fn decode_json(
  value: Json,
  decoder: Decoder(a),
) -> Result(a, json.DecodeError) {
  json.parse(value.text, decoder)
}
