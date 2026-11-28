import dream_postgres/listener.{
  type ListenMessage, ListenFailed, Listening, NotListening, NotificationArrived,
}
import gleam/erlang/process.{type Subject}

/// The payload of the next notification, or `Error(Nil)` when none came
/// within 5 seconds. It skips the messages about the listening state.
pub fn next_job(jobs: Subject(ListenMessage)) -> Result(String, Nil) {
  case process.receive(jobs, 5000) {
    Ok(NotificationArrived(payload:, ..)) -> Ok(payload)
    Ok(NotListening) | Ok(Listening(..)) | Ok(ListenFailed(..)) ->
      next_job(jobs)
    Error(Nil) -> Error(Nil)
  }
}
