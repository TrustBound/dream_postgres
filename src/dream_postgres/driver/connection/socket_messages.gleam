//// The messages of the socket: the bytes that the server sends, also while the
//// connection is idle.

import dream_postgres/driver/connection/copy_process.{paused}
import dream_postgres/driver/connection/event.{ConnectionLost, SocketFailed}
import dream_postgres/driver/connection/reconnection.{lose}
import dream_postgres/driver/connection/running_request.{
  lose_on_error, read_messages,
}
import dream_postgres/driver/connection/state.{type State, Lost, Open, State}
import dream_postgres/driver/transport.{
  BytesReceived, NotThisSocket, SocketClosed, SocketEnded,
}
import gleam/bool.{guard}
import gleam/dynamic.{type Dynamic}
import gleam/result.{map_error}

pub fn socket_message_received(state: State, socket_message: Dynamic) -> State {
  case state.link {
    Open(socket:, bytes:) ->
      socket_event(
        state,
        socket,
        bytes,
        transport.socket_event(socket, socket_message),
      )
    Lost(..) -> state
  }
}

fn socket_event(
  state: State,
  socket: transport.Connection,
  bytes: BitArray,
  event: transport.SocketEvent,
) -> State {
  case event {
    BytesReceived(more) ->
      State(..state, link: Open(socket, <<bytes:bits, more:bits>>))
      |> read_messages
      |> receive_next
    SocketEnded ->
      lose(state, socket, ConnectionLost(SocketFailed(SocketClosed)))
    transport.SocketFailed(error) ->
      lose(state, socket, ConnectionLost(SocketFailed(error)))
    NotThisSocket -> state
  }
}

pub fn receive_next(state: State) -> State {
  use <- guard(paused(state), state)
  case state.link {
    Open(socket:, ..) ->
      transport.receive_next(socket)
      |> map_error(SocketFailed)
      |> lose_on_error(state, socket, _)
    Lost(..) -> state
  }
}
