//// The table of type descriptions: what each type OID of a server is.
////
//// The catalog load (`catalog_load` of `driver/housekeeping_sql`) reads
//// `pg_type`, `pg_namespace`, `pg_range`, `pg_enum` and `pg_attribute` in
//// one statement, so all its rows come from one snapshot of the server's
//// catalog. `from_rows` turns those rows into a table. It is pure: it
//// reads no socket and starts no process.
////
//// A table is complete by construction. Each part of a type, such as the
//// element of an array, the base of a domain, the subtype of a range, the
//// range of a multirange or the type of a composite's field, is a type of
//// the same table, and each chain of domains ends at a type that is not a
//// domain. Rows that break these rules give an error, not a table.
////
//// The schema of a type comes from `pg_namespace`, and the name from
//// `pg_type`, so a type has the same description whether its schema is in
//// the `search_path` or not.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, type TypeKind, Array, Base, Composite, Domain,
  Enum, Multirange, Null, Pseudo, Range, Text, TypeDescription,
}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list.{reverse, try_each, try_fold, try_map}
import gleam/option.{type Option}
import gleam/result.{replace_error, try, unwrap}

// Types -----------------------------------------------------------------------

/// The description of each type of one snapshot of the server's catalog.
pub opaque type CatalogTable {
  CatalogTable(
    types: Dict(Int, TypeDescription),
    /// For each domain, the first type of its chain of base types that is
    /// not a domain.
    underlying: Dict(Int, Int),
  )
}

/// Why rows of the catalog query do not make a table.
pub type RowError {
  /// A row that does not have the shape of the catalog query's rows.
  UnreadableRow(row: List(Cell))
  /// A type whose `typtype` is not one that PostgreSQL 16 to 19 have.
  UnknownTypeKind(type_id: Int, kind: String)
  /// A part of a type that is not a type of the rows.
  MissingPart(type_id: Int, part_type_id: Int)
  /// A domain whose chain of base types comes back to a domain of the
  /// chain.
  CircularDomain(type_id: Int)
}

/// The facts of one type row of the catalog query.
type TypeFacts {
  TypeFacts(
    id: Int,
    schema: String,
    name: String,
    /// The `typtype` letter.
    kind: String,
    /// The `typcategory` letter.
    category: String,
    element_type_id: Int,
    base_type_id: Int,
    range_subtype_id: Int,
    multirange_range_id: Int,
  )
}

/// One row of the catalog query.
type Row {
  TypeRow(facts: TypeFacts)
  LabelRow(type_id: Int, label: String)
  FieldRow(type_id: Int, name: String, field_type_id: Int)
}

