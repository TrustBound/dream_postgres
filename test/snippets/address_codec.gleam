import dream_postgres.{column, row}
import dream_postgres/codec.{
  type Codec, type Field, composite, field, nullable, text,
}
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
