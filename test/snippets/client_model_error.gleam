import dream_postgres/client as postgres

pub fn status_and_message(
  error: postgres.ModelError(postgres.QueryError),
) -> #(Int, String) {
  case error {
    postgres.NotFound -> #(404, "User not found")
    postgres.Conflict("users_email_key") -> #(409, "Email already taken")
    postgres.Conflict(constraint) -> #(409, "Conflict on " <> constraint)
    postgres.QueryFailed(message:, cause: _) -> #(500, message)
  }
}
