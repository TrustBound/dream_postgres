//// The state of a recorder process and the messages that it receives.

import dream_errors.{type Error}
import dream_postgres/driver/cell.{type TypeDescription}
import dream_postgres/error.{
  type PostgresError, type Reason, type ServerError, PostgresError,
  RecorderStopped,
}
import dream_postgres/interceptor.{type Interceptor, type Outcome, type Request}
import dream_postgres/query/definition.{type WriteEvent}
import dream_postgres/recording.{type RecordedEntry}
import dream_postgres/secrets.{type Secrets}
import gleam/erlang/process.{type Down, type Subject}
import gleam/option.{type Option, None}

/// What a started recorder does: its mode, with `RecordMissing` decided.
pub type Session {
  Saving
  PlayingBack
  PassingThrough
}

pub fn start_failure(reason: Reason) -> Error(PostgresError) {
  PostgresError(query_name: None, sql: None, reason:)
  |> error.to_dream_error
}

pub type State {
  State(
    path: String,
    key: fn(Request) -> String,
    interceptors: List(Interceptor),
    /// The entries saved so far, the last one first.
    saved: List(RecordedEntry),
    /// The entries of the recording not given yet, in recorded order.
    waiting: List(RecordedEntry),
    /// The server error of the last failed answer since the last answer
    /// that succeeded: what the transaction failed with.
    aborted_by: Option(ServerError),
  )
}

pub type Message {
  Save(
    request: Request,
    outcome: Outcome,
    types: List(TypeDescription),
    secrets: Secrets,
    reply: Subject(Result(Nil, Reason)),
  )
  Take(request: Request, secrets: Secrets, reply: Subject(Outcome))
  AbortedBy(reply: Subject(Option(ServerError)))
  Stop
  OwnerDown
}

pub fn recorder_down(_down: Down) -> Result(answer, Reason) {
  Error(RecorderStopped)
}

/// Takes the path for the process that calls it, until it ends. `False`
/// when another process that runs holds it.
@external(erlang, "dream_postgres_recorder_ffi", "claim")
pub fn claim(path: String) -> Bool

// What a watched value of a request did: the number of its row (0 for the
// parameters of a statement), its position, and the event.
pub type WriteSeen {
  WriteSeen(row_number: Int, position: Int, event: WriteEvent)
}