/// The rows of the catalog query, sorted by their kind. Labels and fields
/// are newest first, and so are the types.
type SortedRows {
  SortedRows(
    types: List(TypeFacts),
    labels: Dict(Int, List(String)),
    fields: Dict(Int, List(#(String, Int))),
  )
}

// Tables ----------------------------------------------------------------------

/// A table with no type.
///
/// ## Returns
///
/// A table in which no type OID is found.
pub fn empty() -> CatalogTable {
  CatalogTable(types: dict.new(), underlying: dict.new())
}

/// Makes a table from the rows of the catalog query, in the order of the
/// query.
///
/// ## Parameters
///
/// - `rows`: the rows of `query`, as text cells
///
/// ## Returns
///
/// - `Ok(CatalogTable)`: each type of the rows, with its parts
/// - `Error(RowError)`: a row that cannot be read, a type kind that is not
///   known, a part that is not a type of the rows, or a circular domain
pub fn from_rows(rows: List(List(Cell))) -> Result(CatalogTable, RowError) {
  let no_rows = SortedRows(types: [], labels: dict.new(), fields: dict.new())
  use sorted <- try(try_fold(rows, no_rows, add_row))
  use descriptions <- try(
    try_map(reverse(sorted.types), describe_type(_, sorted)),
  )
  let types = descriptions |> list.map(keyed_description) |> dict.from_list
  use Nil <- try(try_each(descriptions, check_parts(_, types)))
  use underlying <- try(
    try_map(domain_ids(descriptions), underlying_pair(_, types)),
  )
  Ok(CatalogTable(types:, underlying: dict.from_list(underlying)))
}

/// The description of a type, as the server's catalog has it. A domain is
/// a `Domain` with the OID of its own base type.
///
/// ## Parameters
///
/// - `table`: the table
/// - `type_id`: the type OID
///
/// ## Returns
///
/// - `Some(TypeDescription)`: the type's description
/// - `None`: the table has no type with this OID
pub fn find(table: CatalogTable, type_id: Int) -> Option(TypeDescription) {
  dict.get(table.types, type_id) |> option.from_result
}

/// The description of the type that holds the values of a type: for a
/// domain, the first type of its chain of base types that is not a domain,
/// and for any other type, the type itself.
///
/// ## Parameters
///
/// - `table`: the table
/// - `type_id`: the type OID
///
/// ## Returns
///
/// - `Some(TypeDescription)`: the description of the underlying type
/// - `None`: the table has no type with this OID
pub fn find_underlying(
  table: CatalogTable,
  type_id: Int,
) -> Option(TypeDescription) {
  find(table, dict.get(table.underlying, type_id) |> unwrap(type_id))
}

// Reading the rows ------------------------------------------------------------

fn add_row(
  sorted: SortedRows,
  cells: List(Cell),
) -> Result(SortedRows, RowError) {
  use row <- try(read_row(cells))
  Ok(case row {
    TypeRow(facts:) -> SortedRows(..sorted, types: [facts, ..sorted.types])
    LabelRow(type_id:, label:) ->
      SortedRows(..sorted, labels: prepend(sorted.labels, type_id, label))
    FieldRow(type_id:, name:, field_type_id:) ->
      SortedRows(
        ..sorted,
        fields: prepend(sorted.fields, type_id, #(name, field_type_id)),
      )
  })
}

fn prepend(
  lists: Dict(Int, List(value)),
  key: Int,
  value: value,
) -> Dict(Int, List(value)) {
  dict.insert(lists, key, [value, ..dict.get(lists, key) |> unwrap([])])
}

fn read_row(cells: List(Cell)) -> Result(Row, RowError) {
  case cells {
    [
      Text(<<"type">>),
      Text(id),
      Null,
      Text(schema),
      Text(name),
      Text(kind),
      Text(category),
      Text(element),
      Text(base),
      Text(subtype),
      Text(range),
    ] ->
      read_type_row(cells, #(id, element, base, subtype, range), #(
        schema,
        name,
        kind,
        category,
      ))
    [Text(<<"label">>), Text(id), Text(_position), Text(label), ..rest] ->
      read_label_row(cells, id, label, rest)
    [
      Text(<<"field">>),
      Text(id),
      Text(_position),
      Text(name),
      Text(field_type),
      ..rest
    ] -> read_field_row(cells, id, name, field_type, rest)
    _other -> Error(UnreadableRow(cells))
  }
}

fn read_type_row(
  cells: List(Cell),
  numbers: #(BitArray, BitArray, BitArray, BitArray, BitArray),
  texts: #(BitArray, BitArray, BitArray, BitArray),
) -> Result(Row, RowError) {
  use id <- try(number_of(numbers.0, cells))
  use element_type_id <- try(number_of(numbers.1, cells))
  use base_type_id <- try(number_of(numbers.2, cells))
  use range_subtype_id <- try(number_of(numbers.3, cells))
  use multirange_range_id <- try(number_of(numbers.4, cells))
  use schema <- try(text_of(texts.0, cells))
  use name <- try(text_of(texts.1, cells))
  use kind <- try(text_of(texts.2, cells))
  use category <- try(text_of(texts.3, cells))
  Ok(
    TypeRow(TypeFacts(
      id:,
      schema:,
      name:,
      kind:,
      category:,
      element_type_id:,
      base_type_id:,
      range_subtype_id:,
      multirange_range_id:,
    )),
  )
}

fn read_label_row(
  cells: List(Cell),
  id: BitArray,
  label: BitArray,
  rest: List(Cell),
) -> Result(Row, RowError) {
  use Nil <- try(all_null(rest, 7, cells))
  use type_id <- try(number_of(id, cells))
  use label <- try(text_of(label, cells))
  Ok(LabelRow(type_id:, label:))
}

fn read_field_row(
  cells: List(Cell),
  id: BitArray,
  name: BitArray,
  field_type: BitArray,
  rest: List(Cell),
) -> Result(Row, RowError) {
  use Nil <- try(all_null(rest, 6, cells))
  use type_id <- try(number_of(id, cells))
  use name <- try(text_of(name, cells))
  use field_type_id <- try(number_of(field_type, cells))
  Ok(FieldRow(type_id:, name:, field_type_id:))
}

/// The cells after the facts of a label or a field row are all NULL.
fn all_null(
  rest: List(Cell),
  count: Int,
  cells: List(Cell),
) -> Result(Nil, RowError) {
  case rest == list.repeat(Null, count) {
    True -> Ok(Nil)
    False -> Error(UnreadableRow(cells))
  }
}

fn text_of(bytes: BitArray, cells: List(Cell)) -> Result(String, RowError) {
  bit_array.to_string(bytes) |> replace_error(UnreadableRow(cells))
}

fn number_of(bytes: BitArray, cells: List(Cell)) -> Result(Int, RowError) {
  use text <- try(text_of(bytes, cells))
  int.parse(text) |> replace_error(UnreadableRow(cells))
}

// Describing the types --------------------------------------------------------

fn describe_type(
  facts: TypeFacts,
  sorted: SortedRows,
) -> Result(TypeDescription, RowError) {
  use kind <- try(kind_of(facts, sorted))
  Ok(TypeDescription(
    id: facts.id,
    schema: facts.schema,
    name: facts.name,
    kind:,
  ))
}

/// The kind of a type from its `typtype`. A base type of the category `A`
/// with an element type is an array, also `int2vector` and `oidvector`,
/// whose binary form is the form of an array. Other base types with an
/// element type, such as `name` or `point`, are base types.
fn kind_of(facts: TypeFacts, sorted: SortedRows) -> Result(TypeKind, RowError) {
  case facts.kind, facts.category {
    "b", "A" if facts.element_type_id != 0 -> Ok(Array(facts.element_type_id))
    "b", _category -> Ok(Base)
    "c", _category -> Ok(Composite(in_order(sorted.fields, facts.id)))
    "d", _category -> Ok(Domain(facts.base_type_id))
    "e", _category -> Ok(Enum(in_order(sorted.labels, facts.id)))
    "r", _category -> Ok(Range(facts.range_subtype_id))
    "m", _category -> Ok(Multirange(facts.multirange_range_id))
    "p", _category -> Ok(Pseudo)
    other, _category -> Error(UnknownTypeKind(facts.id, other))
  }
}

/// The labels or the fields of a type, in the order of the query.
fn in_order(lists: Dict(Int, List(value)), type_id: Int) -> List(value) {
  dict.get(lists, type_id) |> unwrap([]) |> reverse
}

fn keyed_description(description: TypeDescription) -> #(Int, TypeDescription) {
  #(description.id, description)
}

// Checking the table ----------------------------------------------------------

fn check_parts(
  description: TypeDescription,
  types: Dict(Int, TypeDescription),
) -> Result(Nil, RowError) {
  parts_of(description.kind) |> try_each(check_part(_, description.id, types))
}

fn check_part(
  part_type_id: Int,
  type_id: Int,
  types: Dict(Int, TypeDescription),
) -> Result(Nil, RowError) {
  dict.get(types, part_type_id)
  |> result.replace(Nil)
  |> replace_error(MissingPart(type_id:, part_type_id:))
}

/// The type OIDs that a kind names.
fn parts_of(kind: TypeKind) -> List(Int) {
  case kind {
    Base | Enum(..) | Pseudo -> []
    Composite(fields:) -> list.map(fields, field_type_id)
    Domain(base_type_id:) -> [base_type_id]
    Range(element_type_id:) -> [element_type_id]
    Multirange(range_type_id:) -> [range_type_id]
    Array(element_type_id:) -> [element_type_id]
  }
}

fn field_type_id(field: #(String, Int)) -> Int {
  field.1
}

fn domain_ids(descriptions: List(TypeDescription)) -> List(Int) {
  list.filter_map(descriptions, domain_id)
}

fn domain_id(description: TypeDescription) -> Result(Int, Nil) {
  case description.kind {
    Domain(..) -> Ok(description.id)
    _other -> Error(Nil)
  }
}

/// A domain with the first type of its chain that is not a domain. A
/// chain longer than the number of types comes back to itself.
fn underlying_pair(
  domain_id: Int,
  types: Dict(Int, TypeDescription),
) -> Result(#(Int, Int), RowError) {
  use underlying <- try(follow_chain(
    types,
    domain_id,
    domain_id,
    dict.size(types),
  ))
  Ok(#(domain_id, underlying))
}

fn follow_chain(
  types: Dict(Int, TypeDescription),
  type_id: Int,
  domain_id: Int,
  steps_left: Int,
) -> Result(Int, RowError) {
  case dict.get(types, type_id), steps_left {
    Ok(TypeDescription(kind: Domain(..), ..)), 0 ->
      Error(CircularDomain(domain_id))
    Ok(TypeDescription(kind: Domain(base_type_id:), ..)), _steps_left ->
      follow_chain(types, base_type_id, domain_id, steps_left - 1)
    _not_a_domain, _steps_left -> Ok(type_id)
  }
}
