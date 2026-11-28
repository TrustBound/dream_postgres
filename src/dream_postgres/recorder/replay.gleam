//// The lowest layer of a connection with no database: what answers each
//// request after the last interceptor, such as the recording of a
//// recorder in playback mode.

import dream_postgres/error.{type Reason, type ServerError}
import dream_postgres/interceptor.{type Outcome, type Request}
import gleam/option.{type Option}

/// What answers the requests of a connection with no database.
pub type Replay {
  Replay(
    /// The outcome of each request.
    answer: fn(Request) -> Outcome,
    /// The server error that failed the open transaction, as
    /// `transaction.commit` reads it from a connection, or `None`. An
    /// error means the answer cannot be given.
    aborted_by: fn() -> Result(Option(ServerError), Reason),
  )
}
