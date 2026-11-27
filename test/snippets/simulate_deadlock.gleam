import dream_postgres/interceptor.{type Outcome, type Request, server_error}
import dream_postgres/sql_state.{DeadlockDetected}
import gleam/option.{None, Some}

pub fn simulate_deadlock(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("account.transfer") ->
      Error(server_error(DeadlockDetected, "deadlock detected"))
    Some(_) | None -> next(request)
  }
}
