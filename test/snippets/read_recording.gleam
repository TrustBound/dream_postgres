import dream_postgres/recording.{type Recording, parse_recording}
import gleam/json

/// Reads the bytes of a recording file.
pub fn read_recording(bytes: BitArray) -> Result(Recording, json.DecodeError) {
  parse_recording(bytes)
}
