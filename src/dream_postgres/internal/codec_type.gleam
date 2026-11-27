//// The codec type and its helpers, for the modules of dream_postgres that
//// define codecs. An app uses `dream_postgres/codec` and never this module.

import dream_postgres/internal/cell.{
  type Cell, type Format, type TypeDescription, Array, Base, Binary, Composite,
  Domain, Enum, Multirange, Null, Pseudo, Range, Text,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

/// Finds what a type OID is. dream_postgres gives each codec a lookup on
/// the type catalog of the connection, so a codec of an array, a range or a
/// composite can find the types of its parts.
pub type TypeLookup =
  fn(Int) -> Result(TypeDescription, Nil)

/// Why a codec could not read a value.
pub type DecodeIssue {
  /// The value is NULL, and the codec does not take NULL.
  NullValue
  /// The value is valid, and the codec's Gleam type cannot hold it, for
  /// example `infinity` for a finite timestamp, or `NaN` for a `Float`.
  OutOfRange(value: String)
  /// The bytes are not a valid value of the type.
  Malformed(reason: String)
}

/// A codec of the Gleam type `a`.
pub type Codec(a) {
  Codec(
    /// The codec's name in error messages, for example `int` or
    /// `array of text`.
    name: String,
    /// The Gleam type, as code, for example `Int` or `List(String)`.
    gleam_type: String,
    /// The wire format that the codec reads and writes.
    format: Format,
    /// Whether the codec takes a type. Domains are resolved before.
    accepts: fn(TypeDescription, TypeLookup) -> Bool,
    /// Writes a value for a parameter of the given type.
    encode: fn(a, TypeDescription, TypeLookup) -> Result(Cell, String),
    /// Reads a cell of a column of the given type.
    decode: fn(Cell, TypeDescription, TypeLookup) -> Result(a, DecodeIssue),
    /// A value of the type, for the pass that lists a row reader's codecs.
    placeholder: a,
  )
}

// --- Internal access for the rest of the package ----------------------------

/// The codec's name in error messages.
pub fn name(codec: Codec(a)) -> String {
  codec.name
}

/// The Gleam type of the codec, as code.
pub fn gleam_type(codec: Codec(a)) -> String {
  codec.gleam_type
}

/// The wire format of the codec.
pub fn format(codec: Codec(a)) -> Format {
  codec.format
}

/// The placeholder value of the codec.
pub fn placeholder(codec: Codec(a)) -> a {
  codec.placeholder
}

/// Whether the codec takes a type, after its domains are resolved.
pub fn accepts(
  codec: Codec(a),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Bool {
  codec.accepts(resolve_domain(description, lookup), lookup)
}

/// Writes a value for a parameter of a type.
pub fn encode(
  codec: Codec(a),
  value: a,
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  codec.encode(value, resolve_domain(description, lookup), lookup)
}

/// Reads a cell of a column of a type.
pub fn decode(
  codec: Codec(a),
  value: Cell,
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(a, DecodeIssue) {
  codec.decode(value, resolve_domain(description, lookup), lookup)
}

// A domain reads and writes as its base type. A domain whose base cannot
// be found stays a domain, which no codec takes.
fn resolve_domain(
  description: TypeDescription,
  lookup: TypeLookup,
) -> TypeDescription {
  case description.kind {
    Domain(base_type_id:) ->
      case lookup(base_type_id) {
        Ok(base) -> resolve_domain(base, lookup)
        Error(Nil) -> description
      }
    Base
    | Enum(..)
    | Composite(..)
    | Range(..)
    | Multirange(..)
    | Array(..)
    | Pseudo -> description
  }
}

// --- Helpers --------------------------------------------------------------------

pub fn is_base(description: TypeDescription, names: List(String)) -> Bool {
  case description.kind {
    Base -> list.contains(names, description.name)
    Enum(..)
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Array(..)
    | Pseudo -> False
  }
}

pub fn binary_bytes(value: Cell) -> Result(BitArray, DecodeIssue) {
  case value {
    Binary(bytes:) | Text(bytes:) -> Ok(bytes)
    Null -> Error(NullValue)
  }
}

pub fn utf8_text(value: Cell) -> Result(String, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  utf8_bytes(bytes)
}

pub fn utf8_bytes(bytes: BitArray) -> Result(String, DecodeIssue) {
  bit_array.to_string(bytes)
  |> result.replace_error(Malformed("the text is not UTF-8"))
}

pub fn wrong_size(
  description: TypeDescription,
  bytes: BitArray,
) -> DecodeIssue {
  Malformed(
    int.to_string(bit_array.byte_size(bytes))
    <> " bytes are not a "
    <> description.name
    <> " value",
  )
}

/// Reads one float8 from the front of the bytes. `NaN` and the infinities,
/// which a `Float` cannot hold, give `OutOfRange`.
pub fn read_float8(bytes: BitArray) -> Result(#(Float, BitArray), DecodeIssue) {
  case bytes {
    <<number:float-size(64), rest:bits>> -> Ok(#(number, rest))
    <<sign:size(1), 2047:size(11), fraction:size(52), _:bits>> ->
      Error(OutOfRange(special_float(sign, fraction)))
    _ -> Error(Malformed("a float8 is cut short"))
  }
}

/// The name of a float with an exponent of all ones: an infinity (no
/// fraction) or NaN.
pub fn special_float(sign: Int, fraction: Int) -> String {
  case fraction, sign {
    0, 0 -> "Infinity"
    0, _ -> "-Infinity"
    _, _ -> "NaN"
  }
}
