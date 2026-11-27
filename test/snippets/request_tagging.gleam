import dream_postgres/interceptor.{type Outcome, type Request, Request}
import gleam/io
import gleam/option
import gleam/order
import gleam/time/duration
import gleam/time/timestamp

/// Puts a comment in front of the SQL, so that `pg_stat_activity` and the
/// server log show which app sent it.
pub fn tag_with_app_name(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  next(Request(..request, sql: "/* billing */ " <> request.sql))
}

/// Prints the name of each request that took more than 500 milliseconds,
/// or its SQL when it has no name.
pub fn log_slow_queries(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  let started = timestamp.system_time()
  let outcome = next(request)
  let elapsed = timestamp.difference(started, timestamp.system_time())
  case duration.compare(elapsed, duration.milliseconds(500)) {
    order.Gt ->
      io.println("slow query: " <> option.unwrap(request.name, request.sql))
    order.Lt | order.Eq -> Nil
  }
  outcome
}
