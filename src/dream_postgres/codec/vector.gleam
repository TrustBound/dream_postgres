//// The codecs of the pgvector types, in pgvector's binary formats:
////
//// - `vector`: the dimensions (16 bits), 16 unused bits, then a float4
////   for each dimension.
//// - `halfvec`: the same, with a float2 for each dimension.
//// - `sparsevec`: the dimensions, the number of elements and 32 unused
////   bits (32 bits each), then the 0-based index of each element (32 bits
////   each), then a float4 for each element.

import dream_postgres/codec/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import dream_postgres/vector.{type HalfVector, type SparseVector, type Vector}
import gleam/bit_array
import gleam/result

pub const vector =
  Codec(
    name: "vector",
    gleam_type: "Vector",
    format: cell.BinaryFormat,
    accepts: accepts_vector,
    encode: encode_vector,
    decode: decode_vector,
    placeholder: placeholder_vector,
  )

const placeholder_vector = vector.placeholder_vector

pub const half_vector =
  Codec(
    name: "half vector",
    gleam_type: "HalfVector",
    format: cell.BinaryFormat,
    accepts: accepts_half_vector,
    encode: encode_half_vector,
    decode: decode_half_vector,
    placeholder: placeholder_half_vector,
  )

const placeholder_half_vector = vector.placeholder_half_vector

pub const sparse_vector =
  Codec(
    name: "sparse vector",
    gleam_type: "SparseVector",
    format: cell.BinaryFormat,
    accepts: accepts_sparse_vector,
    encode: encode_sparse_vector,
    decode: decode_sparse_vector,
    placeholder: placeholder_sparse_vector,
  )

const placeholder_sparse_vector = vector.placeholder_sparse_vector

// --- accepts -------------------------------------------------------------------

fn accepts_vector(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["vector"])
}

fn accepts_half_vector(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["halfvec"])
}

fn accepts_sparse_vector(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["sparsevec"])
}

// --- encode --------------------------------------------------------------------

// The value types hold only what pgvector takes, so an encode never fails.

fn encode_vector(
  value: Vector,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let floats = vector.vector_bytes(value)
  Ok(
    Binary(<<
      { bit_array.byte_size(floats) / 4 }:size(16),
      0:size(16),
      floats:bits,
    >>),
  )
}

fn encode_half_vector(
  value: HalfVector,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let floats = vector.half_vector_bytes(value)
  Ok(
    Binary(<<
      { bit_array.byte_size(floats) / 2 }:size(16),
      0:size(16),
      floats:bits,
    >>),
  )
}

fn encode_sparse_vector(
  value: SparseVector,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let #(dimensions, indices, floats) = vector.sparse_vector_parts(value)
  Ok(
    Binary(<<
      dimensions:size(32),
      { bit_array.byte_size(floats) / 4 }:size(32),
      0:size(32),
      indices:bits,
      floats:bits,
    >>),
  )
}

// --- decode --------------------------------------------------------------------

fn decode_vector(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Vector, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<dimensions:size(16), _unused:size(16), floats:bytes-size(dimensions * 4)>>
      if dimensions > 0
    ->
      vector.vector_of_bytes(floats)
      |> result.replace_error(Malformed(
        "the vector holds a float that is not finite",
      ))
    _ -> Error(Malformed("the vector's dimensions do not match its floats"))
  }
}

fn decode_half_vector(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(HalfVector, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<dimensions:size(16), _unused:size(16), floats:bytes-size(dimensions * 2)>>
      if dimensions > 0
    ->
      vector.half_vector_of_bytes(floats)
      |> result.replace_error(Malformed(
        "the half vector holds a float that is not finite",
      ))
    _ ->
      Error(Malformed("the half vector's dimensions do not match its floats"))
  }
}

fn decode_sparse_vector(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(SparseVector, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<
      dimensions:size(32),
      count:size(32),
      _unused:size(32),
      indices:bytes-size(count * 4),
      floats:bytes-size(count * 4),
    >>
      if dimensions > 0
    ->
      vector.sparse_vector_of_parts(dimensions, indices, floats)
      |> result.replace_error(Malformed(
        "the sparse vector holds an index out of order or out of range, or a float that is not finite",
      ))
    _ -> Error(Malformed("the sparse vector's sizes do not match its elements"))
  }
}
