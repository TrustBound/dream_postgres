import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/listener.{
  type ListenMessage, type ListenerName, monitor_listener, named_listener,
}
import gleam/erlang/process.{type Down, type Selector, type Subject}
import gleam/result

pub type JobEvent {
  JobMessage(message: ListenMessage)
  /// The registry of the listener ended, and every subscription with it.
  ListenerEnded(down: Down)
}

/// A selector of the messages of `jobs` and of the end of the listener's
/// registry.
pub fn job_events(
  notifications: ListenerName,
  jobs: Subject(ListenMessage),
) -> Result(Selector(JobEvent), Error(PostgresError)) {
  use monitor <- result.try(monitor_listener(named_listener(notifications)))
  process.new_selector()
  |> process.select_map(jobs, JobMessage)
  |> process.select_specific_monitor(monitor, ListenerEnded)
  |> Ok
}
