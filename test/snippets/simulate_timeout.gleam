import dream_postgres/interceptor.{type Outcome, type Request, timeout}
import gleam/option.{None, Some}

pub fn simulate_timeout(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("report.build") -> Error(timeout())
    Some(_) | None -> next(request)
  }
}
