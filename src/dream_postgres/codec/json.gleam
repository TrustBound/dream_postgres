//// The codecs of `json` and `jsonb`. The binary form of `jsonb` is a version
//// byte, 1, then the text.
////
//// This module is internal to dream_postgres.

import dream_postgres/codec/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  utf8_bytes, utf8_text, wrong_size,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Binary, BinaryFormat,
}
import dream_postgres/json.{type Json}
import gleam/bit_array
import gleam/result

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

const placeholder_json = json.null

fn accepts_json(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["json"])
}

fn encode_json(
  value: Json,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(bit_array.from_string(json.json_to_string(value))))
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
  Ok(Binary(<<1, json.json_to_string(value):utf8>>))
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
  json.parse_json(text)
  |> result.replace_error(Malformed("the server sent text that is not JSON"))
}
