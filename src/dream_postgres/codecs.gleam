//// A codec writes one Gleam type as a PostgreSQL value, and reads it back.
////
//// The same codec gives a parameter and reads a column.
////
//// This module has the `Codec` type, the codecs of `Int`, `Float`, `Bool`,
//// `String`, `BitArray` and `Uuid`, and `nullable`, `enum` and `custom`.
//// Every other PostgreSQL type family has its own module in
//// `dream_postgres/codecs/`, with its Gleam types and its codecs: `array`,
//// `composite`, `numeric`, `bit_string`, `hstore`, `time`, `json`, `range`,
//// `network`, `geometry`, `text_search`, `vector` and `tid`.
////
//// ### Give an array parameter <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/existing_post_ids.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/codecs.{int}
//// import dream_postgres/codecs/array.{array}
//// import dream_postgres/error.{type PostgresError}
//// import dream_postgres/pool.{type Connection}
//// import dream_postgres/query.{all, parameter, query}
//// import dream_postgres/row.{single}
////
//// /// The ids of the list that a post has.
//// pub fn existing_post_ids(
////   connection: Connection,
////   ids: List(Int),
//// ) -> Result(List(Int), Error(PostgresError)) {
////   "SELECT id FROM posts WHERE id = any($1) ORDER BY id"
////   |> query
////   |> parameter(array(int), ids)
////   |> all(single(int), connection)
//// }
//// ```
////
//// Before a query runs, dream_postgres compares each codec with the type
//// that PostgreSQL gives the parameter or the column. A codec that does not
//// take that type stops the query before anything runs.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, OutOfRange, binary_bytes,
  is_base, special_float, utf8_text, wrong_size,
}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, BinaryFormat, Composite,
  Domain, Enum, Multirange, Null, Pseudo, Range, Text, TextFormat,
}
import dream_uuid.{type Uuid}
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A codec of the Gleam type `a`: it writes `a` as a PostgreSQL value, and
/// reads it back.
pub type Codec(a) =
  codec_type.Codec(a)

/// A value of the codec's type, for a query that is built only to be
/// checked, such as a query of `boot_check.checked`. A check uses the
/// codec of a parameter, never its value.
///
/// ### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/boot_check.{type QueryCheck, checked, checked_command}
/// import dream_postgres/codecs.{int, placeholder, text}
/// import dream_postgres/query.{named, parameter, query}
/// import dream_postgres/row.{column, row}
///
/// /// The checks of the queries of the user module. A check uses the codec of
/// /// each parameter, not its value, so each value is a placeholder.
/// pub fn queries() -> List(QueryCheck) {
///   [
///     query("SELECT id, email FROM users WHERE id = $1")
///       |> named("user.find")
///       |> parameter(int, placeholder(int))
///       |> checked({
///         use id <- column(int)
///         use email <- column(text)
///         row(#(id, email))
///       }),
///     query("DELETE FROM users WHERE id = $1")
///       |> named("user.delete")
///       |> parameter(int, placeholder(int))
///       |> checked_command,
///   ]
/// }
/// ```
pub fn placeholder(codec: Codec(a)) -> a {
  codec_type.placeholder(codec)
}

// --- Combinators -------------------------------------------------------------

/// A codec that also takes NULL, as `None`.
pub fn nullable(inner: Codec(a)) -> Codec(Option(a)) {
  Codec(
    name: "nullable " <> inner.name,
    gleam_type: "Option(" <> inner.gleam_type <> ")",
    format: inner.format,
    accepts: inner.accepts,
    encode: fn(value, description, lookup) {
      case value {
        Some(present) -> inner.encode(present, description, lookup)
        None -> Ok(Null)
      }
    },
    decode: fn(value, description, lookup) {
      case value {
        Null -> Ok(None)
        Binary(..) | Text(..) ->
          inner.decode(value, description, lookup) |> result.map(Some)
      }
    },
    placeholder: None,
  )
}

