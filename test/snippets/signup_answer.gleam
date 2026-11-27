import dream_errors.{
  type Error, Conflict, Failed, Invalid, NotFound, Retry, Timeout, Unavailable,
}
import dream_postgres.{type PostgresError}
import snippets/user_row.{type User}

/// The status code and the text that a sign-up page shows for the result
/// of `create_user`. The text is the app's own text, never the message of
/// the error.
pub fn signup_answer(
  created: Result(User, Error(PostgresError)),
) -> #(Int, String) {
  case created {
    Ok(_user) -> #(201, "Welcome.")
    Error(Conflict(..)) -> #(409, "That email has an account already.")
    Error(Invalid(..)) -> #(400, "Please check your input.")
    Error(Retry(..)) | Error(Unavailable(..)) | Error(Timeout(..)) -> #(
      503,
      "Please try again soon.",
    )
    Error(NotFound(..)) | Error(Failed(..)) -> #(500, "Something went wrong.")
  }
}
