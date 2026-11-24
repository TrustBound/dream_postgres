import dream_postgres/client as postgres
import gleam/string

pub fn describe_connection(url: String) -> String {
  case postgres.from_url(url) {
    Ok(_connection) -> "The pool started"
    Error(postgres.InvalidUrl(error)) ->
      "Invalid URL: " <> string.inspect(error)
    Error(error) -> "The pool did not start: " <> string.inspect(error)
  }
}
