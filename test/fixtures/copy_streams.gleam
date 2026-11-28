//// Binary COPY data for the tests of the stream reader and writer.

import dream_postgres/driver/cell.{type Cell, Binary, Null}
import gleam/bit_array
import gleam/int
import gleam/result

/// The signature of the binary COPY format.
///
/// ## Example
///
/// ```gleam
/// <<copy_streams.signature():bits, 0:size(32), 0:size(32)>>
/// ```
pub fn signature() -> BitArray {
  <<"PGCOPY\n":utf8, 0xFF, "\r\n":utf8, 0>>
}

/// A header with the flags and the header extension given.
///
/// ## Example
///
/// ```gleam
/// copy_streams.header(flags: 0, extension: <<>>)
/// ```
pub fn header(flags flags: Int, extension extension: BitArray) -> BitArray {
  <<
    signature():bits,
    flags:size(32),
    { bit_array.byte_size(extension) }:size(32),
    extension:bits,
  >>
}

/// The tuples of `stream`: `7, 'Ada'` and `8, NULL`.
///
/// ## Example
///
/// ```gleam
/// copy_streams.tuples()
/// // -> [[Binary(<<7:size(32)>>), Binary(<<"Ada":utf8>>)], [Binary(<<8:size(32)>>), Null]]
/// ```
pub fn tuples() -> List(List(Cell)) {
  [
    [Binary(<<7:size(32)>>), Binary(<<"Ada":utf8>>)],
    [Binary(<<8:size(32)>>), Null],
  ]
}

/// The whole stream of `tuples`, with no flags and no header extension.
///
/// ## Example
///
/// ```gleam
/// copy_streams.stream()
/// // -> <<"PGCOPY\n", 255, "\r\n", 0, 0:32, 0:32, 2:16, ..>>
/// ```
pub fn stream() -> BitArray {
  <<
    header(flags: 0, extension: <<>>):bits,
    2:size(16),
    4:size(32),
    7:size(32),
    3:size(32),
    "Ada":utf8,
    2:size(16),
    4:size(32),
    8:size(32),
    -1:size(32),
    -1:size(16),
  >>
}

/// The bytes in chunks of one byte each.
///
/// ## Example
///
/// ```gleam
/// copy_streams.one_byte_chunks(<<1, 2>>)
/// // -> [<<1>>, <<2>>]
/// ```
pub fn one_byte_chunks(bytes: BitArray) -> List(BitArray) {
  int.range(
    from: bit_array.byte_size(bytes) - 1,
    to: -1,
    with: [],
    run: fn(chunks, position) {
      [bit_array.slice(bytes, position, 1), ..chunks]
    },
  )
  |> result.values
}
