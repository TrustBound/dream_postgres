//// A composite codec for the composite type `label` of the test catalog
//// (`type_catalog.label()`), whose `path` field has a codec in the text
//// format.

import dream_postgres/codec
import dream_postgres/codec/codec_type.{type Codec}
import dream_postgres/codec/composite as composite_codecs
import dream_postgres/query/definition
import dream_postgres/row/reader.{column, row}
import fixtures/ltree_codec.{ltree_codec}

/// A codec for the composite type `label`: a name and an `ltree` path. A
/// composite field needs a codec in the binary format, so the codec does
/// not take the type and cannot write a value.
///
/// ## Example
///
/// ```gleam
/// #("home", "top.home")
/// |> should
/// |> encode_as(label_codec(), type_catalog.label())
/// ```
pub fn label_codec() -> Codec(#(String, String)) {
  composite_codecs.composite(
    type_name: "label",
    read: {
      use name <- column(codec.text)
      use path <- column(ltree_codec())
      row(#(name, path))
    },
    write: label_fields,
    placeholder: #("", ""),
  )
}

fn label_fields(label: #(String, String)) -> List(codec.Field) {
  [
    definition.value_of(codec.text, label.0),
    definition.value_of(ltree_codec(), label.1),
  ]
}
