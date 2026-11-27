import dream_postgres/interceptor.{type Outcome, type Request, command}
import gleam/option.{None, Some}

pub fn answer_three_updates(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    // `affected` reads this answer as 3.
    Some("user.deactivate_all") -> command("UPDATE 3")
    Some(_) | None -> next(request)
  }
}
