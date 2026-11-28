//// Gleam types and codecs for the temporary types that the probe sessions
//// make (`fixtures/probe_sessions`), and a codec for the text form of a
//// type with no built-in codec.

import dream_postgres/codec.{type Codec}
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
  codec.enum("probe_mood", #(Sad, "sad"), [#(Okay, "ok"), #(Happy, "happy")])
}

/// The codec of the composite `probe_address`.
///
/// ## Example
///
/// ```gleam
/// codec.array(probe_types.address_codec())
/// ```
pub fn address_codec() -> Codec(Address) {
  codec.composite(
    "probe_address",
    read: {
      use street <- column(codec.text)
      use number <- column(codec.int)
      use note <- column(codec.nullable(codec.text))
      row(Address(street:, number:, note:))
    },
    write: fn(address) {
      [
        codec.field(codec.text, address.street),
        codec.field(codec.int, address.number),
        codec.field(codec.nullable(codec.text), address.note),
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
  codec.composite(
    "probe_line_item",
    read: {
      use amount <- column(codec.numeric)
      use quantity <- column(codec.int)
      row(LineItem(amount:, quantity:))
    },
    write: fn(line_item) {
      [
        codec.field(codec.numeric, line_item.amount),
        codec.field(codec.int, line_item.quantity),
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
  codec.composite(
    "probe_order",
    read: {
      use item <- column(line_item_codec())
      use note <- column(codec.nullable(codec.text))
      row(Order(item:, note:))
    },
    write: fn(order) {
      [
        codec.field(line_item_codec(), order.item),
        codec.field(codec.nullable(codec.text), order.note),
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
  codec.custom(
    type_name:,
    to_text: fn(text) { text },
    from_text: Ok,
    placeholder: "",
  )
}
