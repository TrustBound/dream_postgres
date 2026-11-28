//// The Gleam value of PostgreSQL's `tid`: where a row version is stored.
////
//// In PostgreSQL's binary format: the block number (32 bits), then the
//// offset (16 bits).

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, binary_bytes, is_base, wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/int
import gleam/result

/// A row version's place: its block number (0 to 4294967295) and its
/// position in the block (0 to 65535).
pub type Tid {
  Tid(block: Int, offset: Int)
}

// --- Codecs ---------------------------------------------------------------------

/// `tid`, as a `Tid`.
pub const tid =
  Codec(
    name: "tid",
    gleam_type: "Tid",
    format: cell.BinaryFormat,
    accepts: accepts_tid,
    encode: encode_tid,
    decode: decode_tid,
    placeholder: Tid(0, 0),
  )

fn accepts_tid(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["tid"])
}

fn encode_tid(
  value: Tid,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let Tid(block:, offset:) = value
  case block >= 0 && block <= 4_294_967_295 && offset >= 0 && offset <= 65_535 {
    True -> Ok(Binary(<<block:size(32), offset:size(16)>>))
    False ->
      Error(
        "("
        <> int.to_string(block)
        <> ","
        <> int.to_string(offset)
        <> ") is out of range for tid",
      )
  }
}

fn decode_tid(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Tid, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<block:size(32), offset:size(16)>> -> Ok(Tid(block:, offset:))
    _ -> Error(wrong_size(description, bytes))
  }
}
