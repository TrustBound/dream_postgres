import dream_postgres/client.{type QueryError, violated_constraint}

pub fn sign_up_error_message(error: QueryError) -> String {
  case violated_constraint(error) {
    Ok("users_email_key") -> "Email already taken"
    Ok(constraint) -> "The sign-up broke the constraint " <> constraint
    Error(Nil) -> "The sign-up failed"
  }
}
