//// A codec writes one Gleam type as a PostgreSQL value, and reads it back.
////
//// The same codec gives a parameter and reads a column:
////
//// ### Give an array parameter <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/existing_post_ids.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/codec.{array, int}
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
  type DecodeIssue, type TypeLookup, Codec, Malformed, NullValue, OutOfRange,
  accepts, binary_bytes, decode, encode, is_base, special_float, utf8_bytes,
  utf8_text, wrong_size,
}
import dream_postgres/codecs/composite as composite_codecs
import dream_postgres/codecs/geometry as geometry_codecs
import dream_postgres/codecs/network as network_codecs
import dream_postgres/codecs/numeric as numeric_codec
import dream_postgres/codecs/range as range_codecs
import dream_postgres/codecs/text_search as text_search_codecs
import dream_postgres/codecs/time as time_codecs
import dream_postgres/codecs/vector as vector_codecs
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, Array, Base, Binary, BinaryFormat, Composite,
  Domain, Enum, Multirange, Null, Pseudo, Range, Text, TextFormat,
}
import dream_postgres/json.{type Json}
import dream_postgres/query/definition
import dream_postgres/range.{type Range}
import dream_postgres/row/reader.{type Row}
import dream_uuid.{type Uuid}
import gleam/bit_array
import gleam/dict.{type Dict}
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
/// import dream_postgres/codec.{int, placeholder, text}
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

/// A codec of a one-dimensional array, as a `List`. An element that is NULL
/// needs a nullable element codec:
///
/// ### An array whose elements can be NULL <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/scores_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{type Codec, array, int, nullable}
/// import gleam/option.{type Option}
///
/// /// A codec of `int4[]` whose elements can be NULL.
/// pub fn scores_codec() -> Codec(List(Option(Int))) {
///   array(nullable(int))
/// }
/// ```
pub fn array(element: Codec(a)) -> Codec(List(a)) {
  Codec(
    name: "array of " <> element.name,
    gleam_type: "List(" <> element.gleam_type <> ")",
    format: element.format,
    accepts: fn(description, lookup) {
      array_accepts(element, description, lookup)
    },
    encode: fn(values, description, lookup) {
      use element_type <- result.try(array_element_type(description, lookup))
      case element.format {
        BinaryFormat ->
          encode_binary_array(
            element,
            values,
            description,
            element_type,
            lookup,
          )
        TextFormat -> encode_text_array(element, values, element_type, lookup)
      }
    },
    decode: fn(value, description, lookup) {
      use element_type <- result.try(
        array_element_type(description, lookup)
        |> result.map_error(Malformed),
      )
      case value {
        Null -> Error(NullValue)
        Binary(bytes:) ->
          decode_binary_array(element, bytes, element_type, lookup)
        Text(bytes:) -> decode_text_array(element, bytes, element_type, lookup)
      }
    },
    placeholder: [],
  )
}

fn array_accepts(
  element: Codec(a),
  description: TypeDescription,
  lookup: TypeLookup,
) -> Bool {
  case description.kind {
    Array(element_type_id:) ->
      element_type_accepted(element, element_type_id, lookup)
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Pseudo -> False
  }
}

fn element_type_accepted(
  element: Codec(a),
  element_type_id: Int,
  lookup: TypeLookup,
) -> Bool {
  case lookup(element_type_id) {
    Ok(element_type) -> accepts(element, element_type, lookup)
    Error(Nil) -> False
  }
}

fn array_element_type(
  description: TypeDescription,
  lookup: TypeLookup,
) -> Result(TypeDescription, String) {
  case description.kind {
    Array(element_type_id:) ->
      lookup(element_type_id)
      |> result.replace_error(
        "the element type " <> int.to_string(element_type_id) <> " is unknown",
      )
    Base
    | Enum(..)
    | Composite(..)
    | Domain(..)
    | Range(..)
    | Multirange(..)
    | Pseudo -> Error(description.name <> " is not an array type")
  }
}

