//// The binary format of PostgreSQL's COPY (`FORMAT binary`): the
//// identifiers of a COPY statement, and the data stream in both
//// directions.
////
//// The stream is a header, the tuples, and a trailer. The header is the
//// signature `PGCOPY\n\377\r\n\0`, the flags (32 bits) and the length of a
//// header extension (32 bits) with its bytes. Each tuple is its field
//// count (16 bits), then for each field its length (32 bits, -1 for NULL)
//// and its bytes. The trailer is the field count -1.

import dream_postgres/driver/cell.{type Cell, Binary, Null}
import dream_postgres/error.{
  type CopyStreamFault, BytesAfterCopyTrailer, CopyStreamCutShort,
  InvalidCopyFieldCount, InvalidCopyFieldLength, InvalidCopySignature,
  UnsupportedCopyFlags,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const signature = <<"PGCOPY\n":utf8, 0xFF, "\r\n":utf8, 0>>

/// The flags that a reader must know: bits 0 to 15 are critical, and bit
/// 16 says that each tuple has an OID. Bits 17 to 31 can be ignored.
const critical_flags = 0x1FFFF

// --- Identifiers -------------------------------------------------------------

/// The name as a quoted PostgreSQL identifier: in double quotes, with each
/// double quote in it doubled. The name is taken as it is, with its case,
/// its spaces and its dots.
pub fn quote_identifier(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

/// The quoted names, separated by commas.
pub fn quote_identifiers(names: List(String)) -> String {
  names |> list.map(quote_identifier) |> string.join(", ")
}

// --- Writing -----------------------------------------------------------------

/// The header of a stream with no flags and no header extension.
pub fn header() -> BitArray {
  <<signature:bits, 0:size(32), 0:size(32)>>
}

/// The trailer of a stream.
pub fn trailer() -> BitArray {
  <<-1:size(16)>>
}

/// One tuple: the bytes of each field in order, or `None` for NULL.
pub fn encode_tuple(fields: List(Option(BitArray))) -> BitArray {
  list.fold(fields, <<{ list.length(fields) }:size(16)>>, encode_field)
}

fn encode_field(tuple: BitArray, field: Option(BitArray)) -> BitArray {
  case field {
    Some(bytes) -> <<
      tuple:bits,
      { bit_array.byte_size(bytes) }:size(32),
      bytes:bits,
    >>
    None -> <<tuple:bits, -1:size(32)>>
  }
}

// --- Reading -----------------------------------------------------------------

/// What the reader of a stream has read so far.
pub opaque type StreamReader {
  StreamReader(stage: Stage, buffer: BitArray)
}

type Stage {
  AwaitingHeader
  ReadingTuples
  Ended
}

// One part of a stream.
type Part {
  HeaderPart
  TuplePart(cells: List(Cell))
  TrailerPart
}

// What one parse step found: a whole part with the bytes after it, or
// too few bytes to tell yet.
type Parsed {
  Complete(part: Part, rest: BitArray)
  Incomplete
}

/// A reader at the start of a stream.
pub fn new_reader() -> StreamReader {
  StreamReader(stage: AwaitingHeader, buffer: <<>>)
}

/// Reads the next chunk of a stream. A chunk can end anywhere, also inside
/// the header or a field: the reader keeps the bytes of a part that is not
/// whole yet, for the next chunk. Gives the tuples that the chunk ended,
/// each as one cell for each field.
pub fn read_chunk(
  reader: StreamReader,
  chunk: BitArray,
) -> Result(#(StreamReader, List(List(Cell))), CopyStreamFault) {
  read_parts(reader.stage, <<reader.buffer:bits, chunk:bits>>, [])
}

/// Checks that the stream ended with its trailer.
pub fn finish(reader: StreamReader) -> Result(Nil, CopyStreamFault) {
  case reader.stage {
    Ended -> Ok(Nil)
    AwaitingHeader | ReadingTuples -> Error(CopyStreamCutShort)
  }
}

fn read_parts(
  stage: Stage,
  buffer: BitArray,
  tuples: List(List(Cell)),
) -> Result(#(StreamReader, List(List(Cell))), CopyStreamFault) {
  case stage {
    AwaitingHeader ->
      parse_header(buffer) |> result.try(next_part(_, stage, buffer, tuples))
    ReadingTuples ->
      parse_tuple(buffer) |> result.try(next_part(_, stage, buffer, tuples))
    Ended -> after_trailer(buffer, tuples)
  }
}

// Goes on after one parse step: with the bytes after a whole part, or with
// the reader that waits for more bytes.
fn next_part(
  parsed: Parsed,
  stage: Stage,
  buffer: BitArray,
  tuples: List(List(Cell)),
) -> Result(#(StreamReader, List(List(Cell))), CopyStreamFault) {
  case parsed {
    Complete(part: HeaderPart, rest:) -> read_parts(ReadingTuples, rest, tuples)
    Complete(part: TuplePart(cells:), rest:) ->
      read_parts(ReadingTuples, rest, [cells, ..tuples])
    Complete(part: TrailerPart, rest:) -> read_parts(Ended, rest, tuples)
    Incomplete -> Ok(#(StreamReader(stage:, buffer:), list.reverse(tuples)))
  }
}

fn after_trailer(
  buffer: BitArray,
  tuples: List(List(Cell)),
) -> Result(#(StreamReader, List(List(Cell))), CopyStreamFault) {
  case buffer {
    <<>> -> Ok(#(StreamReader(stage: Ended, buffer:), list.reverse(tuples)))
    _ -> Error(BytesAfterCopyTrailer)
  }
}

fn parse_header(buffer: BitArray) -> Result(Parsed, CopyStreamFault) {
  case buffer {
    <<
      "PGCOPY\n":utf8,
      0xFF,
      "\r\n":utf8,
      0,
      flags:size(32),
      extension_length:size(32),
      _extension:bytes-size(extension_length),
      rest:bits,
    >> -> check_flags(flags, rest)
    _ -> partial_header(buffer)
  }
}

fn check_flags(flags: Int, rest: BitArray) -> Result(Parsed, CopyStreamFault) {
  case int.bitwise_and(flags, critical_flags) {
    0 -> Ok(Complete(part: HeaderPart, rest:))
    _ -> Error(UnsupportedCopyFlags(flags:))
  }
}

// Too few bytes for the whole header: valid while the bytes so far agree
// with the signature.
fn partial_header(buffer: BitArray) -> Result(Parsed, CopyStreamFault) {
  let size =
    int.min(bit_array.byte_size(buffer), bit_array.byte_size(signature))
  case bit_array.slice(buffer, 0, size) == bit_array.slice(signature, 0, size) {
    True -> Ok(Incomplete)
    False -> Error(InvalidCopySignature)
  }
}

// A tuple, or the trailer.
fn parse_tuple(buffer: BitArray) -> Result(Parsed, CopyStreamFault) {
  case buffer {
    <<-1:signed-size(16), rest:bits>> -> Ok(Complete(part: TrailerPart, rest:))
    <<count:signed-size(16), rest:bits>> if count >= 0 ->
      parse_fields(rest, count, [])
    <<count:signed-size(16), _rest:bits>> ->
      Error(InvalidCopyFieldCount(count:))
    _ -> Ok(Incomplete)
  }
}

fn parse_fields(
  buffer: BitArray,
  remaining: Int,
  cells: List(Cell),
) -> Result(Parsed, CopyStreamFault) {
  case remaining, buffer {
    0, _ -> Ok(Complete(part: TuplePart(list.reverse(cells)), rest: buffer))
    _, <<-1:signed-size(32), rest:bits>> ->
      parse_fields(rest, remaining - 1, [Null, ..cells])
    _, <<length:signed-size(32), _rest:bits>> if length < -1 ->
      Error(InvalidCopyFieldLength(length:))
    _, <<length:signed-size(32), field:bytes-size(length), rest:bits>> ->
      parse_fields(rest, remaining - 1, [Binary(field), ..cells])
    _, _ -> Ok(Incomplete)
  }
}
