//// Row readers that choose what they read from a value they read. The
//// check of a reader sees only the branch of the placeholder value of each
//// codec, 0 for `codec.int`, so a read must refuse another branch.

import dream_postgres/codec
import dream_postgres/internal/row_reader.{type Row, column, row}
import gleam/option.{type Option, None, Some}

/// A reader of `kind int4, name text` that reads the name only when the
/// kind is 0, and stops after the kind for any other kind.
///
/// ## Example
///
/// ```gleam
/// value_dependent_readers.branching()
/// |> should
/// |> read_row(columns, [Binary(<<0:size(32)>>), Binary(<<"Ada":utf8>>)])
/// // -> Ok(#(0, Some("Ada")))
/// ```
pub fn branching() -> Row(#(Int, Option(String))) {
  use kind <- column(codec.int)
  case kind {
    0 -> {
      use name <- column(codec.text)
      row(#(kind, Some(name)))
    }
    _ -> row(#(kind, None))
  }
}

/// A reader of `kind int4` and a second column that reads the second
/// column with `codec.text` when the kind is 0, and with `codec.numeric`
/// for any other kind.
///
/// ## Example
///
/// ```gleam
/// value_dependent_readers.switching()
/// |> should
/// |> read_row(columns, [Binary(<<1:size(32)>>), Binary(<<"Ada":utf8>>)])
/// // -> Error(ReaderDependsOnValue(read: 2))
/// ```
pub fn switching() -> Row(#(Int, String)) {
  use kind <- column(codec.int)
  case kind {
    0 -> {
      use name <- column(codec.text)
      row(#(kind, name))
    }
    _ -> {
      use score <- column(codec.numeric)
      row(#(kind, score))
    }
  }
}
