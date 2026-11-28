//// The Gleam values of the pgvector extension's types: `vector`,
//// `halfvec` and `sparsevec`. Each type is opaque, so a value always holds
//// what pgvector takes: from 1 to 16000 dimensions of finite floats.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result

/// A `vector`: floats of 4 bytes.
pub opaque type Vector {
  Vector(floats: BitArray)
}

/// A `halfvec`: floats of 2 bytes.
pub opaque type HalfVector {
  HalfVector(floats: BitArray)
}

/// A `sparsevec`: the dimensions, and the elements that are not zero.
pub opaque type SparseVector {
  SparseVector(dimensions: Int, indices: BitArray, floats: BitArray)
}

/// Why a list of floats is not a `vector` or a `halfvec`.
pub type VectorError {
  NoDimensions
  TooManyDimensions(dimensions: Int, maximum: Int)
  FloatTooLarge(position: Int, value: Float, maximum: Float)
}

/// Why a dict is not a `sparsevec`.
pub type SparseVectorError {
  DimensionsOutOfRange(dimensions: Int, maximum: Int)
  IndexOutOfRange(index: Int, dimensions: Int)
  ElementTooLarge(index: Int, value: Float, maximum: Float)
  TooManyElements(count: Int, maximum: Int)
}

const max_vector_dimensions = 16_000

const max_sparse_dimensions = 1_000_000_000

const max_sparse_elements = 16_000

const max_float4 = 3.4028234663852886e38

const max_float2 = 65_504.0

/// A vector of the floats, each rounded to the nearest float of 4 bytes.
pub fn list_to_vector(floats: List(Float)) -> Result(Vector, VectorError) {
  pack_floats(floats, FourBytes, max_float4)
  |> result.map(Vector)
}

/// The floats of a vector, in order.
pub fn vector_to_list(vector: Vector) -> List(Float) {
  unpack_floats(vector.floats, FourBytes, [])
}

/// The number of dimensions of a vector.
pub fn vector_dimensions(vector: Vector) -> Int {
  bit_array.byte_size(vector.floats) / 4
}

/// A half vector of the floats, each rounded to the nearest float of 2
/// bytes.
pub fn list_to_half_vector(
  floats: List(Float),
) -> Result(HalfVector, VectorError) {
  pack_floats(floats, TwoBytes, max_float2)
  |> result.map(HalfVector)
}

/// The floats of a half vector, in order.
pub fn half_vector_to_list(vector: HalfVector) -> List(Float) {
  unpack_floats(vector.floats, TwoBytes, [])
}

/// The number of dimensions of a half vector.
pub fn half_vector_dimensions(vector: HalfVector) -> Int {
  bit_array.byte_size(vector.floats) / 2
}

/// A sparse vector of `dimensions`, with the elements of the dict at their
/// 0-based indices. An element of zero is left out, as pgvector does.
pub fn dict_to_sparse_vector(
  dimensions: Int,
  elements: Dict(Int, Float),
) -> Result(SparseVector, SparseVectorError) {
  case dimensions < 1 || dimensions > max_sparse_dimensions {
    True -> Error(DimensionsOutOfRange(dimensions, max_sparse_dimensions))
    False -> pack_sparse(dimensions, elements)
  }
}

fn pack_sparse(
  dimensions: Int,
  elements: Dict(Int, Float),
) -> Result(SparseVector, SparseVectorError) {
  use #(count, indices, floats) <- result.try(
    dict.to_list(elements)
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.try_fold(#(0, <<>>, <<>>), fn(packed, element) {
      let #(count, indices, floats) = packed
      let #(index, value) = element
      case index < 0 || index >= dimensions, float_bits(value, FourBytes) {
        True, _ -> Error(IndexOutOfRange(index, dimensions))
        False, Error(Nil) -> Error(ElementTooLarge(index, value, max_float4))
        // 0.0 and -0.0
        False, Ok(<<_:1, 0:31>>) -> Ok(packed)
        False, Ok(bits) ->
          Ok(
            #(count + 1, <<indices:bits, index:32>>, <<floats:bits, bits:bits>>),
          )
      }
    }),
  )
  case count > max_sparse_elements {
    True -> Error(TooManyElements(count, max_sparse_elements))
    False -> Ok(SparseVector(dimensions, indices, floats))
  }
}

/// The elements of a sparse vector that are not zero, by 0-based index.
pub fn sparse_vector_to_dict(vector: SparseVector) -> Dict(Int, Float) {
  list.zip(
    unpack_indices(vector.indices, []),
    unpack_floats(vector.floats, FourBytes, []),
  )
  |> dict.from_list
}

/// The number of dimensions of a sparse vector.
pub fn sparse_vector_dimensions(vector: SparseVector) -> Int {
  vector.dimensions
}

// --- The binary forms, for the codecs ---------------------------------------

/// The floats of a vector, 4 bytes each.
@internal
pub fn vector_bytes(vector: Vector) -> BitArray {
  vector.floats
}

