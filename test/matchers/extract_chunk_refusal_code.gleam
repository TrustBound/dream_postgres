//// Extracts the SQLSTATE code of a chunk whose COPY the server refused.

import dream_postgres/driver/connection/request_failure.{
  type ChunkError, ChunkRefused,
}
import dream_test/types.{
  type MatchResult, AssertionFailure, CustomMatcherFailure, MatchFailed, MatchOk,
}
import gleam/option.{Some}
import gleam/string.{inspect}

/// Gives the SQLSTATE code of a `ChunkRefused`. Fails for other errors.
///
/// ```gleam
/// send_chunk(sender, <<"x\tbad\n":utf8>>)
/// |> should
/// |> be_error
/// |> extract_chunk_refusal_code
/// |> be_equal("22P02")
/// |> or_fail_with("Expected 22P02")
/// ```
pub fn extract_chunk_refusal_code(
  result: MatchResult(ChunkError),
) -> MatchResult(String) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(error) -> code_of(error)
  }
}

fn code_of(error: ChunkError) -> MatchResult(String) {
  case error {
    ChunkRefused(report, _status) -> MatchOk(report.code)
    _other ->
      MatchFailed(AssertionFailure(
        operator: "extract_chunk_refusal_code",
        message: "",
        payload: Some(CustomMatcherFailure(
          actual: inspect(error),
          description: "Expected ChunkRefused",
        )),
      ))
  }
}
