//// A matcher that reads chunks of binary COPY data to their end.

import dream_postgres/error.{type CopyStreamFault}
import dream_postgres/internal/cell.{type Cell}
import dream_postgres/internal/copy_stream.{type StreamReader}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import gleam/list
import gleam/result

/// Read each chunk in order with one stream reader, then check that the
/// stream ended. The chain goes on with every tuple read, in order, or
/// with the first fault.
///
/// ## Example
///
/// ```gleam
/// [copy_stream.header(), copy_stream.trailer()]
/// |> should
/// |> read_copy_stream()
/// |> be_equal(Ok([]))
/// |> or_fail_with("Expected an empty stream")
/// ```
pub fn read_copy_stream(
  result: MatchResult(List(BitArray)),
) -> MatchResult(Result(List(List(Cell)), CopyStreamFault)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(chunks) -> MatchOk(read_all(chunks))
  }
}

fn read_all(
  chunks: List(BitArray),
) -> Result(List(List(Cell)), CopyStreamFault) {
  use #(reader, tuples) <- result.try(list.try_fold(
    chunks,
    #(copy_stream.new_reader(), []),
    read_one,
  ))
  copy_stream.finish(reader) |> result.replace(tuples)
}

fn read_one(
  read_so_far: #(StreamReader, List(List(Cell))),
  chunk: BitArray,
) -> Result(#(StreamReader, List(List(Cell))), CopyStreamFault) {
  let #(reader, tuples) = read_so_far
  copy_stream.read_chunk(reader, chunk)
  |> result.map(fn(read) { #(read.0, list.append(tuples, read.1)) })
}
