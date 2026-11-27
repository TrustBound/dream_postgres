import dream_postgres/recording.{Recording, to_file_text}

/// The text of a recording with no request:
/// "{\n  \"dream_postgres_recording\": 1,\n  \"entries\": []\n}\n"
pub fn empty_recording_text() -> String {
  to_file_text(Recording(entries: []))
}
