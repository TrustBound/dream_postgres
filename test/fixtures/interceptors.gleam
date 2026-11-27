//// Interceptors for the interceptor and transaction tests: one that
//// answers with a given outcome, ones that change the SQL, one that fails
//// a named query, one that refuses each rollback, one that watches the
//// command tags, and one that refuses with the text of the request.

import dream_postgres/error.{type Reason}
import dream_postgres/interceptor.{
  type Interceptor, type Outcome, type Request, CopyFromAnswer, CopyToAnswer,
  Request, Sql, SqlAnswer, StatementAnswer,
}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

/// An interceptor that refuses every request with `string.inspect` of the
/// request as the reason, as a careless log line would print it.
///
/// ## Example
///
/// ```gleam
/// with_interceptor(connection, interceptors.refuse_with_request_text())
/// ```
pub fn refuse_with_request_text() -> Interceptor {
  fn(request: Request, _next: fn(Request) -> Outcome) {
    Error(interceptor.refuse(string.inspect(request)))
  }
}

/// An interceptor that answers every request with `outcome`, and never
/// calls the database.
///
/// ## Example
///
/// ```gleam
/// interceptors.answer_with(Error(interceptor.refuse("read only")))
/// ```
pub fn answer_with(outcome: Outcome) -> Interceptor {
  fn(_request: Request, _next: fn(Request) -> Outcome) { outcome }
}

/// An interceptor that runs `sql` in place of the SQL of each request.
///
/// ## Example
///
/// ```gleam
/// interceptors.replace_sql("SELECT 'one'::text AS word")
/// ```
pub fn replace_sql(sql: String) -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    next(Request(..request, sql:))
  }
}

/// An interceptor that sends each request on as a `run_sql` call.
///
/// ## Example
///
/// ```gleam
/// interceptors.make_sql()
/// // a copy_from request reaches the database as a `run_sql` call
/// ```
pub fn make_sql() -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    next(Request(..request, kind: Sql))
  }
}

/// An interceptor that adds `text` at the end of the SQL of each request.
///
/// ## Example
///
/// ```gleam
/// interceptors.append_to_sql(" || 'a'")
/// // "SELECT 'x'::text" runs as "SELECT 'x'::text || 'a'"
/// ```
pub fn append_to_sql(text: String) -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    next(Request(..request, sql: request.sql <> text))
  }
}

/// An interceptor that fails the query named `name` with `reason`, and
/// sends every other request on.
///
/// ## Example
///
/// ```gleam
/// interceptors.fail_named(
///   "post.create",
///   interceptor.server_error(sql_state.DeadlockDetected, "deadlock detected"),
/// )
/// ```
pub fn fail_named(name: String, reason: Reason) -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    case request.name == Some(name) {
      True -> Error(reason)
      False -> next(request)
    }
  }
}

/// An interceptor that refuses each `ROLLBACK`, also a `ROLLBACK TO
/// SAVEPOINT`, with the reason `InterceptorFailed("rollback refused")`,
/// and sends every other request on. The refused request does not reach
/// the server.
///
/// ## Example
///
/// ```gleam
/// with_interceptor(connection, interceptors.refuse_rollback())
/// ```
pub fn refuse_rollback() -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    case string.starts_with(request.sql, "ROLLBACK") {
      True -> Error(interceptor.refuse("rollback refused"))
      False -> next(request)
    }
  }
}

/// An interceptor that only watches: it sends the command tags of each
/// outcome to `seen`, joined with `, `, or the reason of a failure, and
/// gives the outcome unchanged.
///
/// ## Example
///
/// ```gleam
/// interceptors.send_tags_to(seen)
/// // "SELECT generate_series(1, 2)" sends Ok("SELECT 2")
/// ```
pub fn send_tags_to(seen: Subject(Result(String, Reason))) -> Interceptor {
  fn(request: Request, next: fn(Request) -> Outcome) {
    let outcome = next(request)
    process.send(
      seen,
      result.map(outcome, fn(answer) {
        case answer {
          StatementAnswer(result: command_result, ..) -> command_result.tag
          SqlAnswer(results:) ->
            results
            |> list.map(fn(command_result) { command_result.tag })
            |> string.join(", ")
          CopyFromAnswer(count:) -> "COPY " <> int.to_string(count)
          CopyToAnswer(..) -> "COPY"
        }
      }),
    )
    outcome
  }
}
