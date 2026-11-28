//// A composite codec for the composite type `address` of the test catalog
//// (`type_catalog.address()`), and the bytes of its values.

import dream_postgres/codecs.{type Codec}
import dream_postgres/codecs/composite
import dream_postgres/row/reader.{column, row}
import gleam/option.{type Option, None}

/// An address: a street and a city that can be NULL.
pub type Address {
  Address(street: String, city: Option(String))
}

/// A codec for the composite type `address`, in the binary format.
///
/// ## Example
///
/// ```gleam
/// Address("1 Main St", Some("Lyon"))
/// |> should
/// |> encode_as(address_codec(), type_catalog.address())
/// ```
pub fn address_codec() -> Codec(Address) {
  composite.composite(
    "address",
    read: {
      use street <- column(codecs.text)
      use city <- column(codecs.nullable(codecs.text))
      row(Address(street:, city:))
    },
    write: address_fields,
    placeholder: Address(street: "", city: None),
  )
}

fn address_fields(address: Address) -> List(composite.Field) {
  [
    composite.field(codecs.text, address.street),
    composite.field(codecs.nullable(codecs.text), address.city),
  ]
}

/// The binary record of the address `1 Main St` in `Lyon`.
pub fn main_street_in_lyon_bytes() -> BitArray {
  <<
    2:size(32),
    25:size(32),
    9:size(32),
    "1 Main St":utf8,
    25:size(32),
    4:size(32),
    "Lyon":utf8,
  >>
}

/// The binary record of the address `1 Main St` with a NULL city.
pub fn main_street_with_no_city_bytes() -> BitArray {
  <<
    2:size(32),
    25:size(32),
    9:size(32),
    "1 Main St":utf8,
    25:size(32),
    -1:size(32),
  >>
}