/// The vector of packed floats of 4 bytes, if each is finite.
@internal
pub fn vector_of_bytes(floats: BitArray) -> Result(Vector, Nil) {
  check_floats(floats, FourBytes) |> result.replace(Vector(floats))
}

/// The floats of a half vector, 2 bytes each.
@internal
pub fn half_vector_bytes(vector: HalfVector) -> BitArray {
  vector.floats
}

/// The half vector of packed floats of 2 bytes, if each is finite.
@internal
pub fn half_vector_of_bytes(floats: BitArray) -> Result(HalfVector, Nil) {
  check_floats(floats, TwoBytes) |> result.replace(HalfVector(floats))
}

/// The dimensions, the indices (4 bytes each) and the floats (4 bytes
/// each) of a sparse vector.
@internal
pub fn sparse_vector_parts(vector: SparseVector) -> #(Int, BitArray, BitArray) {
  #(vector.dimensions, vector.indices, vector.floats)
}

/// The sparse vector of its parts, if the indices go up and are less than
/// the dimensions, and the floats are finite.
@internal
pub fn sparse_vector_of_parts(
  dimensions: Int,
  indices: BitArray,
  floats: BitArray,
) -> Result(SparseVector, Nil) {
  use Nil <- result.try(check_indices(indices, -1, dimensions))
  check_floats(floats, FourBytes)
  |> result.replace(SparseVector(dimensions, indices, floats))
}

fn check_indices(
  bits: BitArray,
  previous: Int,
  dimensions: Int,
) -> Result(Nil, Nil) {
  case bits {
    <<>> -> Ok(Nil)
    <<index:size(32), rest:bits>> if index > previous && index < dimensions ->
      check_indices(rest, index, dimensions)
    _ -> Error(Nil)
  }
}

// --- Helpers -----------------------------------------------------------------

type FloatSize {
  TwoBytes
  FourBytes
}

fn pack_floats(
  floats: List(Float),
  size: FloatSize,
  maximum: Float,
) -> Result(BitArray, VectorError) {
  let dimensions = list.length(floats)
  case dimensions {
    0 -> Error(NoDimensions)
    _ if dimensions > max_vector_dimensions ->
      Error(TooManyDimensions(dimensions, max_vector_dimensions))
    _ ->
      list.index_fold(floats, Ok(<<>>), fn(packed, value, position) {
        use packed <- result.try(packed)
        append_float(packed, value, position, size, maximum)
      })
  }
}

fn append_float(
  packed: BitArray,
  value: Float,
  position: Int,
  size: FloatSize,
  maximum: Float,
) -> Result(BitArray, VectorError) {
  case float_bits(value, size) {
    Ok(bits) -> Ok(<<packed:bits, bits:bits>>)
    Error(Nil) -> Error(FloatTooLarge(position, value, maximum))
  }
}

// The float as a float of `size`, rounded to the nearest one. A float
// larger than the largest finite float of `size` is an error, as pgvector
// refuses it. A Gleam float on the BEAM is never NaN or infinity.
fn float_bits(value: Float, size: FloatSize) -> Result(BitArray, Nil) {
  case size, value >. max_float2 || value <. 0.0 -. max_float2 {
    TwoBytes, True -> Error(Nil)
    TwoBytes, False -> Ok(<<value:float-size(16)>>)
    FourBytes, _ -> four_byte_float_bits(value)
  }
}

fn four_byte_float_bits(value: Float) -> Result(BitArray, Nil) {
  case value >. max_float4 || value <. 0.0 -. max_float4 {
    True -> Error(Nil)
    False -> Ok(<<value:float-size(32)>>)
  }
}

fn check_floats(bits: BitArray, size: FloatSize) -> Result(Nil, Nil) {
  case size, bits {
    _, <<>> -> Ok(Nil)
    TwoBytes, <<_:float-size(16), rest:bits>> -> check_floats(rest, size)
    FourBytes, <<_:float-size(32), rest:bits>> -> check_floats(rest, size)
    TwoBytes, _ | FourBytes, _ -> Error(Nil)
  }
}

fn unpack_floats(
  bits: BitArray,
  size: FloatSize,
  floats: List(Float),
) -> List(Float) {
  case size, bits {
    TwoBytes, <<value:float-size(16), rest:bits>>
    | FourBytes, <<value:float-size(32), rest:bits>>
    -> unpack_floats(rest, size, [value, ..floats])
    TwoBytes, _ | FourBytes, _ -> list.reverse(floats)
  }
}

fn unpack_indices(bits: BitArray, indices: List(Int)) -> List(Int) {
  case bits {
    <<index:32, rest:bits>> -> unpack_indices(rest, [index, ..indices])
    _ -> list.reverse(indices)
  }
}

/// The vector `[0]`, the codec's placeholder.
@internal
pub const placeholder_vector = Vector(<<0:size(32)>>)

/// The half vector `[0]`, the codec's placeholder.
@internal
pub const placeholder_half_vector = HalfVector(<<0:size(16)>>)

/// The sparse vector of 1 dimension and no elements, the codec's
/// placeholder.
@internal
pub const placeholder_sparse_vector = SparseVector(1, <<>>, <<>>)
