//// The session of a listener: the actor that owns the connection process,
//// runs each `LISTEN` and `UNLISTEN` that the registry asks for, and reports
//// each notification and change of the connection to the registry (see
//// `driver/listener`).
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/event.{
  type ConnectionEvent, Connected, Disconnected, ReconnectFailed, Reconnected,
} as connection_event
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/connection/request_failure.{
  type SimpleQueryError, ConnectionEnded, ConnectionProcessDown, DeadlinePassed,
  SimpleQueryCopyRefused, SimpleQueryFailed, SimpleQueryNotConnected,
  SimpleQueryRefused, SimpleQueryRequestFailed, SimpleQueryUnencodable,
}
import dream_postgres/driver/connection/settings.{ConnectionConfig}
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/listener/process_message.{
  type Listened, type ListenerConfig, type SessionMessage, ChannelHasZeroByte,
  CloseRequest, ConnectionChanged, ConnectionNotified, ListenAnswerUnexpected,
  ListenDeadlinePassed, ListenLost, ListenNotDone, ListenRefused, ListenRequest,
  ListenWorked, ListenerConnectionDown, NotificationReceived,
  SessionConnectFailed, SessionLost, SessionStarted, SessionUp, UnlistenRequest,
  reply, send_to_registry,
}
import dream_postgres/driver/sink
import gleam/erlang/process.{type Pid, type Subject}
import gleam/function.{identity}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result.{replace, replace_error}
import gleam/string.{replace as replace_text}

type SessionState {
  SessionState(
    connection: Connection,
    /// The process ID of the registry, looked up once when the session
    /// started.
    registry: Pid,
    deadline_milliseconds: Int,
  )
}

/// The start of the session does no I/O: its connection process starts
/// supervised, and connects after it.
pub fn start(
  config: ListenerConfig,
  registry: Pid,
) -> Result(actor.Started(Subject(SessionMessage)), actor.StartError) {
  let timeout = config.connection.setup_timeout_milliseconds
  actor.new_with_initialiser(timeout, initialise_session(_, config, registry))
  |> actor.on_message(handle_session_message)
  |> actor.start
}

fn initialise_session(
  subject: Subject(SessionMessage),
  config: ListenerConfig,
  registry: Pid,
) -> Result(
  actor.Initialised(SessionState, SessionMessage, Subject(SessionMessage)),
  String,
) {
  let notifications = process.new_subject()
  let events = process.new_subject()
  let connection_config =
    ConnectionConfig(
      ..config.connection,
      events: Some(sink.to(events, identity)),
      notifications: Some(sink.to(notifications, identity)),
      notices: None,
    )
  connection.supervised(connection_config).start()
  |> result.map(session_initialised(
    subject,
    config,
    registry,
    _,
    notifications,
    events,
  ))
  |> replace_error("the connection process did not start")
}

/// Tells the registry that the session started, before any event of its
/// connection, so the registry knows the session before its first report.
fn session_initialised(
  subject: Subject(SessionMessage),
  config: ListenerConfig,
  registry: Pid,
  started: actor.Started(Connection),
  notifications: Subject(Notification),
  events: Subject(ConnectionEvent),
) -> actor.Initialised(SessionState, SessionMessage, Subject(SessionMessage)) {
  send_to_registry(registry, SessionStarted(subject, process.self()))
  let state =
    SessionState(
      connection: started.data,
      registry:,
      deadline_milliseconds: config.deadline_milliseconds,
    )
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(notifications, ConnectionNotified)
    |> process.select_map(events, ConnectionChanged)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(subject)
}

fn handle_session_message(
  state: SessionState,
  message: SessionMessage,
) -> actor.Next(SessionState, SessionMessage) {
  case message {
    ListenRequest(channel:, reply: reply_to) -> {
      reply(reply_to, run_listen(state, channel))
      actor.continue(state)
    }
    UnlistenRequest(channel:, reply: reply_to) -> {
      run_unlisten(state, channel)
      reply(reply_to, Nil)
      actor.continue(state)
    }
    CloseRequest(reply: reply_to) -> {
      connection.stop(state.connection)
      reply(reply_to, Nil)
      actor.stop()
    }
    ConnectionNotified(notification) -> {
      send_to_registry(state.registry, NotificationReceived(notification))
      actor.continue(state)
    }
    ConnectionChanged(event) -> {
      report(state, event)
      actor.continue(state)
    }
  }
}

/// Tells the registry what changed. A failed reconnect needs nothing: the
/// connection process tries again by itself, and the registry told each
/// subscriber at the loss.
fn report(state: SessionState, event: ConnectionEvent) -> Nil {
  case event {
    Connected | Reconnected -> send_to_registry(state.registry, SessionUp)
    connection_event.ConnectFailed(error) ->
      send_to_registry(state.registry, SessionConnectFailed(error))
    ReconnectFailed(_error) -> Nil
    Disconnected(_error) -> send_to_registry(state.registry, SessionLost)
  }
}

/// Sends `UNLISTEN`. Its result changes nothing (see `unlisten`).
fn run_unlisten(state: SessionState, channel: String) -> Nil {
  case run(state, "UNLISTEN " <> quoted(channel)) {
    Ok(Nil) | Error(_loss_or_refusal) -> Nil
  }
}

fn run_listen(state: SessionState, channel: String) -> Listened {
  run(state, "LISTEN " <> quoted(channel)) |> listened
}

/// The SQL is one `LISTEN` in one Query message. Its only encode failure
/// is the zero byte: the message is far below the 2 GiB limit, because
/// the channel has at most 63 bytes. A PostgreSQL server answers it with
/// one result or one error, so `SimpleQueryFailed` and `SimpleQueryCopyRefused` come
/// only from a server that breaks the protocol.
fn listened(result: Result(Nil, SimpleQueryError)) -> Listened {
  case result {
    Ok(Nil) -> ListenWorked
    Error(SimpleQueryRequestFailed(ConnectionEnded(_)))
    | Error(SimpleQueryNotConnected(_)) -> ListenLost
    Error(SimpleQueryRequestFailed(ConnectionProcessDown)) ->
      ListenNotDone(ListenerConnectionDown)
    Error(SimpleQueryRequestFailed(DeadlinePassed(cancelled:))) ->
      ListenNotDone(ListenDeadlinePassed(cancelled))
    Error(SimpleQueryUnencodable(_zero_byte)) ->
      ListenNotDone(ChannelHasZeroByte)
    Error(SimpleQueryRefused(report:, transaction_status:)) ->
      ListenNotDone(ListenRefused(report, transaction_status))
    Error(SimpleQueryFailed(..)) | Error(SimpleQueryCopyRefused(..)) ->
      ListenNotDone(ListenAnswerUnexpected)
  }
}

fn run(state: SessionState, sql: String) -> Result(Nil, SimpleQueryError) {
  connection_simple_query.run_listener_simple_query(
    state.connection,
    sql,
    state.deadline_milliseconds,
  )
  |> replace(Nil)
}

/// The channel as a quoted identifier, so its name stays exact.
fn quoted(channel: String) -> String {
  "\"" <> replace_text(channel, "\"", "\"\"") <> "\""
}
