import dream_postgres/client as postgres

pub fn one_email(
  emails: List(String),
) -> Result(String, postgres.ModelQueryError) {
  case emails {
    [email] -> Ok(email)
    [] -> Error(postgres.NotFound)
    _ ->
      Error(postgres.QueryFailed(
        message: "user.email returned more than one row",
        cause: postgres.more_than_one_row(2),
      ))
  }
}
