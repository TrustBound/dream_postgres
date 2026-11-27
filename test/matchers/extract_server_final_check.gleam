//// Checks a server-final-message against a SCRAM exchange.

import dream_postgres/driver/scram.{
  type ClientFinal, type ServerFinalError, verify_server_final,
}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the result of `verify_server_final` for the server-final-message:
/// `Ok(Nil)` when the server signature is right, or the error.
///
/// ```gleam
/// client_final(first, "pencil", server_first)
/// |> should
/// |> be_ok
/// |> extract_server_final_check(server_final)
/// |> be_ok
/// |> be_equal(Nil)
/// |> or_fail_with("Expected the server signature to verify")
/// ```
pub fn extract_server_final_check(
  result: MatchResult(ClientFinal),
  server_final: BitArray,
) -> MatchResult(Result(Nil, ServerFinalError)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(final) -> MatchOk(verify_server_final(final, server_final))
  }
}
