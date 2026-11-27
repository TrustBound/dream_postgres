//// A matcher that gives the client reason of a chunk that the COPY did not take.

import dream_postgres/driver/connection.{type ChunkError}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/driver_executor
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}

/// Give the client reason of a chunk that the COPY did not take, as the client sees it.
///
/// ## Example
///
/// ```gleam
/// connection.ChunkCopyNotRunning
/// |> should
/// |> map_chunk_error()
/// |> be_equal(error.CopyNotRunning)
/// |> or_fail_with("Expected CopyNotRunning")
/// ```
pub fn map_chunk_error(result: MatchResult(ChunkError)) -> MatchResult(Reason) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(chunk_error) ->
      MatchOk(driver_executor.chunk_error_reason(chunk_error))
  }
}
