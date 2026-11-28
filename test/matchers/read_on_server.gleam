//// A matcher that reads a literal of a type on a probe server with a codec.

import dream_postgres/codecs.{type Codec}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/probe_sessions.{type ProbeSessions, type ReadFailure}
import gleam/option.{type Option, None, Some}
import gleam/string
import matchers/read_expression_on_server.{read_expression_on_server}

/// Run `SELECT <literal>::<type_sql>` on the server of the chosen version,
/// with the literal of the chain (`None` for NULL), and read the cell with
/// `codec`. The chain goes on with the result: the value, or why the read
/// gave no value.
///
/// ## Example
///
/// ```gleam
/// Some("7")
/// |> should
/// |> read_on_server(sessions, codec.int, "int4")
/// |> be_ok()
/// |> be_equal(7)
/// |> or_fail_with("Expected the int4 7 to read as 7")
/// ```
pub fn read_on_server(
  result: MatchResult(Option(String)),
  sessions: ProbeSessions,
  codec: Codec(a),
  type_sql: String,
) -> MatchResult(Result(a, ReadFailure)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(literal) ->
      MatchOk(quoted_literal(literal) <> "::" <> type_sql)
      |> read_expression_on_server(sessions, codec)
  }
}

fn quoted_literal(literal: Option(String)) -> String {
  case literal {
    Some(text) -> "'" <> string.replace(text, "'", "''") <> "'"
    None -> "NULL"
  }
}
