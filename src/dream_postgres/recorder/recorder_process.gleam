//// The process of a recorder: it keeps the recording, and writes it when a
//// request ends.

import dream_postgres/driver/cell.{type TypeDescription}
import dream_postgres/error.{type Reason, RecordingNotWritten}
import dream_postgres/interceptor.{type Outcome, type Request, Request}
import dream_postgres/recorder/recorded_answer.{intercepted_copy, take}
import dream_postgres/recorder/recorder_state.{
  type Message, type State, AbortedBy, OwnerDown, Save, State, Stop, Take,
}
import dream_postgres/recorder/recording_file.{write_recording}
import dream_postgres/recorder/written_entry.{
  recorded_request, secret_free_outcome,
}
import dream_postgres/recording.{RecordedEntry}
import dream_postgres/secrets.{type Secrets}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Save(request:, outcome:, types:, secrets:, reply:) -> {
      let #(saved, state) = save_copy(state, request, outcome, types, secrets)
      process.send(reply, saved)
      actor.continue(state)
    }
    Take(request:, secrets:, reply:) -> {
      let #(outcome, state) = take(state, request, secrets)
      process.send(reply, outcome)
      actor.continue(state)
    }
    AbortedBy(reply:) -> {
      process.send(reply, state.aborted_by)
      actor.continue(state)
    }
    Stop | OwnerDown -> actor.stop()
  }
}

// Saves the copy of a request with its outcome: the secrets first, then
// the interceptors of the recorder. A request that PostgreSQL did not
// answer is not saved.
fn save_copy(
  state: State,
  copy: Request,
  outcome: Outcome,
  types: List(TypeDescription),
  secrets: Secrets,
) -> #(Result(Nil, Reason), State) {
  let entry = {
    use secret_free <- result.map(secret_free_outcome(secrets, outcome))
    let #(final_request, final_outcome) =
      intercepted_copy(
        state.interceptors,
        Request(..copy, sql: secrets.replace_text(secrets, copy.sql)),
        secret_free,
      )
    recorded_request(final_request, final_outcome, types)
    |> option.map(RecordedEntry(key: state.key(final_request), request: _))
  }
  case entry {
    Ok(Some(entry)) -> {
      let saved = [entry, ..state.saved]
      #(
        write_recording(state.path, list.reverse(saved))
          |> result.map_error(RecordingNotWritten(state.path, _)),
        State(..state, saved:),
      )
    }
    Ok(None) -> #(Ok(Nil), state)
    Error(reason) -> #(Error(reason), state)
  }
}
