//// A step of an act whose failure is the point of the test.

/// Gives `Ok(Nil)` when `result` failed, and an error text when it worked,
/// so an act that expects a failure checks it and goes on.
pub fn expect_failure(result: Result(value, error)) -> Result(Nil, String) {
  case result {
    Ok(_value) -> Error("expected a failure, and the call worked")
    Error(_error) -> Ok(Nil)
  }
}
