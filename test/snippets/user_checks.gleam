import dream_postgres.{
  type QueryCheck, checked, checked_command, column, named, parameter, query,
  row,
}
import dream_postgres/codec.{int, placeholder, text}

/// The checks of the queries of the user module. A check uses the codec of
/// each parameter, not its value, so each value is a placeholder.
pub fn queries() -> List(QueryCheck) {
  [
    query("SELECT id, email FROM users WHERE id = $1")
      |> named("user.find")
      |> parameter(int, placeholder(int))
      |> checked({
        use id <- column(int)
        use email <- column(text)
        row(#(id, email))
      }),
    query("DELETE FROM users WHERE id = $1")
      |> named("user.delete")
      |> parameter(int, placeholder(int))
      |> checked_command,
  ]
}
