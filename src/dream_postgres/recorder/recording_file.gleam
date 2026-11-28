//// The recording file: reading it from disk and writing it to disk.

import dream_postgres/error.{type Reason, RecordingNotDecoded, RecordingNotRead}
import dream_postgres/posix.{type Posix}
import dream_postgres/recording.{type RecordedEntry, Recording}
import gleam/json
import gleam/result

pub fn write_recording(
  path: String,
  entries: List(RecordedEntry),
) -> Result(Nil, Posix) {
  write_file(path, <<recording.format_recording(Recording(entries:)):utf8>>)
}

pub fn read_recording(path: String) -> Result(List(RecordedEntry), Reason) {
  use bytes <- result.try(
    read_file(path) |> result.map_error(RecordingNotRead(path, _)),
  )
  recording.parse_recording(bytes)
  |> result.map(fn(read) { read.entries })
  |> result.map_error(fn(decode_error: json.DecodeError) {
    RecordingNotDecoded(path:, reason: decode_error)
  })
}

@external(erlang, "dream_postgres_recorder_ffi", "write_file")
fn write_file(path: String, bytes: BitArray) -> Result(Nil, Posix)

@external(erlang, "dream_postgres_recorder_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, Posix)

@external(erlang, "dream_postgres_recorder_ffi", "is_file")
pub fn is_file(path: String) -> Bool
