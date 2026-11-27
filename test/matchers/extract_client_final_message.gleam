//// Extracts the client-final-message of a SCRAM exchange.

import dream_postgres/driver/scram.{type ClientFinal, client_final_message}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Gives the bytes of the client-final-message, which the client sends
/// after the server-first-message.
///
/// ```gleam
/// client_final(first, "pencil", server_first)
/// |> should
/// |> be_ok
/// |> extract_client_final_message
/// |> be_equal(<<"c=biws,r=...,p=...">>)
/// |> or_fail_with("Expected the client-final-message")
/// ```
pub fn extract_client_final_message(
  result: MatchResult(ClientFinal),
) -> MatchResult(BitArray) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(final) -> MatchOk(client_final_message(final))
  }
}
