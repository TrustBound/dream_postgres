import dream_postgres/recording.{Recording, format_recording}

/// The text of a recording with no request:
/// "{\n  \"dream_postgres_recording\": 1,\n  \"entries\": []\n}\n"
pub fn empty_recording_text() -> String {
  format_recording(Recording(entries: []))
}
