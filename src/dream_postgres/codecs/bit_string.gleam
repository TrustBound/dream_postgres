//// The codec of `bit` and `varbit`, in PostgreSQL's binary format: the
//// number of bits (32 bits), then the bits, padded with zeros to whole bytes.
////
//// This module is internal to dream_postgres.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/bit_array
import gleam/result

pub const bit_string =
  Codec(
    name: "bit string",
    gleam_type: "BitArray",
    format: cell.BinaryFormat,
    accepts: accepts_bit_string,
    encode: encode_bit_string,
    decode: decode_bit_string,
    placeholder: <<>>,
  )

fn accepts_bit_string(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["bit", "varbit"])
}

fn encode_bit_string(
  value: BitArray,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let length = bit_array.bit_size(value)
  let padding = { 8 - length % 8 } % 8
  Ok(Binary(<<length:size(32), value:bits, 0:size(padding)>>))
}

fn decode_bit_string(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(BitArray, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<length:size(32), rest:bits>> -> take_bit_string(rest, length)
    _ -> Error(wrong_size(description, bytes))
  }
}

fn take_bit_string(
  rest: BitArray,
  length: Int,
) -> Result(BitArray, DecodeIssue) {
  case rest {
    <<bits:bits-size(length), _padding:bits>> -> Ok(bits)
    _ -> Error(Malformed("the bit string is shorter than its length"))
  }
}
