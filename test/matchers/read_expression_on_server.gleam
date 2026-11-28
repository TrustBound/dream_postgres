//// A matcher that runs `SELECT <expression>` on a probe server, with the
//// expression of the chain, and reads the value with a codec.

import dream_postgres/codec.{type Codec}
import dream_postgres/codec/codec_type
import dream_postgres/driver/connection/extended_query as connection_extended_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/probe_sessions.{
  type ProbeSession, type ProbeSessions, type ReadFailure, ReadDecodeFailed,
  ReadNotAccepted, ReadRefused,
}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

/// Run `SELECT <expression>` on the server of the chosen version, in the
/// format of `codec`, and read the cell with `codec`. The chain goes on
/// with the result: the value, or why the read gave no value.
///
/// ## Example
///
/// ```gleam
/// "ROW(1.5::numeric, 'a')"
/// |> should
/// |> read_expression_on_server(sessions, record_codec)
/// |> be_ok()
/// |> be_equal("(1.5,a)")
/// |> or_fail_with("Expected the text form of the record")
/// ```
pub fn read_expression_on_server(
  result: MatchResult(String),
  sessions: ProbeSessions,
  codec: Codec(a),
) -> MatchResult(Result(a, ReadFailure)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(expression) -> read_on_chosen(sessions, codec, expression)
  }
}

fn read_on_chosen(
  sessions: ProbeSessions,
  codec: Codec(a),
  expression: String,
) -> MatchResult(Result(a, ReadFailure)) {
  case probe_sessions.chosen(sessions) {
    Ok(session) -> MatchOk(read_value(session, codec, expression))
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "read_expression_on_server",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected a probe session of the chosen version",
        )),
      ))
  }
}

fn read_value(
  session: ProbeSession,
  codec: Codec(a),
  expression: String,
) -> Result(a, ReadFailure) {
  let sql = "SELECT " <> expression
  use outcome <- result.try(
    connection_extended_query.run(
      session.connection,
      connection_statement.statement(sql),
      [],
      [codec_type.format(codec)],
      probe_sessions.deadline_milliseconds,
    )
    |> result.map_error(fn(error) { ReadRefused(string.inspect(error)) }),
  )
  use first <- result.try(
    probe_sessions.first_cell(outcome) |> result.map_error(ReadRefused),
  )
  use column <- result.try(
    list.first(outcome.columns)
    |> result.replace_error(ReadRefused("the result has no column")),
  )
  use column_type <- result.try(
    probe_sessions.type_of(session, column.type_id)
    |> result.map_error(ReadRefused),
  )
  use _ <- result.try(
    case
      codec_type.accepts(codec, column_type, probe_sessions.lookup(session))
    {
      True -> Ok(Nil)
      False -> Error(ReadNotAccepted(codec_type.name(codec), column_type.name))
    },
  )
  codec_type.decode(codec, first, column_type, probe_sessions.lookup(session))
  |> result.map_error(ReadDecodeFailed)
}
