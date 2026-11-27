//// The types of a small PostgreSQL catalog, for the tests that need no
//// server. A codec looks up the types that a type refers to (the element of
//// an array, the base of a domain, the subtype of a range) with `lookup`.
//// The ids 99_999 and up are in no catalog, so a type that refers to them
//// refers to a type that is not known.

import dream_postgres/internal/cell.{
  type TypeDescription, Array, Base, Composite, Domain, Enum, Multirange, Pseudo,
  Range, TypeDescription,
}
import gleam/list

/// A base type of `pg_catalog` with this name. The codecs choose a base type
/// by its name, so its id is 0, which no other type refers to.
///
/// ## Example
///
/// ```gleam
/// type_catalog.base("timestamptz")
/// ```
pub fn base(name: String) -> TypeDescription {
  TypeDescription(id: 0, schema: "pg_catalog", name:, kind: Base)
}

/// A base type of `pg_catalog` with this id and name.
///
/// ## Example
///
/// ```gleam
/// type_catalog.base_with_id(1033, "aclitem")
/// ```
pub fn base_with_id(id: Int, name: String) -> TypeDescription {
  TypeDescription(id:, schema: "pg_catalog", name:, kind: Base)
}

/// A pseudo-type of `pg_catalog` with this id and name.
///
/// ## Example
///
/// ```gleam
/// type_catalog.pseudo(2249, "record")
/// ```
pub fn pseudo(id: Int, name: String) -> TypeDescription {
  TypeDescription(id:, schema: "pg_catalog", name:, kind: Pseudo)
}