/// A codec of a PostgreSQL enum. The labels must be the labels of the
/// enum type in the database, all of them, or the check before the run
/// refuses the query.
///
/// ### A codec of an enum type <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/mood_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codecs.{type Codec, enum}
///
/// /// The values of the PostgreSQL enum
/// /// `CREATE TYPE mood AS ENUM ('happy', 'sad')`.
/// pub type Mood {
///   Happy
///   Sad
/// }
///
/// /// Every label of the enum, each with its value.
/// pub fn mood_codec() -> Codec(Mood) {
///   enum("mood", #(Happy, "happy"), [#(Sad, "sad")])
/// }
/// ```
pub fn enum(
  type_name: String,
  first: #(a, String),
  rest: List(#(a, String)),
) -> Codec(a) {
  let values = [first, ..rest]
  let labels = list.map(values, fn(pair) { pair.1 })
  Codec(
    name: "enum " <> type_name,
    gleam_type: type_name,
    format: BinaryFormat,
    accepts: fn(description, _lookup) {
      accepts_enum(description, type_name, labels)
    },
    encode: fn(value, _description, _lookup) {
      encode_enum_label(values, value, type_name)
    },
    decode: fn(value, _description, _lookup) {
      use label <- result.try(utf8_text(value))
      decode_enum_label(values, label)
    },
    placeholder: first.0,
  )
}

fn accepts_enum(
  description: TypeDescription,
  type_name: String,
  labels: List(String),
) -> Bool {
  case description.kind {
    Enum(labels: database_labels) ->
      description.name == type_name
      && list.sort(database_labels, string.compare)
      == list.sort(labels, string.compare)
    Base
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Array(..)
    | Pseudo -> False
  }
}

fn encode_enum_label(
  values: List(#(a, String)),
  value: a,
  type_name: String,
) -> Result(Cell, String) {
  case list.find(values, fn(pair) { pair.0 == value }) {
    Ok(#(_, label)) -> Ok(Binary(bit_array.from_string(label)))
    Error(Nil) -> Error("the value is not one of the labels of " <> type_name)
  }
}

fn decode_enum_label(
  values: List(#(a, String)),
  label: String,
) -> Result(a, DecodeIssue) {
  case list.find(values, fn(pair) { pair.1 == label }) {
    Ok(#(found, _)) -> Ok(found)
    Error(Nil) ->
      Error(Malformed("the label " <> label <> " is not a label of the codec"))
  }
}

/// A codec of a type that dream_postgres has no codec for, such as an
/// extension's type. It reads and writes the type's text form.
///
/// ### A codec of the ltree extension <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/ltree_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codecs.{type Codec, custom}
/// import gleam/list
/// import gleam/string
///
/// /// A path of the ltree extension, such as `top.science.physics`.
/// pub type Path {
///   Path(labels: List(String))
/// }
///
/// pub fn ltree_codec() -> Codec(Path) {
///   custom(
///     type_name: "ltree",
///     to_text: path_to_string,
///     from_text: path_from_string,
///     placeholder: Path([]),
///   )
/// }
///
/// fn path_to_string(path: Path) -> String {
///   string.join(path.labels, ".")
/// }
///
/// fn path_from_string(text: String) -> Result(Path, String) {
///   let labels = string.split(text, ".")
///   case list.contains(labels, "") {
///     True -> Error("an ltree path has an empty label: " <> text)
///     False -> Ok(Path(labels))
///   }
/// }
/// ```
pub fn custom(
  type_name type_name: String,
  to_text to_text: fn(a) -> String,
  from_text from_text: fn(String) -> Result(a, String),
  placeholder placeholder: a,
) -> Codec(a) {
  Codec(
    name: type_name,
    gleam_type: type_name,
    format: TextFormat,
    accepts: fn(description, _lookup) { description.name == type_name },
    encode: fn(value, _description, _lookup) {
      Ok(Text(bit_array.from_string(to_text(value))))
    },
    decode: fn(value, _description, _lookup) {
      use text <- result.try(utf8_text(value))
      from_text(text) |> result.map_error(Malformed)
    },
    placeholder:,
  )
}

// --- Built-in codecs ----------------------------------------------------------

/// `int2`, `int4`, `int8` and `oid`, as `Int`. A value that does not fit
/// the parameter's type is refused before the query is sent.
pub const int =
  Codec(
    name: "int",
    gleam_type: "Int",
    format: BinaryFormat,
    accepts: accepts_int,
    encode: encode_int,
    decode: decode_int,
    placeholder: 0,
  )

/// `float4` and `float8`, as `Float`. `NaN` and the infinities, which a
/// `Float` cannot hold, give `OutOfRange`.
pub const float =
  Codec(
    name: "float",
    gleam_type: "Float",
    format: BinaryFormat,
    accepts: accepts_float,
    encode: encode_float,
    decode: decode_float,
    placeholder: 0.0,
  )

/// `bool`, as `Bool`.
pub const bool =
  Codec(
    name: "bool",
    gleam_type: "Bool",
    format: BinaryFormat,
    accepts: accepts_bool,
    encode: encode_bool,
    decode: decode_bool,
    placeholder: False,
  )

/// `text`, `varchar`, `bpchar`, `char`, `name` and the extension type
/// `citext`, as `String`.
pub const text =
  Codec(
    name: "text",
    gleam_type: "String",
    format: BinaryFormat,
    accepts: accepts_text,
    encode: encode_text,
    decode: decode_text,
    placeholder: "",
  )

/// `bytea`, as `BitArray`.
pub const bytea =
  Codec(
    name: "bytea",
    gleam_type: "BitArray",
    format: BinaryFormat,
    accepts: accepts_bytea,
    encode: encode_bytea,
    decode: decode_bytea,
    placeholder: <<>>,
  )

/// `uuid`, as `dream_uuid.Uuid`.
pub const uuid =
  Codec(
    name: "uuid",
    gleam_type: "Uuid",
    format: BinaryFormat,
    accepts: accepts_uuid,
    encode: encode_uuid,
    decode: decode_uuid,
    placeholder: placeholder_uuid,
  )

// --- int -----------------------------------------------------------------------

fn accepts_int(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["int2", "int4", "int8", "oid"])
}

fn encode_int(
  value: Int,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case description.name {
    "int2" ->
      in_range(value, -32_768, 32_767, "int2")
      |> result.replace(Binary(<<value:size(16)>>))
    "int4" ->
      in_range(value, -2_147_483_648, 2_147_483_647, "int4")
      |> result.replace(Binary(<<value:size(32)>>))
    "oid" ->
      in_range(value, 0, 4_294_967_295, "oid")
      |> result.replace(Binary(<<value:size(32)>>))
    _ ->
      in_range(
        value,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807,
        "int8",
      )
      |> result.replace(Binary(<<value:size(64)>>))
  }
}

fn in_range(
  value: Int,
  lowest: Int,
  highest: Int,
  type_name: String,
) -> Result(Nil, String) {
  case value >= lowest && value <= highest {
    True -> Ok(Nil)
    False -> Error(int.to_string(value) <> " is out of range for " <> type_name)
  }
}

fn decode_int(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Int, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case description.name, bytes {
    "oid", <<number:unsigned-size(32)>> -> Ok(number)
    _, <<number:signed-size(16)>> -> Ok(number)
    _, <<number:signed-size(32)>> -> Ok(number)
    _, <<number:signed-size(64)>> -> Ok(number)
    _, _ -> Error(wrong_size(description, bytes))
  }
}

// --- float ---------------------------------------------------------------------

fn accepts_float(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["float4", "float8"])
}

fn encode_float(
  value: Float,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case description.name {
    "float4" -> encode_float4(value)
    _ -> Ok(Binary(<<value:float-size(64)>>))
  }
}

fn encode_float4(value: Float) -> Result(Cell, String) {
  case value >. largest_float4 || value <. 0.0 -. largest_float4 {
    True -> Error(float.to_string(value) <> " is out of range for float4")
    False -> Ok(Binary(<<value:float-size(32)>>))
  }
}

fn decode_float(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Float, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<number:float-size(32)>> -> Ok(number)
    <<number:float-size(64)>> -> Ok(number)
    <<sign:size(1), 255:size(8), fraction:size(23)>> ->
      Error(OutOfRange(special_float(sign, fraction)))
    <<sign:size(1), 2047:size(11), fraction:size(52)>> ->
      Error(OutOfRange(special_float(sign, fraction)))
    _ -> Error(wrong_size(description, bytes))
  }
}

// The largest finite float4.
const largest_float4 = 3.4028234663852886e38

// --- bool ----------------------------------------------------------------------

fn accepts_bool(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["bool"])
}

fn encode_bool(
  value: Bool,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  case value {
    True -> Ok(Binary(<<1>>))
    False -> Ok(Binary(<<0>>))
  }
}

fn decode_bool(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Bool, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<1>> -> Ok(True)
    <<0>> -> Ok(False)
    _ -> Error(wrong_size(description, bytes))
  }
}

// --- text ----------------------------------------------------------------------

fn accepts_text(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["text", "varchar", "bpchar", "char", "name", "citext"])
}

fn encode_text(
  value: String,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(bit_array.from_string(value)))
}

fn decode_text(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(String, DecodeIssue) {
  utf8_text(value)
}

// --- bytea ---------------------------------------------------------------------

fn accepts_bytea(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["bytea"])
}

fn encode_bytea(
  value: BitArray,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(value))
}

fn decode_bytea(
  value: Cell,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(BitArray, DecodeIssue) {
  binary_bytes(value)
}

// --- uuid ----------------------------------------------------------------------

const placeholder_uuid = dream_uuid.nil

fn accepts_uuid(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["uuid"])
}

fn encode_uuid(
  value: Uuid,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(dream_uuid.to_bit_array(value)))
}

fn decode_uuid(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Uuid, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  dream_uuid.from_bit_array(bytes)
  |> result.replace_error(wrong_size(description, bytes))
}
