//// A composite codec for the composite type `address` of the test catalog
//// (`type_catalog.address()`), and the bytes of its values.

import dream_postgres/codec.{type Codec}
import dream_postgres/internal/row_reader.{column, row}
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
  codec.composite(
    "address",
    read: {
      use street <- column(codec.text)
      use city <- column(codec.nullable(codec.text))
      row(Address(street:, city:))
    },
    write: address_fields,
    placeholder: Address(street: "", city: None),
  )
}

fn address_fields(address: Address) -> List(codec.Field) {
  [
    codec.field(codec.text, address.street),
    codec.field(codec.nullable(codec.text), address.city),
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