/// A composite type of `public` with this id, name and fields. Each field
/// is its name and the id of its type.
///
/// ## Example
///
/// ```gleam
/// type_catalog.composite(90_201, "place", [#("street", 25)])
/// ```
pub fn composite(
  id: Int,
  name: String,
  fields: List(#(String, Int)),
) -> TypeDescription {
  TypeDescription(id:, schema: "public", name:, kind: Composite(fields))
}

/// The type `int2`.
pub fn int2() -> TypeDescription {
  base_with_id(21, "int2")
}

/// The type `int4`.
pub fn int4() -> TypeDescription {
  base_with_id(23, "int4")
}

/// The type `int8`.
pub fn int8() -> TypeDescription {
  base_with_id(20, "int8")
}

/// The type `oid`.
pub fn oid() -> TypeDescription {
  base_with_id(26, "oid")
}

/// The type `float4`.
pub fn float4() -> TypeDescription {
  base_with_id(700, "float4")
}

/// The type `float8`.
pub fn float8() -> TypeDescription {
  base_with_id(701, "float8")
}

/// The type `text`.
pub fn text() -> TypeDescription {
  base_with_id(25, "text")
}

/// The type `numeric`.
pub fn numeric() -> TypeDescription {
  base_with_id(1700, "numeric")
}

/// The type `point`.
pub fn point() -> TypeDescription {
  base_with_id(600, "point")
}

/// The extension type `ltree`, a base type of `public`.
pub fn ltree() -> TypeDescription {
  TypeDescription(id: 90_001, schema: "public", name: "ltree", kind: Base)
}

/// The enum type `mood`, with the labels `happy` and `sad`.
pub fn mood() -> TypeDescription {
  TypeDescription(
    id: 90_002,
    schema: "public",
    name: "mood",
    kind: Enum(["happy", "sad"]),
  )
}

/// The array type `_int4`.
pub fn int4_array() -> TypeDescription {
  TypeDescription(
    id: 1007,
    schema: "pg_catalog",
    name: "_int4",
    kind: Array(23),
  )
}

/// The type `int2vector`, an array of `int2`.
pub fn int2_vector() -> TypeDescription {
  TypeDescription(
    id: 22,
    schema: "pg_catalog",
    name: "int2vector",
    kind: Array(21),
  )
}

/// The array type `_ltree`, of the extension type `ltree`.
pub fn ltree_array() -> TypeDescription {
  TypeDescription(
    id: 90_003,
    schema: "public",
    name: "_ltree",
    kind: Array(90_001),
  )
}

/// An array type whose element type is not known.
pub fn lost_array() -> TypeDescription {
  TypeDescription(
    id: 90_004,
    schema: "public",
    name: "_lost",
    kind: Array(99_999),
  )
}

/// The domain `positive_int` over `int4`.
pub fn positive_int() -> TypeDescription {
  TypeDescription(
    id: 90_005,
    schema: "public",
    name: "positive_int",
    kind: Domain(23),
  )
}

/// A domain whose base type is not known.
pub fn lost_domain() -> TypeDescription {
  TypeDescription(
    id: 90_006,
    schema: "public",
    name: "lost_domain",
    kind: Domain(99_999),
  )
}

/// The array type `_point`.
pub fn point_array() -> TypeDescription {
  TypeDescription(
    id: 1017,
    schema: "pg_catalog",
    name: "_point",
    kind: Array(600),
  )
}

/// The range type `numrange`.
pub fn numeric_range() -> TypeDescription {
  TypeDescription(
    id: 3906,
    schema: "pg_catalog",
    name: "numrange",
    kind: Range(1700),
  )
}

/// The range type `int4range`.
pub fn int4_range() -> TypeDescription {
  TypeDescription(
    id: 3904,
    schema: "pg_catalog",
    name: "int4range",
    kind: Range(23),
  )
}

/// The multirange type `int4multirange`.
pub fn int4_multirange() -> TypeDescription {
  TypeDescription(
    id: 4451,
    schema: "pg_catalog",
    name: "int4multirange",
    kind: Multirange(3904),
  )
}

/// The range type `pathrange` of `public`, over `ltree`.
pub fn path_range() -> TypeDescription {
  TypeDescription(
    id: 90_020,
    schema: "public",
    name: "pathrange",
    kind: Range(90_001),
  )
}

/// The multirange type `pathmultirange` of `public`, over `pathrange`.
pub fn path_multirange() -> TypeDescription {
  TypeDescription(
    id: 90_021,
    schema: "public",
    name: "pathmultirange",
    kind: Multirange(90_020),
  )
}

/// The types that `lookup` finds.
pub fn all() -> List(TypeDescription) {
  [
    int2(),
    int4(),
    int8(),
    text(),
    numeric(),
    point(),
    ltree(),
    mood(),
    int4_array(),
    point_array(),
    numeric_range(),
    int4_range(),
    path_range(),
  ]
}

/// Find a type of the catalog by its id.
///
/// ## Example
///
/// ```gleam
/// type_catalog.lookup(23)
/// // -> Ok(type_catalog.int4())
/// ```
pub fn lookup(id: Int) -> Result(TypeDescription, Nil) {
  list.find(all(), fn(description) { description.id == id })
}

/// The composite type `address` of `public`, with the text fields `street`
/// and `city`.
pub fn address() -> TypeDescription {
  composite(90_200, "address", [#("street", 25), #("city", 25)])
}

/// The composite type `label` of `public`, with the text field `name` and
/// the `ltree` field `path`.
pub fn label() -> TypeDescription {
  composite(90_203, "label", [#("name", 25), #("path", 90_001)])
}

/// A range type whose subtype is in no catalog.
///
/// ## Example
///
/// ```gleam
/// type_catalog.lost_range()
/// ```
pub fn lost_range() -> TypeDescription {
  TypeDescription(
    id: 90_401,
    schema: "public",
    name: "lostrange",
    kind: Range(99_999),
  )
}

/// A multirange type whose range type is in no catalog.
///
/// ## Example
///
/// ```gleam
/// type_catalog.lost_multirange()
/// ```
pub fn lost_multirange() -> TypeDescription {
  TypeDescription(
    id: 90_402,
    schema: "public",
    name: "lost",
    kind: Multirange(99_999),
  )
}

/// A multirange type whose range type is `int4`, which is not a range.
///
/// ## Example
///
/// ```gleam
/// type_catalog.multirange_of_int4()
/// ```
pub fn multirange_of_int4() -> TypeDescription {
  TypeDescription(
    id: 90_403,
    schema: "public",
    name: "odd",
    kind: Multirange(23),
  )
}

/// The composite type `pair`: `left int4, right text`. Not in `all()`.
pub fn pair() -> TypeDescription {
  composite(90_301, "pair", [#("left", 23), #("right", 25)])
}
