# Codecs

A codec connects a Gleam type and a PostgreSQL type. It writes a Gleam value as a parameter, and it reads a column back into a Gleam value. The module `dream_postgres/codecs` has the codecs. This guide lists each codec with the PostgreSQL types that it takes, then shows the codecs that you build: nullable values, arrays, enums, JSON, types with no codec, and composite types.

## Table of Contents

- [The checks of a codec](#the-checks-of-a-codec)
- [Every codec](#every-codec)
- [NULL](#null)
- [Arrays](#arrays)
- [Enums](#enums)
- [JSON](#json)
- [A type with no codec](#a-type-with-no-codec)
- [Composite types](#composite-types)
- [Placeholders](#placeholders)

## The checks of a codec

Each codec knows the PostgreSQL types that it takes. Before each run, dream_postgres checks the codec of each parameter and of each column against the type that the server gave. A codec that does not take the type is a `Failed` error, and the query does not run. So `codecs.int` cannot read a `text` column by mistake.

A value that does not fit is refused before the query goes to the server. For example, `codecs.int` refuses 40000 for an `int2` parameter.

## Every codec

`dream_postgres/codecs` has the `Codec` type, the codecs of Gleam's own types, and `nullable`, `enum` and `custom`. Every other PostgreSQL type family has its own module in `dream_postgres/codecs/`, with its Gleam types and its codecs. In this table, the part before the dot is the module: `codecs.int` is `dream_postgres/codecs`, and `time.date` is `dream_postgres/codecs/time`.

| Codec | PostgreSQL types | Gleam type |
|---|---|---|
| `codecs.int` | `int2`, `int4`, `int8`, `oid` | `Int` |
| `codecs.float` | `float4`, `float8` | `Float` |
| `codecs.bool` | `bool` | `Bool` |
| `codecs.text` | `text`, `varchar`, `bpchar`, `char`, `name`, and the extension type `citext` | `String` |
| `codecs.bytea` | `bytea` | `BitArray` |
| `codecs.uuid` | `uuid` | `dream_uuid.Uuid` |
| `numeric.numeric` | `numeric` | `String`, the exact text, such as `"1234.5600"` |
| `json.json` | `json` | `dream_postgres/codecs/json.Json` |
| `json.jsonb` | `jsonb` | `dream_postgres/codecs/json.Json` |
| `time.date` | `date` | `gleam/time/calendar.Date` |
| `time.date_or_infinite` | `date` | `MaybeInfinite(Date)` |
| `time.time` | `time` | `gleam/time/calendar.TimeOfDay` |
| `time.time_with_offset` | `timetz` | `dream_postgres/codecs/time.TimeWithOffset` |
| `time.timestamp` | `timestamp`, read as UTC | `gleam/time/timestamp.Timestamp` |
| `time.timestamp_or_infinite` | `timestamp` | `MaybeInfinite(Timestamp)` |
| `time.timestamp_with_time_zone` | `timestamptz` | `Timestamp` |
| `time.timestamp_with_time_zone_or_infinite` | `timestamptz` | `MaybeInfinite(Timestamp)` |
| `time.interval` | `interval` | `dream_postgres/codecs/time.Interval` |
| `time.interval_or_infinite` | `interval` | `MaybeInfinite(Interval)` |
| `network.ip_network` | `inet`, `cidr` | `dream_postgres/codecs/network.IpNetwork` |
| `network.mac_address` | `macaddr`, `macaddr8` | `dream_postgres/codecs/network.MacAddress` |
| `bit_string.bit_string` | `bit`, `varbit` | `BitArray` of exactly their bits |
| `tid.tid` | `tid` | `dream_postgres/codecs/tid.Tid` |
| `hstore.hstore()` | the extension type `hstore` | `Dict(String, Option(String))` |
| `geometry.point` | `point` | `dream_postgres/codecs/geometry.Point` |
| `geometry.line` | `line` | `Line` |
| `geometry.line_segment` | `lseg` | `LineSegment` |
| `geometry.box` | `box` | `Box` |
| `geometry.path` | `path` | `Path` |
| `geometry.polygon` | `polygon` | `Polygon` |
| `geometry.circle` | `circle` | `Circle` |
| `range.range(element)` | a range type of the element, such as `int4range`, `daterange` or `tstzrange` | `dream_postgres/codecs/range.Range(a)` |
| `range.multirange(element)` | a multirange type of the element | `List(Range(a))` |
| `text_search.text_search_vector` | `tsvector` | `dream_postgres/codecs/text_search.TsVector` |
| `text_search.text_search_query` | `tsquery` | `TsQuery` |
| `vector.vector` | the pgvector type `vector` | `dream_postgres/codecs/vector.Vector` |
| `vector.half_vector` | the pgvector type `halfvec` | `HalfVector` |
| `vector.sparse_vector` | the pgvector type `sparsevec` | `SparseVector` |
| `codecs.nullable(inner)` | the types of `inner`, and NULL | `Option(a)` |
| `array.array(element)` | a one-dimensional array of the element type | `List(a)` |
| `codecs.enum(..)` | one enum type | your own type |
| `codecs.custom(..)` | one type, in its text form | your own type |
| `composite.composite(..)` | one composite type | your own type |

Some values need care:

- `codecs.float` gives `OutOfRange` for `NaN` and the infinities, because a `Float` cannot hold them.
- `numeric.numeric` keeps every digit. No float rounding happens. It also reads `"NaN"` and `"Infinity"`.
- `time.date`, `time.timestamp` and `time.timestamp_with_time_zone` give `OutOfRange` for `infinity` and `-infinity`. The `_or_infinite` codecs read them as `PositiveInfinity` and `NegativeInfinity`.
- `time.timestamp` rounds a value to the nearest microsecond, as PostgreSQL stores it.
- `time.interval_or_infinite` reads the infinite intervals of PostgreSQL 17 and later. PostgreSQL 16 has no infinite interval, and it reads a `PositiveInfinity` parameter as the largest finite interval.
- `network.ip_network` refuses a `cidr` parameter with bits set right of its prefix, before the query goes to the server.

## NULL

A codec reads a NULL column as an error: `UnexpectedNull`, which names the column. `codecs.nullable(inner)` takes NULL too, as `None`, and writes `None` as NULL. This query reads the balance of each user, and a user with no account has no balance:

### Read a column that can be NULL <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/balances.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int, nullable, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import dream_postgres/row.{column, row}
import gleam/option.{type Option}

/// Gives the email of each user and the balance of the user's account. A
/// user with no account has no balance: the column is NULL, read as None.
pub fn balances(
  connection: Connection,
) -> Result(List(#(String, Option(Int))), Error(PostgresError)) {
  let email_and_balance = {
    use email <- column(text)
    use balance <- column(nullable(int))
    row(#(email, balance))
  }
  "SELECT users.email, accounts.balance FROM users
  LEFT JOIN accounts ON accounts.user_id = users.id ORDER BY users.id"
  |> query
  |> all(email_and_balance, connection)
}
```

## Arrays

`array.array(element)` reads and writes a one-dimensional array as a `List`. An array whose elements can be NULL needs a nullable element codec, `array.array(codec.nullable(codec.int))`:

### An array parameter <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/find_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/codecs/array.{array}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, parameter, query}
import snippets/user_row.{type User, user_row}

/// Gives the users with the ids. The list goes to PostgreSQL as one array
/// parameter.
pub fn find_users(
  connection: Connection,
  user_ids: List(Int),
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users WHERE id = ANY($1) ORDER BY id"
  |> query
  |> parameter(array(int), user_ids)
  |> all(user_row(), connection)
}
```

## Enums

`codecs.enum(type_name, first, rest)` takes the name of the enum type and each value with its label. The labels must be every label of the type in the database, or the check before the run refuses the query:

### An enum codec <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/mood_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codecs.{type Codec, enum}

/// The values of the PostgreSQL enum
/// `CREATE TYPE mood AS ENUM ('happy', 'sad')`.
pub type Mood {
  Happy
  Sad
}

/// Every label of the enum, each with its value.
pub fn mood_codec() -> Codec(Mood) {
  enum("mood", #(Happy, "happy"), [#(Sad, "sad")])
}
```

## JSON

`json.json` and `json.jsonb` read and write a `Json` value of `dream_postgres/codecs/json`. That value is always a valid JSON document. `json.from_json` makes one from a `gleam_json` value, and `json.parse` reads it with a decoder:

### Write and read a JSON document <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/theme_json.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codecs/json.{type Json, from_json, parse}
import gleam/dynamic/decode
import gleam/json as gleam_json

pub type Theme {
  Theme(dark: Bool, font_size: Int)
}

/// The theme as a JSON document, for a `json` or a `jsonb` parameter.
pub fn theme_document(theme: Theme) -> Json {
  gleam_json.object([
    #("dark", gleam_json.bool(theme.dark)),
    #("font_size", gleam_json.int(theme.font_size)),
  ])
  |> from_json
}

/// The theme of a JSON document that a `json` or a `jsonb` column gave.
pub fn theme_from_document(
  document: Json,
) -> Result(Theme, gleam_json.DecodeError) {
  parse(document, theme_decoder())
}

fn theme_decoder() -> decode.Decoder(Theme) {
  use dark <- decode.field("dark", decode.bool)
  use font_size <- decode.field("font_size", decode.int)
  decode.success(Theme(dark:, font_size:))
}
```

`json.from_string` makes a value from a text, and gives an error for a text that is not valid JSON. `json.to_string` gives the text.

## A type with no codec

`codecs.custom` makes a codec for a type that dream_postgres has no codec for, such as the type of an extension. It reads and writes the text form of the type. The `from_text` function gives an error for a text that it cannot read:

### A codec for ltree <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/category_path_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codecs.{type Codec, custom}
import gleam/string

/// A path of the extension type `ltree`, such as `shop.books.poetry`.
pub type CategoryPath {
  CategoryPath(labels: List(String))
}

/// Writes and reads an `ltree` value as its text.
pub fn category_path_codec() -> Codec(CategoryPath) {
  custom(
    type_name: "ltree",
    to_text: category_path_to_text,
    from_text: category_path_from_text,
    placeholder: CategoryPath(labels: []),
  )
}

fn category_path_to_text(path: CategoryPath) -> String {
  string.join(path.labels, with: ".")
}

fn category_path_from_text(text: String) -> Result(CategoryPath, String) {
  Ok(CategoryPath(labels: string.split(text, on: ".")))
}
```

A custom codec uses the text format, so a composite type cannot hold it.

## Composite types

`composite.composite` makes a codec of a composite type. It reads a value with a row reader, the same as a row of a query. It writes a value as a list of `composite.field` values, in the order of the fields of the type:

### A composite codec <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/address_codec.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codecs.{type Codec, nullable, text}
import dream_postgres/codecs/composite.{type Field, composite, field}
import dream_postgres/row.{column, row}
import gleam/option.{type Option, None}

/// The values of the PostgreSQL composite type
/// `CREATE TYPE address AS (street text, city text)`.
pub type Address {
  Address(street: String, city: Option(String))
}

/// Reads an address with a row reader, and writes it as its fields in the
/// order of the type.
pub fn address_codec() -> Codec(Address) {
  composite(
    "address",
    read: {
      use street <- column(text)
      use city <- column(nullable(text))
      row(Address(street:, city:))
    },
    write: address_fields,
    placeholder: Address(street: "", city: None),
  )
}

fn address_fields(address: Address) -> List(Field) {
  [field(text, address.street), field(nullable(text), address.city)]
}
```

## Placeholders

Each codec has a placeholder: a value of its type for a query that only gets checked and never runs, such as a query of the boot check. `codecs.placeholder(codec)` gives it. `codecs.custom` and `composite.composite` take the placeholder as an argument. The placeholder of `codecs.enum` is its first value. The [boot check guide](boot-check.md) shows its use.
