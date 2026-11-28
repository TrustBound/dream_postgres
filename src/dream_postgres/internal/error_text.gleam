//// The wording of the parts of an error message that depend on plain values: a
//// column, a timeout, and the statements that ran.

import gleam/int

pub fn column_text(position: Int, name: String) -> String {
  "column " <> int.to_string(position) <> " (" <> name <> ")"
}

pub fn timeout_message(stopped_on_server: Bool) -> String {
  case stopped_on_server {
    True -> "the query did not finish in time"
    False ->
      "the query did not finish in time, and the server did not confirm that it stopped"
  }
}

pub fn statements_run_text(statements_run: Int) -> String {
  case statements_run {
    0 -> ""
    _ ->
      "; the SQL ran "
      <> int.to_string(statements_run)
      <> " of its statements before it, and outside a transaction they are committed"
  }
}

pub fn statement_ran_text(statement_ran: Bool) -> String {
  case statement_ran {
    True ->
      "; the statement ran to its end, and outside a transaction it is committed"
    False -> ""
  }
}