/// A codec of a PostgreSQL enum. The labels must be the labels of the
/// enum type in the database, all of them, or the check before the run
/// refuses the query.
///
/// ### A codec of an enum type <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/mood_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{type Codec, enum}
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
/// import dream_postgres/codec.{type Codec, custom}
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

/// `numeric`, as its exact text, for example `"1234.5600"`, `"NaN"` or
/// `"Infinity"`. No digit is lost, and no float rounding happens. It uses
/// the binary format, so it also reads a numeric field of a composite.
pub const numeric = numeric_codec.numeric

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

/// `date`, as `gleam_time`'s `Date`. `infinity` and `-infinity` give
/// `OutOfRange`: read them with `date_or_infinite`.
pub const date = time_codecs.date

/// `date`, as a `MaybeInfinite(Date)`, which holds `infinity` too.
pub const date_or_infinite = time_codecs.date_or_infinite

/// `time`, as `gleam_time`'s `TimeOfDay`, to the microsecond.
pub const time = time_codecs.time

/// `timetz`, as a `TimeWithOffset`.
pub const time_with_offset = time_codecs.time_with_offset

/// `timestamp`, as `gleam_time`'s `Timestamp`, read as UTC. A value is
/// rounded to the nearest microsecond, as PostgreSQL stores it.
pub const timestamp = time_codecs.timestamp_codec

/// `timestamp`, as a `MaybeInfinite(Timestamp)`, which holds `infinity` too.
pub const timestamp_or_infinite = time_codecs.timestamp_or_infinite

/// `timestamptz`, as `gleam_time`'s `Timestamp`.
pub const timestamp_with_time_zone = time_codecs.timestamp_with_time_zone

/// `timestamptz`, as a `MaybeInfinite(Timestamp)`.
pub const timestamp_with_time_zone_or_infinite =
  time_codecs.timestamp_with_time_zone_or_infinite

/// `interval`, as an `Interval` of months, days and microseconds.
pub const interval = time_codecs.interval

/// `interval`, as a `MaybeInfinite(Interval)`, for the infinite intervals of
/// PostgreSQL 17 and later. PostgreSQL 16 has no infinite interval: it
/// reads `PositiveInfinity` as the largest finite interval.
pub const interval_or_infinite = time_codecs.interval_or_infinite

/// `inet` and `cidr`, as an `IpNetwork`. A `cidr` parameter with bits set
/// right of its prefix is refused before the query is sent.
pub const ip_network = network_codecs.ip_network

/// `macaddr` and `macaddr8`, as a `MacAddress`.
pub const mac_address = network_codecs.mac_address

/// `bit` and `varbit`, as a `BitArray` of exactly their bits.
pub const bit_string = network_codecs.bit_string

/// `tid`, as a `Tid`.
pub const tid = network_codecs.tid_codec

/// The extension type `hstore`, as a `Dict` of keys to values that can be
/// NULL. A function, because a constant cannot hold a `Dict`.
pub fn hstore() -> Codec(Dict(String, Option(String))) {
  network_codecs.hstore()
}

/// `point`, as a `Point`.
pub const point = geometry_codecs.point

/// `line`, as a `Line`.
pub const line = geometry_codecs.line

/// `lseg`, as a `LineSegment`.
pub const line_segment = geometry_codecs.line_segment

/// `box`, as a `Box`.
pub const box = geometry_codecs.box

/// `path`, as a `Path`.
pub const path = geometry_codecs.path

/// `polygon`, as a `Polygon`.
pub const polygon = geometry_codecs.polygon

/// `circle`, as a `Circle`.
pub const circle = geometry_codecs.circle

