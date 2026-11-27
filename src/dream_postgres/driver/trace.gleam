//// The OpenTelemetry span of each statement of a connection (see
//// `dream_postgres_trace_ffi.erl`). The span starts and ends in the
//// caller's process, so it is a child of the caller's current span. With
//// no OpenTelemetry SDK running, each call is a no-op of the API.
////
//// The attributes follow the OTel semantic conventions for PostgreSQL
//// (open-telemetry/semantic-conventions at commit 7c8eb86d04,
//// docs/db/postgresql.md and docs/db/database-spans.md). No parameter
//// value is ever recorded.
////
//// A span records a call that the app made through `prepare`, `run`,
//// `run_simple_query`, `copy_from` or `copy_to`. The statements that the driver
//// sends for its own housekeeping, from its own processes, make no span:
//// the catalog load and a pool member's ROLLBACK and health check go
//// through `run_housekeeping` and `run_housekeeping_simple_query`, and a
//// listener's LISTEN and UNLISTEN go through `run_listener_simple_query`, which
//// no span wraps. They have no caller span to nest under, and would be a
//// root span for each idle connection at each health check.
////
//// This module is internal to dream_postgres.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A span that runs.
pub opaque type Span {
  Span(
    context: SpanContext,
    /// The target that names the span when the caller gave no summary,
    /// for the rename at its end. `None` when the summary names it.
    target_without_summary: Option(String),
  )
}

/// The OpenTelemetry context of a span that runs.
type SpanContext

/// What the span of a statement of a connection names: the database and
/// the server of the connection's settings.
pub type SpanTarget {
  SpanTarget(database: String, host: String, port: Int)
}

/// What a statement adds to its span.
pub type SpanQuery {
  SpanQuery(
    /// The caller's low-cardinality name of the statement, if any.
    summary: Option(String),
    /// The statement's text, for a statement whose values are parameters.
    text: Option(String),
  )
}

/// How the statement ended, for its span.
pub type SpanEnd {
  /// It worked. `operation` is the operation of the server's command tag,
  /// when there is exactly one tag. `warning_code` is the SQLSTATE of the
  /// last warning (class 01) that the statement got, if any.
  Worked(operation: Option(String), warning_code: Option(String))
  /// It failed. `error_type` names the error; `status_code` is the
  /// server's SQLSTATE, when the server gave one.
  Failed(error_type: String, status_code: Option(String))
}

/// The default PostgreSQL port: a span leaves out `server.port` for it.
const default_port = 5432

/// Starts the span of a statement.
///
/// ## Parameters
///
/// - `target`: the database and the server of the connection
/// - `query`: the caller's name of the statement, and its text when its
///   values are parameters
///
/// ## Returns
///
/// The span, which `end` must end.
pub fn start(target: SpanTarget, query: SpanQuery) -> Span {
  // The span name is the summary when the caller gave one, else the
  // namespace target until `end` knows the operation (semantic
  // conventions at commit 7c8eb86d04, docs/db/database-spans.md lines
  // 56-63 and 69-74).
  let name = option.unwrap(query.summary, target.database)
  let strings =
    [
      #("db.system.name", "postgresql"),
      #("db.namespace", target.database),
      #("server.address", target.host),
    ]
    |> list.append(optional("db.query.summary", query.summary))
    |> list.append(optional("db.query.text", query.text))
  let context = start_client_span(name, strings, port_attributes(target.port))
  Span(context:, target_without_summary: target_without_summary(query, target))
}

fn target_without_summary(
  query: SpanQuery,
  target: SpanTarget,
) -> Option(String) {
  case query.summary {
    Some(_summary) -> None
    None -> Some(target.database)
  }
}

