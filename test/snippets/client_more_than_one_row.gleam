import dream_errors
import dream_postgres/client as postgres

pub fn one_email(
  emails: List(String),
) -> Result(String, dream_errors.Error(postgres.QueryError)) {
  case emails {
    [email] -> Ok(email)
    [] -> Error(dream_errors.NotFound("user.email found no row"))
    _ ->
      Error(dream_errors.Failed(
        message: "user.email returned more than one row",
        cause: postgres.more_than_one_row(2),
      ))
  }
}