/// A codec of a range of the element codec's type, for any range type
/// whose element the element codec takes:
///
/// ### A codec of a date range <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/booking_period_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{type Codec, date, range}
/// import dream_postgres/range.{type Range}
/// import gleam/time/calendar.{type Date}
///
/// /// A codec of `daterange`.
/// pub fn booking_period_codec() -> Codec(Range(Date)) {
///   range(date)
/// }
/// ```
pub fn range(element: Codec(a)) -> Codec(Range(a)) {
  range_codecs.range(element)
}

/// A codec of a multirange, as a list of ranges.
pub fn multirange(element: Codec(a)) -> Codec(List(Range(a))) {
  range_codecs.multirange(element)
}

/// `tsvector`, as a list of lexemes.
pub const text_search_vector = text_search_codecs.text_search_vector

/// `tsquery`, as a `TsQuery`.
pub const text_search_query = text_search_codecs.text_search_query

/// The pgvector type `vector`, as a `Vector`.
pub const vector = vector_codecs.vector

/// The pgvector type `halfvec`, as a `HalfVector`.
pub const half_vector = vector_codecs.half_vector

/// The pgvector type `sparsevec`, as a `SparseVector`.
pub const sparse_vector = vector_codecs.sparse_vector

/// A field of a composite value, with its codec, for the `write` function
/// of `composite`.
pub type Field =
  definition.Value

/// A field of a composite value: its codec and its value. The fields go in
/// the order of the type's fields.
pub fn field(codec: Codec(a), value: a) -> Field {
  definition.value_of(codec, value)
}

/// A codec of a composite type. It reads a value with a row reader, the
/// same as a row of a query, and writes it as a list of fields in the
/// type's order. Each field's codec must use the binary format, as every
/// codec of this module does except `custom`.
///
/// ### A codec of a composite type <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/address_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_postgres/codec.{
///   type Codec, type Field, composite, field, nullable, text,
/// }
/// import dream_postgres/row.{column, row}
/// import gleam/option.{type Option, None}
///
/// /// The values of the PostgreSQL composite type
/// /// `CREATE TYPE address AS (street text, city text)`.
/// pub type Address {
///   Address(street: String, city: Option(String))
/// }
///
/// /// Reads an address with a row reader, and writes it as its fields in the
/// /// order of the type.
/// pub fn address_codec() -> Codec(Address) {
///   composite(
///     "address",
///     read: {
///       use street <- column(text)
///       use city <- column(nullable(text))
///       row(Address(street:, city:))
///     },
///     write: address_fields,
///     placeholder: Address(street: "", city: None),
///   )
/// }
///
/// fn address_fields(address: Address) -> List(Field) {
///   [field(text, address.street), field(nullable(text), address.city)]
/// }
/// ```
pub fn composite(
  type_name: String,
  read reader: Row(a),
  write to_fields: fn(a) -> List(Field),
  placeholder placeholder: a,
) -> Codec(a) {
  composite_codecs.composite(
    type_name:,
    read: reader,
    write: to_fields,
    placeholder:,
  )
}

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

// --- json ----------------------------------------------------------------------

const placeholder_json = json.null

fn accepts_json(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["json"])
}

fn encode_json(
  value: Json,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  Ok(Binary(bit_array.from_string(json.to_string(value))))
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
  Ok(Binary(<<1, json.to_string(value):utf8>>))
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
  json.from_string(text)
  |> result.replace_error(Malformed("the server sent text that is not JSON"))
}

// --- Arrays --------------------------------------------------------------------

// The binary form of an array: the number of dimensions, a flag for NULL
// elements, the element type's OID, then for each dimension its size and
// lower bound, then each element as a length (-1 for NULL) and its bytes.
fn encode_binary_array(
  element: Codec(a),
  values: List(a),
  array_type: TypeDescription,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use cells <- result.try(
    list.try_map(values, fn(value) {
      encode(element, value, element_type, lookup)
    }),
  )
  let has_null = case list.contains(cells, Null) {
    True -> 1
    False -> 0
  }
  use lower_bound <- result.try(lower_bound(array_type, cells, has_null))
  let header = case cells {
    [] -> <<0:size(32), 0:size(32), element_type.id:size(32)>>
    _ -> <<
      1:size(32),
      has_null:size(32),
      element_type.id:size(32),
      { list.length(cells) }:size(32),
      lower_bound:size(32),
    >>
  }
  Ok(
    Binary(
      list.fold(cells, header, fn(bytes, cell) {
        bit_array.append(bytes, binary_element(cell))
      }),
    ),
  )
}

