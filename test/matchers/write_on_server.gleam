//// A matcher that sends the value of the chain to a probe server as `$1`
//// and gives the server's text of it.

import dream_postgres/codec.{type Codec}
import dream_postgres/codecs/codec_type
import dream_postgres/driver/cell.{
  type TypeDescription, Binary, Null, Text, TextFormat,
}
import dream_postgres/driver/connection/extended_query as connection_extended_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import fixtures/probe_sessions.{type ProbeSession, type ProbeSessions}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Write the value with `codec` as the parameter of
/// `SELECT $1::<type_sql>::text` on the server of the chosen version. The
/// chain goes on with the result: the server's text of the value, `None`
/// for NULL, or the reason that the probe failed.
///
/// ## Example
///
/// ```gleam
/// 7
/// |> should
/// |> write_on_server(sessions, codec.int, "int4")
/// |> be_ok()
/// |> be_some()
/// |> be_equal("7")
/// |> or_fail_with("Expected the server text 7")
/// ```
pub fn write_on_server(
  result: MatchResult(a),
  sessions: ProbeSessions,
  codec: Codec(a),
  type_sql: String,
) -> MatchResult(Result(Option(String), String)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(value) -> write_on_chosen(sessions, codec, value, type_sql)
  }
}

fn write_on_chosen(
  sessions: ProbeSessions,
  codec: Codec(a),
  value: a,
  type_sql: String,
) -> MatchResult(Result(Option(String), String)) {
  case probe_sessions.chosen(sessions) {
    Ok(session) -> MatchOk(server_text(session, codec, value, type_sql))
    Error(reason) ->
      MatchFailed(AssertionFailure(
        operator: "write_on_server",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: reason,
          description: "expected a probe session of the chosen version",
        )),
      ))
  }
}

fn server_text(
  session: ProbeSession,
  codec: Codec(a),
  value: a,
  type_sql: String,
) -> Result(Option(String), String) {
  let sql = "SELECT $1::" <> type_sql <> "::text"
  use statement <- result.try(
    connection_extended_query.prepare(
      session.connection,
      connection_statement.statement(sql),
      probe_sessions.deadline_milliseconds,
    )
    |> result.map_error(string.inspect),
  )
  use parameter <- result.try(
    list.first(statement.parameters)
    |> result.replace_error("the statement has no parameter"),
  )
  use parameter_type <- result.try(probe_sessions.type_of(
    session,
    parameter.type_id,
  ))
  use _ <- result.try(check_accepts(session, codec, parameter_type))
  use parameter_cell <- result.try(codec_type.encode(
    codec,
    value,
    parameter_type,
    probe_sessions.lookup(session),
  ))
  use outcome <- result.try(
    connection_extended_query.run(
      session.connection,
      connection_statement.statement(sql),
      [parameter_cell],
      [TextFormat],
      probe_sessions.deadline_milliseconds,
    )
    |> result.map_error(string.inspect),
  )
  use first <- result.try(probe_sessions.first_cell(outcome))
  case first {
    Text(bytes:) ->
      bit_array.to_string(bytes)
      |> result.map(Some)
      |> result.replace_error("the server text is not UTF-8")
    Null -> Ok(None)
    Binary(..) -> Error("the server sent binary for a text column")
  }
}

fn check_accepts(
  session: ProbeSession,
  codec: Codec(a),
  description: TypeDescription,
) -> Result(Nil, String) {
  case codec_type.accepts(codec, description, probe_sessions.lookup(session)) {
    True -> Ok(Nil)
    False ->
      Error(codec_type.name(codec) <> " does not take " <> description.name)
  }
}
