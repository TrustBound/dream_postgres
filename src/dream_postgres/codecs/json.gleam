//// A JSON document, as PostgreSQL stores it in a `json` or `jsonb` column.
////
//// The type is opaque, so a value of it always holds valid JSON: it is made
//// from a `gleam/json` value, or from a text that parses.
////
//// `json` and `jsonb` are the codecs of the two column types.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  utf8_bytes, utf8_text, wrong_size,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Binary, BinaryFormat,
}
import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/json as gleam_json
import gleam/result

/// A valid JSON document.
pub opaque type Json {
  Json(text: String)
}

/// The JSON document `null`.
pub const null = Json("null")

/// The document of a `gleam/json` value.
pub fn from_json(value: gleam_json.Json) -> Json {
  Json(gleam_json.to_string(value))
}

/// The document of a text, if the text is valid JSON.
pub fn from_string(text: String) -> Result(Json, gleam_json.DecodeError) {
  gleam_json.parse(text, decode.dynamic)
  |> result.replace(Json(text))
}

/// The text of a document.
pub fn to_string(value: Json) -> String {
  value.text
}

/// Decodes a document with a `gleam/dynamic/decode` decoder.
pub fn parse(
  value: Json,
  decoder: Decoder(a),
) -> Result(a, gleam_json.DecodeError) {
  gleam_json.parse(value.text, decoder)
}

// --- Codecs ---------------------------------------------------------------------

/// `json`, as a valid `Json` document.
pub const json =
  Codec(
    name: "json",
    gleam_type: "Json",
    format: BinaryFormat,
    accepts: accepts_json,
    encode: encode_json,
    decode: decode_json,
    placeholder: placeholder_json,
  )

/// `jsonb`, as a valid `Json` document.
pub const jsonb =
  Codec(
    name: "jsonb",
    gleam_type: "Json",
    format: BinaryFormat,
    accepts: accepts_jsonb,
    encode: encode_jsonb,
    decode: decode_jsonb,
    placeholder: placeholder_json,
  )

const placeholder_json = null

fn accepts_json(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["json"])
}

fn encode_json(
  value: Json,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(bit_array.from_string(to_string(value))))
}

fn decode_json(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Json, DecodeIssue) {
  use text <- result.try(utf8_text(value))
  parse_json(text)
}

fn accepts_jsonb(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["jsonb"])
}

// The binary form of jsonb is a version byte, 1, then the text.
fn encode_jsonb(
  value: Json,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(<<1, to_string(value):utf8>>))
}

fn decode_jsonb(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Json, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<1, text_bytes:bits>> -> {
      use text <- result.try(utf8_bytes(text_bytes))
      parse_json(text)
    }
    _ -> Error(wrong_size(description, bytes))
  }
}

fn parse_json(text: String) -> Result(Json, DecodeIssue) {
  from_string(text)
  |> result.replace_error(Malformed("the server sent text that is not JSON"))
}