// An array counts from 1. The vector types int2vector and oidvector count
// from 0, and their receive functions take only one dimension, with no
// NULL element.
fn lower_bound(
  array_type: TypeDescription,
  cells: List(Cell),
  has_null: Int,
) -> Result(Int, String) {
  case is_base_vector(array_type), cells, has_null {
    False, _, _ -> Ok(1)
    True, [], _ ->
      Error(array_type.name <> " cannot be empty in the binary format")
    True, _, 1 -> Error(array_type.name <> " cannot hold a NULL element")
    True, _, _ -> Ok(0)
  }
}

fn is_base_vector(array_type: TypeDescription) -> Bool {
  array_type.schema == "pg_catalog"
  && { array_type.name == "int2vector" || array_type.name == "oidvector" }
}

fn binary_element(cell: Cell) -> BitArray {
  case cell {
    Null -> <<-1:size(32)>>
    Binary(bytes:) | Text(bytes:) -> <<
      { bit_array.byte_size(bytes) }:size(32),
      bytes:bits,
    >>
  }
}

fn decode_binary_array(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(a), DecodeIssue) {
  case bytes {
    <<0:size(32), _flags:size(32), _element_type_id:size(32)>> -> Ok([])
    <<
      1:size(32),
      _flags:size(32),
      _element_type_id:size(32),
      count:size(32),
      _lower_bound:signed-size(32),
      elements:bits,
    >> ->
      decode_binary_elements(element, elements, count, element_type, lookup, [])
    <<dimensions:size(32), _:bits>> ->
      Error(Malformed(
        "the array has "
        <> int.to_string(dimensions)
        <> " dimensions, and a List holds one",
      ))
    _ -> Error(Malformed("the array's header is cut short"))
  }
}

fn decode_binary_elements(
  element: Codec(a),
  bytes: BitArray,
  remaining: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
  decoded: List(a),
) -> Result(List(a), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(decoded))
    0, _ -> Error(Malformed("the array has bytes after its last element"))
    _, <<-1:signed-size(32), rest:bits>> ->
      decode_binary_element(
        element,
        Null,
        rest,
        remaining,
        element_type,
        lookup,
        decoded,
      )
    _, <<length:size(32), item:bytes-size(length), rest:bits>> ->
      decode_binary_element(
        element,
        Binary(item),
        rest,
        remaining,
        element_type,
        lookup,
        decoded,
      )
    _, _ -> Error(Malformed("the array's elements are cut short"))
  }
}

fn decode_binary_element(
  element: Codec(a),
  cell: Cell,
  rest: BitArray,
  remaining: Int,
  element_type: TypeDescription,
  lookup: TypeLookup,
  decoded: List(a),
) -> Result(List(a), DecodeIssue) {
  use value <- result.try(decode(element, cell, element_type, lookup))
  decode_binary_elements(element, rest, remaining - 1, element_type, lookup, [
    value,
    ..decoded
  ])
}

