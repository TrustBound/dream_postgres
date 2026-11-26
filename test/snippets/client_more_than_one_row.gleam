import dream_errors.{type Error, Failed, NotFound}
import dream_postgres/client.{type QueryError, more_than_one_row}

pub fn one_email(emails: List(String)) -> Result(String, Error(QueryError)) {
  case emails {
    [email] -> Ok(email)
    [] -> Error(NotFound("user.email found no row"))
    _ ->
      Error(Failed(
        message: "user.email returned more than one row",
        cause: more_than_one_row(2),
      ))
  }
}
