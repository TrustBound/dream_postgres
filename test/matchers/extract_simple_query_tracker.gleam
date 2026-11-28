//// Runs simple queries on a session, and tracks the transaction after each one.

import dream_postgres/driver/query/simple_query.{
  start_simple_query, step_simple_query,
}
import dream_postgres/driver/query/step.{
  type Outcome, type SimpleQueryFailure, type StatementResult,
}
import dream_postgres/driver/transaction.{
  type TransactionTracker, new_tracker, track_simple_query,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import driver/server_query.{type QueryFailure, type Session, run_step}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Runs each simple query in order on the session, gives each outcome to
/// `track_simple_query`, starting from a new tracker, and gives the tracker
/// after the last simple query. Fails when a simple query does not finish.
///
/// ```gleam
/// session
/// |> should
/// |> extract_simple_query_tracker(["BEGIN; SELECT 1/0", "ROLLBACK"])
/// |> extract_tracked_state
/// |> be_equal(#(Idle, None))
/// |> or_fail_with("Expected no error after the rollback")
/// ```
pub fn extract_simple_query_tracker(
  result: MatchResult(Session),
  simple_queries: List(String),
) -> MatchResult(TransactionTracker) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(session) -> track_each(session, new_tracker(), simple_queries)
  }
}

fn track_each(
  session: Session,
  tracker: TransactionTracker,
  simple_queries: List(String),
) -> MatchResult(TransactionTracker) {
  case simple_queries {
    [] -> MatchOk(tracker)
    [sql, ..rest] ->
      track_next(
        run_step(session, start_simple_query(sql), step_simple_query),
        tracker,
        rest,
      )
  }
}

fn track_next(
  stepped: Result(
    #(Outcome(List(StatementResult), SimpleQueryFailure), Session),
    QueryFailure,
  ),
  tracker: TransactionTracker,
  rest: List(String),
) -> MatchResult(TransactionTracker) {
  case stepped {
    Ok(#(outcome, session)) ->
      track_each(session, track_simple_query(tracker, outcome), rest)
    Error(failure) ->
      MatchFailed(AssertionFailure(
        operator: "extract_simple_query_tracker",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(failure),
          description: "Expected each simple query to finish",
        )),
      ))
  }
}
