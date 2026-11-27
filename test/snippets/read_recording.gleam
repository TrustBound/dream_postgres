import dream_postgres/recording.{type Recording, from_file_bytes}
import gleam/json

/// Reads the bytes of a recording file.
pub fn read_recording(bytes: BitArray) -> Result(Recording, json.DecodeError) {
  from_file_bytes(bytes)
}
