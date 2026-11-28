import dream_postgres/codecs.{int, text}
import dream_postgres/codecs/composite.{field}
import dream_postgres/interceptor.{type Outcome, type Request, column, rows}
import gleam/option.{None, Some}

pub fn answer_with_two_posts(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("post.list") ->
      rows([column("id", "int4"), column("title", "text")], [
        [field(int, 1), field(text, "First")],
        [field(int, 2), field(text, "Second")],
      ])
    Some(_) | None -> next(request)
  }
}