// The text form of an array: `{a,"b c",NULL}`. Each element is quoted, with
// each backslash and quote escaped, so no element needs other checks.
fn encode_text_array(
  element: Codec(a),
  values: List(a),
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(Cell, String) {
  use cells <- result.try(
    list.try_map(values, fn(value) {
      encode(element, value, element_type, lookup)
    }),
  )
  let items = list.map(cells, text_array_item)
  Ok(
    Text(<<
      "{":utf8,
      { bit_array.concat(list.intersperse(items, <<",":utf8>>)) }:bits,
      "}":utf8,
    >>),
  )
}

fn text_array_item(cell: Cell) -> BitArray {
  case cell {
    Null -> <<"NULL":utf8>>
    Binary(bytes:) | Text(bytes:) -> <<
      "\"":utf8,
      { escape_bytes(bytes, <<>>) }:bits,
      "\"":utf8,
    >>
  }
}

fn escape_bytes(bytes: BitArray, escaped: BitArray) -> BitArray {
  case bytes {
    <<"\\":utf8, rest:bits>> ->
      escape_bytes(rest, <<escaped:bits, "\\\\":utf8>>)
    <<"\"":utf8, rest:bits>> ->
      escape_bytes(rest, <<escaped:bits, "\\\"":utf8>>)
    <<byte, rest:bits>> -> escape_bytes(rest, <<escaped:bits, byte>>)
    // The end of the bytes.
    _ -> escaped
  }
}

fn decode_text_array(
  element: Codec(a),
  bytes: BitArray,
  element_type: TypeDescription,
  lookup: TypeLookup,
) -> Result(List(a), DecodeIssue) {
  use text <- result.try(utf8_bytes(bytes))
  use items <- result.try(parse_text_array(text))
  list.try_map(items, fn(item) {
    let cell = case item {
      None -> Null
      Some(item_text) -> Text(bit_array.from_string(item_text))
    }
    decode(element, cell, element_type, lookup)
  })
}

// Reads a one-dimensional array literal into its elements: `None` for an
// unquoted NULL, and the text of every other element.
fn parse_text_array(text: String) -> Result(List(Option(String)), DecodeIssue) {
  case text {
    "{}" -> Ok([])
    "{" <> body -> parse_array_body(body)
    _ -> Error(Malformed("the array text does not start with a brace"))
  }
}

fn parse_array_body(body: String) -> Result(List(Option(String)), DecodeIssue) {
  case string.ends_with(body, "}") {
    True -> parse_items(string.to_graphemes(string.drop_end(body, 1)), [])
    False -> Error(Malformed("the array text has no closing brace"))
  }
}

fn parse_items(
  characters: List(String),
  items: List(Option(String)),
) -> Result(List(Option(String)), DecodeIssue) {
  case characters {
    ["{", ..] ->
      Error(Malformed(
        "the array has more than one dimension, and a List holds one",
      ))
    ["\"", ..rest] -> {
      use #(item, after) <- result.try(parse_quoted(rest, ""))
      finish_item(after, [Some(item), ..items])
    }
    _ -> {
      let #(item, after) = parse_unquoted(characters, "")
      finish_item(after, [unquoted_item(item), ..items])
    }
  }
}

fn unquoted_item(item: String) -> Option(String) {
  case string.trim(item) {
    "NULL" -> None
    other -> Some(other)
  }
}

fn finish_item(
  after: List(String),
  items: List(Option(String)),
) -> Result(List(Option(String)), DecodeIssue) {
  case after {
    [] -> Ok(list.reverse(items))
    [",", ..rest] -> parse_items(rest, items)
    _ ->
      Error(Malformed("the array text has a character after a quoted element"))
  }
}

fn parse_quoted(
  characters: List(String),
  item: String,
) -> Result(#(String, List(String)), DecodeIssue) {
  case characters {
    ["\\", escaped, ..rest] -> parse_quoted(rest, item <> escaped)
    ["\"", ..rest] -> Ok(#(item, rest))
    [character, ..rest] -> parse_quoted(rest, item <> character)
    [] -> Error(Malformed("the array text has a quote that does not close"))
  }
}

fn parse_unquoted(
  characters: List(String),
  item: String,
) -> #(String, List(String)) {
  case characters {
    [",", ..] | [] -> #(item, characters)
    ["\\", escaped, ..rest] -> parse_unquoted(rest, item <> escaped)
    [character, ..rest] -> parse_unquoted(rest, item <> character)
  }
}
