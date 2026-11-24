//// Recording: write values as JSON

import dream_postgres/recording.{Integer, Null, Text}

pub fn parameters_text() -> String {
  recording.values_to_json([Integer(1), Text("Ada"), Null])
}