/// Ends the span of a statement with its result.
///
/// ## Parameters
///
/// - `span`: the span of `start`
/// - `ending`: how the statement ended
///
/// ## Returns
///
/// `Nil`.
pub fn end(span: Span, ending: SpanEnd) -> Nil {
  case ending {
    Worked(operation:, warning_code:) -> {
      rename(span, operation)
      end_span(
        span.context,
        list.append(
          optional("db.operation.name", operation),
          optional("db.response.status_code", warning_code),
        ),
        False,
      )
    }
    Failed(error_type:, status_code:) ->
      end_span(
        span.context,
        [
          #("error.type", error_type),
          ..optional("db.response.status_code", status_code)
        ],
        True,
      )
  }
}

/// Names a span that has no summary `{db.operation.name} {target}` once
/// its operation is known (semantic conventions at commit 7c8eb86d04,
/// docs/db/database-spans.md lines 58-60: "If no summary is available,
/// the span name SHOULD be `{db.operation.name} {target}` provided that a
/// (low-cardinality) `db.operation.name` is available"). A span with a
/// summary, or with no operation, keeps its name.
fn rename(span: Span, operation: Option(String)) -> Nil {
  case span.target_without_summary, operation {
    Some(target), Some(operation_name) if operation_name != "" ->
      update_name(span.context, operation_name <> " " <> target)
    Some(_target), Some(_empty_operation) -> Nil
    Some(_target), None -> Nil
    None, _operation -> Nil
  }
}

/// The last warning code of a statement's notices: the last SQLSTATE of
/// class 01. A successful statement records it as
/// `db.response.status_code` and stays OK (semantic conventions at commit
/// 7c8eb86d04, docs/db/postgresql.md line 41: `db.response.status_code`
/// is "Conditionally Required If response has ended with warning or an
/// error"; note 3: "Response codes of "Class 02" or higher SHOULD be
/// considered errors"). Class 00 and the other classes of a notice are
/// not warnings.
///
/// ## Parameters
///
/// - `codes`: the SQLSTATE of each notice, in the order they came
///
/// ## Returns
///
/// - `Some(code)`: the last code of class 01
/// - `None`: no code of class 01
pub fn last_warning_code(codes: List(String)) -> Option(String) {
  list.fold(codes, None, later_warning_code)
}

/// The last warning code after one more notice: `code` when it is of
/// class 01, else `last`.
///
/// ## Parameters
///
/// - `last`: the last warning code so far
/// - `code`: the SQLSTATE of the next notice
///
/// ## Returns
///
/// The last warning code.
pub fn later_warning_code(
  last: Option(String),
  code: String,
) -> Option(String) {
  case string.starts_with(code, "01") {
    True -> Some(code)
    False -> last
  }
}

/// The operation of a command tag: the tag without its row counts, for
/// example `INSERT` for `INSERT 0 3` and `CREATE TABLE` for
/// `CREATE TABLE`.
///
/// ## Parameters
///
/// - `tag`: the tag of a CommandComplete
///
/// ## Returns
///
/// The operation.
pub fn operation_of_tag(tag: String) -> String {
  string.split(tag, " ")
  |> list.filter(is_word)
  |> string.join(" ")
}

fn is_word(part: String) -> Bool {
  int.parse(part) |> option.from_result |> option.is_none
}

/// `server.port` is conditionally required: when the port is not the
/// default (semantic conventions at commit 7c8eb86d04, docs/db/postgresql.md,
/// note 5 on `server.port`).
fn port_attributes(port: Int) -> List(#(String, Int)) {
  case port == default_port {
    True -> []
    False -> [#("server.port", port)]
  }
}

fn optional(key: String, value: Option(String)) -> List(#(String, String)) {
  case value {
    Some(text) -> [#(key, text)]
    None -> []
  }
}

@external(erlang, "dream_postgres_trace_ffi", "start_client_span")
fn start_client_span(
  name: String,
  strings: List(#(String, String)),
  ints: List(#(String, Int)),
) -> SpanContext

@external(erlang, "dream_postgres_trace_ffi", "update_name")
fn update_name(context: SpanContext, name: String) -> Nil

@external(erlang, "dream_postgres_trace_ffi", "end_span")
fn end_span(
  context: SpanContext,
  strings: List(#(String, String)),
  failed: Bool,
) -> Nil
