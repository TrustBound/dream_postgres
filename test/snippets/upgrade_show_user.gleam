import dream_errors.{type Error, NotFound}
import dream_postgres.{type PostgresError}
import snippets/upgrade_find_user.{type FindUserRow}

pub type Response {
  Response(status: Int, body: String)
}

pub fn show_user_response(
  result: Result(FindUserRow, Error(PostgresError)),
) -> Response {
  case result {
    Ok(user) -> Response(200, user.name)
    Error(NotFound(..)) -> Response(404, "User not found")
    Error(_other) -> Response(500, "Internal server error")
  }
}
