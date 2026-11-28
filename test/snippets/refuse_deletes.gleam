import dream_postgres/interceptor.{type Outcome, type Request, refuse}
import gleam/option.{None, Some}

pub fn refuse_deletes(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("user.delete") -> Error(refuse("the connection is read only"))
    Some(_) | None -> next(request)
  }
}
