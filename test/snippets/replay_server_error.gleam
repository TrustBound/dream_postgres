import dream_postgres/error.{type Reason, type ServerError, Server}
import dream_postgres/recording.{failure_reason, recorded_failure}
import gleam/option.{type Option}

/// A server error goes into a recording as a `RecordedServerError`, and
/// comes back as the same reason: `Some(Server(server_error))`.
pub fn replay_server_error(server_error: ServerError) -> Option(Reason) {
  Server(server_error)
  |> recorded_failure
  |> option.map(failure_reason)
}
