import dream_postgres/interceptor.{type Outcome, type Request, connection_lost}
import gleam/option.{None, Some}

pub fn simulate_lost_connection(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("report.build") -> Error(connection_lost())
    Some(_) | None -> next(request)
  }
}
