//// Rows of a users table `(id int4, email text)` for the COPY tests, with
//// the functions that write and read them.

import dream_postgres/codecs.{type Codec}
import dream_postgres/codecs/composite.{type Field}
import dream_postgres/row.{type Row, column, row, single}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A user: its id, and its email, which can be NULL.
pub type User {
  User(id: Int, email: Option(String))
}

/// Three users, the second with a NULL email.
///
/// ## Example
///
/// ```gleam
/// copy_users.users()
/// // -> [User(1, Some("ada@example.com")), User(2, None), ..]
/// ```
pub fn users() -> List(User) {
  [
    User(id: 1, email: Some("ada@example.com")),
    User(id: 2, email: None),
    User(id: 3, email: Some("grace@example.com")),
  ]
}

/// The fields of a user, for the columns `id, email`.
///
/// ## Example
///
/// ```gleam
/// copy_from(held, into: table("users"), columns: ["id", "email"], rows: copy_users.users(), write: copy_users.user_fields)
/// ```
pub fn user_fields(user: User) -> List(Field) {
  [
    composite.field(codecs.int, user.id),
    composite.field(codecs.nullable(codecs.text), user.email),
  ]
}

/// A reader of the columns `id, email`.
///
/// ## Example
///
/// ```gleam
/// copy_to(held, query("SELECT id, email FROM users"), read: copy_users.user_row(), from: [], with: list.prepend)
/// ```
pub fn user_row() -> Row(User) {
  use id <- column(codecs.int)
  use email <- column(codecs.nullable(codecs.text))
  row(User(id:, email:))
}

/// The ids from 1 to `count`, lowest first.
///
/// ## Example
///
/// ```gleam
/// copy_users.ids(3)
/// // -> [1, 2, 3]
/// ```
pub fn ids(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: list.prepend)
}

/// The field of an id, for the column `id int4`.
///
/// ## Example
///
/// ```gleam
/// copy_users.id_fields(7)
/// // -> [codec.field(codec.int, 7)]
/// ```
pub fn id_fields(id: Int) -> List(Field) {
  [composite.field(codecs.int, id)]
}

/// The field of an id with the text codec, which does not take an `int4`
/// column.
///
/// ## Example
///
/// ```gleam
/// copy_users.text_id_fields(7)
/// // -> [codec.field(codec.text, "7")]
/// ```
pub fn text_id_fields(id: Int) -> List(Field) {
  [composite.field(codecs.text, int.to_string(id))]
}

/// The field of an id with `custom_int4`, a codec in the text format.
///
/// ## Example
///
/// ```gleam
/// copy_users.custom_id_fields(7)
/// // -> [codec.field(copy_users.custom_int4(), 7)]
/// ```
pub fn custom_id_fields(id: Int) -> List(Field) {
  [composite.field(custom_int4(), id)]
}

/// A reader of one column with `custom_int4`.
///
/// ## Example
///
/// ```gleam
/// copy_to(held, query("SELECT 1"), read: copy_users.custom_int4_row(), from: 0, with: int.add)
/// ```
pub fn custom_int4_row() -> Row(Int) {
  single(custom_int4())
}

/// A codec of `int4` in the text format, as `codec.custom` makes one.
///
/// ## Example
///
/// ```gleam
/// codec.field(copy_users.custom_int4(), 7)
/// ```
pub fn custom_int4() -> Codec(Int) {
  codecs.custom(
    type_name: "int4",
    to_text: int.to_string,
    from_text: parse_int,
    placeholder: 0,
  )
}

fn parse_int(text: String) -> Result(Int, String) {
  int.parse(text) |> result.replace_error(text <> " is not an integer")
}
