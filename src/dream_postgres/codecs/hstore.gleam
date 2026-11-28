//// The codec of the extension type `hstore`, in its binary format: the
//// number of pairs (32 bits), then each key and value as a length
//// (32 bits, -1 for a NULL value) and its bytes.
////
//// This module is internal to dream_postgres.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  utf8_bytes, wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// A function, not a constant: a constant cannot hold a Dict.
pub fn hstore() -> codec_type.Codec(Dict(String, Option(String))) {
  Codec(
    name: "hstore",
    gleam_type: "Dict(String, Option(String))",
    format: cell.BinaryFormat,
    accepts: accepts_hstore,
    encode: encode_hstore,
    decode: decode_hstore,
    placeholder: dict.new(),
  )
}

fn accepts_hstore(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["hstore"])
}

fn encode_hstore(
  value: Dict(String, Option(String)),
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let pairs = dict.to_list(value)
  let body =
    list.fold(pairs, <<>>, fn(bytes, pair) {
      let #(key, text) = pair
      let key_bytes = bit_array.from_string(key)
      let value_bytes = case text {
        Some(present) -> {
          let present_bytes = bit_array.from_string(present)
          <<
            { bit_array.byte_size(present_bytes) }:size(32),
            present_bytes:bits,
          >>
        }
        None -> <<-1:size(32)>>
      }
      <<
        bytes:bits,
        { bit_array.byte_size(key_bytes) }:size(32),
        key_bytes:bits,
        value_bytes:bits,
      >>
    })
  Ok(Binary(<<{ list.length(pairs) }:size(32), body:bits>>))
}

fn decode_hstore(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Dict(String, Option(String)), DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<count:size(32), pairs:bits>> -> decode_pairs(pairs, count, dict.new())
    _ -> Error(wrong_size(description, bytes))
  }
}

fn decode_pairs(
  bytes: BitArray,
  remaining: Int,
  pairs: Dict(String, Option(String)),
) -> Result(Dict(String, Option(String)), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(pairs)
    0, _ -> Error(Malformed("the hstore has bytes after its last pair"))
    _,
      <<
        key_length:size(32),
        key:bytes-size(key_length),
        -1:signed-size(32),
        rest:bits,
      >>
    -> {
      use key_text <- result.try(utf8_bytes(key))
      decode_pairs(rest, remaining - 1, dict.insert(pairs, key_text, None))
    }
    _,
      <<
        key_length:size(32),
        key:bytes-size(key_length),
        value_length:size(32),
        text:bytes-size(value_length),
        rest:bits,
      >>
    -> {
      use key_text <- result.try(utf8_bytes(key))
      use value_text <- result.try(utf8_bytes(text))
      decode_pairs(
        rest,
        remaining - 1,
        dict.insert(pairs, key_text, Some(value_text)),
      )
    }
    _, _ -> Error(Malformed("the hstore's pairs are cut short"))
  }
}
