import dream_postgres/client as postgres

pub fn sign_up_error_message(error: postgres.QueryError) -> String {
  case postgres.violated_constraint(error) {
    Ok("users_email_key") -> "Email already taken"
    Ok(constraint) -> "The sign-up broke the constraint " <> constraint
    Error(Nil) -> "The sign-up failed"
  }
}
