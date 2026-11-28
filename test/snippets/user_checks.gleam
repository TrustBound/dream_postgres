import dream_postgres/boot_check.{type QueryCheck, command_check, query_check}
import dream_postgres/codec.{codec_placeholder, int, text}
import dream_postgres/query.{named, parameter, query}
import dream_postgres/row.{column, row}

/// The checks of the queries of the user module. A check uses the codec of
/// each parameter, not its value, so each value is a placeholder.
pub fn queries() -> List(QueryCheck) {
  [
    query("SELECT id, email FROM users WHERE id = $1")
      |> named("user.find")
      |> parameter(int, codec_placeholder(int))
      |> query_check({
        use id <- column(int)
        use email <- column(text)
        row(#(id, email))
      }),
    query("DELETE FROM users WHERE id = $1")
      |> named("user.delete")
      |> parameter(int, codec_placeholder(int))
      |> command_check,
  ]
}
