//// The CopyData of a COPY: a chunk from the caller to the socket for a COPY
//// FROM STDIN, and the next row to the caller for a COPY TO STDOUT.

import dream_postgres/driver/connection/copy_exchange.{
  type CopySession, CopySession,
}
import dream_postgres/driver/connection/copy_process.{
  chunk_answer, refuse_chunk, running_copy,
}
import dream_postgres/driver/connection/reconnection.{send_loss}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_deadline.{deadline_passed}
import dream_postgres/driver/connection/request_failure.{type ChunkError}
import dream_postgres/driver/connection/running_request.{
  read_messages, write_failed,
}
import dream_postgres/driver/connection/socket_messages.{receive_next}
import dream_postgres/driver/connection/state.{type State, Open, RunningCopy}
import dream_postgres/driver/query/copy_step.{type CopyState} as query_copy_step
import dream_postgres/driver/transport.{type SendError}
import gleam/erlang/reference.{type Reference}
import gleam/option.{Some}

/// The caller took the row that the process pushed: the process reads on.
/// A row taken after the process stopped the COPY, or after its end,
/// changes nothing.
pub fn take_row(state: State, id: Reference) -> State {
  case state.running {
    Some(RunningCopy(state: copy_state, session:))
      if session.id == id && session.row_pushed
    ->
      running_copy(state, copy_state, CopySession(..session, row_pushed: False))
      |> read_on
    _ -> state
  }
}

/// Reads the messages that came while the process waited for the caller
/// to take a row, and asks the socket for more.
pub fn read_on(state: State) -> State {
  state |> read_messages |> receive_next
}

/// A chunk of the caller of a COPY: of the COPY that runs, of the one
/// whose caller did not finish its side yet, or of one that is over. Each
/// chunk gets an answer.
pub fn chunk_received(
  state: State,
  id: Reference,
  chunk: BitArray,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
) -> State {
  case state.running, state.copy, state.link {
    Some(RunningCopy(state: copy_state, session:)), _, Open(socket:, ..)
      if session.id == id
    -> send_copy_chunk(state, socket, copy_state, session, chunk, reply_to)
    _, Some(ended), _ if ended.id == id -> {
      reply(reply_to, chunk_answer(ended.result))
      state
    }
    _, _, _ -> {
      refuse_chunk(reply_to)
      state
    }
  }
}

/// Sends a chunk while the server reads data and the deadline did not
/// pass, and answers when it went to the socket. Else the chunk waits for
/// the end of the COPY, which is its answer.
fn send_copy_chunk(
  state: State,
  socket: transport.Connection,
  copy_state: CopyState,
  session: CopySession,
  chunk: BitArray,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
) -> State {
  let waiting =
    running_copy(
      state,
      copy_state,
      CopySession(..session, waiting_chunks: [
        reply_to,
        ..session.waiting_chunks
      ]),
    )
  case
    query_copy_step.accepts_copy_data(copy_state) && !deadline_passed(state)
  {
    True ->
      transport.send(socket, query_copy_step.copy_data(chunk))
      |> chunk_sent(state, waiting, socket, reply_to, _)
    False -> waiting
  }
}

/// Answers a chunk that went to the socket. A send that failed loses the
/// connection, and the waiting chunk gets the loss.
fn chunk_sent(
  state: State,
  waiting: State,
  socket: transport.Connection,
  reply_to: ReplyTo(Result(Nil, ChunkError)),
  sent: Result(Nil, SendError),
) -> State {
  case sent {
    Ok(Nil) -> {
      reply(reply_to, Ok(Nil))
      state
    }
    Error(error) -> write_failed(waiting, socket, send_loss(error))
  }
}
