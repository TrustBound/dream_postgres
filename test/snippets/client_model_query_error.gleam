import dream_postgres/client as postgres
import gleam/string

pub fn log_line(error: postgres.ModelQueryError) -> String {
  case error {
    postgres.QueryFailed(message:, cause:) ->
      message <> ": " <> string.inspect(cause)
    postgres.NotFound -> "not found"
    postgres.Conflict(constraint:) -> "conflict on " <> constraint
  }
}
