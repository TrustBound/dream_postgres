//// Gleam types and codecs for the temporary types that the probe sessions
//// make (`fixtures/probe_sessions`), and a codec for the text form of a
//// type with no built-in codec.

import dream_postgres/codecs.{type Codec}
import dream_postgres/codecs/composite
import dream_postgres/codecs/numeric
import dream_postgres/row/reader.{column, row}
import gleam/option.{type Option, None}

/// A value of the enum `probe_mood`.
pub type Mood {
  /// The label `sad`.
  Sad
  /// The label `ok`.
  Okay
  /// The label `happy`.
  Happy
}

/// A value of the composite `probe_address`.
pub type Address {
  Address(street: String, number: Int, note: Option(String))
}

/// A value of the composite `probe_line_item`.
pub type LineItem {
  LineItem(amount: String, quantity: Int)
}

/// A value of the composite `probe_order`, which holds a line item.
pub type Order {
  Order(item: LineItem, note: Option(String))
}

/// The codec of the enum `probe_mood`.
///
/// ## Example
///
/// ```gleam
/// codec.array(probe_types.mood_codec())
/// ```
pub fn mood_codec() -> Codec(Mood) {
  codecs.enum("probe_mood", #(Sad, "sad"), [#(Okay, "ok"), #(Happy, "happy")])
}

/// The codec of the composite `probe_address`.
///
/// ## Example
///
/// ```gleam
/// codec.array(probe_types.address_codec())
/// ```
pub fn address_codec() -> Codec(Address) {
  composite.composite(
    "probe_address",
    read: {
      use street <- column(codecs.text)
      use number <- column(codecs.int)
      use note <- column(codecs.nullable(codecs.text))
      row(Address(street:, number:, note:))
    },
    write: fn(address) {
      [
        composite.field(codecs.text, address.street),
        composite.field(codecs.int, address.number),
        composite.field(codecs.nullable(codecs.text), address.note),
      ]
    },
    placeholder: Address(street: "", number: 0, note: None),
  )
}

/// The codec of the composite `probe_line_item`.
///
/// ## Example
///
/// ```gleam
/// codec.array(probe_types.line_item_codec())
/// ```
pub fn line_item_codec() -> Codec(LineItem) {
  composite.composite(
    "probe_line_item",
    read: {
      use amount <- column(numeric.numeric)
      use quantity <- column(codecs.int)
      row(LineItem(amount:, quantity:))
    },
    write: fn(line_item) {
      [
        composite.field(numeric.numeric, line_item.amount),
        composite.field(codecs.int, line_item.quantity),
      ]
    },
    placeholder: LineItem(amount: "0", quantity: 0),
  )
}

/// The codec of the composite `probe_order`, with the line item codec for
/// its first field.
///
/// ## Example
///
/// ```gleam
/// probe_types.order_codec()
/// ```
pub fn order_codec() -> Codec(Order) {
  composite.composite(
    "probe_order",
    read: {
      use item <- column(line_item_codec())
      use note <- column(codecs.nullable(codecs.text))
      row(Order(item:, note:))
    },
    write: fn(order) {
      [
        composite.field(line_item_codec(), order.item),
        composite.field(codecs.nullable(codecs.text), order.note),
      ]
    },
    placeholder: Order(item: LineItem(amount: "0", quantity: 0), note: None),
  )
}

/// A custom codec of the text format that keeps the text form of a type
/// with no built-in codec.
///
/// ## Example
///
/// ```gleam
/// probe_types.text_form_codec("ltree")
/// ```
pub fn text_form_codec(type_name: String) -> Codec(String) {
  codecs.custom(
    type_name:,
    to_text: fn(text) { text },
    from_text: Ok,
    placeholder: "",
  )
}
