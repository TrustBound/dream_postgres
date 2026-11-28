//// A connection process: one gleam_otp actor that owns one socket to a
//// PostgreSQL server for its whole life.
////
//// The process connects and logs in when it starts. After that it runs one
//// request at a time with the pure steps of `driver/query/step`, over the
//// socket of `driver/transport`, and gives the result back as cells of
//// bytes: the caller decodes them in its own process. Requests that come
//// while one runs wait in order.
////
//// The socket sends each of its messages to the process, so a close by
//// the server is seen at once, also while the connection is idle. When the
//// connection is lost, the process tells the subscriber of its events,
//// fails the requests that wait, and connects again with a backoff that
//// doubles from the first delay up to the longest one.
////
//// A caller that crashes or stops waiting never leaves the connection in
//// an unknown state: the process reads each answer to its end, whether a
//// caller still waits for it or not. A reply that comes after the caller
//// stopped waiting is dropped and never reaches the caller's mailbox.
////
//// A COPY streams its rows between the caller's process and the socket:
//// `copy_from` sends each chunk of the caller to the socket before the
//// caller makes the next one, and `copy_to` reads the next row from the
//// socket only after the caller took the last one. The caller's process
//// makes and reads the data; the connection process keeps the socket. The
//// connection serves its COPY caller only, up to the end of the COPY.
////
//// Messages that the server sends between requests are kept, not dropped:
//// a parameter change updates `server_parameter`, and a notice or a
//// notification goes with the outcome of the next request.
////
//// This module starts and stops a connection process. Its parts live in the
//// modules of `connection/`: one for each protocol or lifecycle concern, such
//// as `startup`, `simple_query`, `extended_query`, `copy_caller`, `cancel`
//// and `reconnection`.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection/call.{
  type Connection, Connection, call, send_request,
}
import dream_postgres/driver/connection/event.{
  type ConnectError, SetupExited, SetupTimedOut,
}
import dream_postgres/driver/connection/message_loop.{handle_message}
import dream_postgres/driver/connection/process_message.{
  type Message, CallerDown, ExitSignal, OpenAttempt, OpenRequest, SocketMessage,
  StopRequest,
}
import dream_postgres/driver/connection/reply.{call_process_until_answer}
import dream_postgres/driver/connection/session_state.{new_state}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/connection/state.{type State}
import dream_postgres/driver/connection/tracing.{span_target}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result.{map_error, try}

// Starting and stopping -------------------------------------------------------

/// Starts a connection process, linked to the caller, and waits until it
/// connected and logged in.
///
/// ## Parameters
///
/// - `config`: the server, the login and the reconnect settings
///
/// ## Returns
///
/// - `Ok(Connection)`: the process is connected and ready
/// - `Error(ConnectError)`: the connect or the login failed. No process
///   stays.
pub fn start(config: ConnectionConfig) -> Result(Connection, ConnectError) {
  start_process(config) |> result.map(started_connection)
}

fn started_connection(started: actor.Started(Connection)) -> Connection {
  started.data
}

/// Starts the process, then asks it to connect and log in. The start of
/// the process does no I/O, and the process answers the open by the end of
/// its own setup deadline, with the session or `SetupTimedOut`. So the
/// starter waits for that answer with a monitor and no timer of its own:
/// no second timer can end a start that the process completed.
fn start_process(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), ConnectError) {
  use started <- try(
    actor.new_with_initialiser(config.setup_timeout_milliseconds, initialise(
      _,
      config,
    ))
    |> actor.on_message(handle_message)
    |> actor.start
    |> map_error(start_failure),
  )
  open_process(started.data) |> result.replace(started)
}

fn open_process(connection: Connection) -> Result(Nil, ConnectError) {
  case
    call_process_until_answer(connection.pid, send_request(
      connection,
      OpenRequest,
      _,
    ))
  {
    Ok(opened) -> opened
    Error(_process_down) -> Error(SetupExited)
  }
}

/// The error of a process that did not start, before it did any I/O.
///
/// ## Parameters
///
/// - `error`: the start error of gleam_otp
///
/// ## Returns
///
/// `SetupTimedOut` when the VM did not run the new process within the
/// setup timeout, and `SetupExited` when it exited while it started.
///
/// It is public so that its tests can give it each start error directly.
/// No portable real path gives any of them: the initialiser does no I/O
/// and always returns `Ok`, so `InitFailed` and `InitExited` cannot come
/// from it, and `InitTimeout` needs a VM too busy to run a new process
/// within the setup timeout.
pub fn start_failure(error: actor.StartError) -> ConnectError {
  case error {
    actor.InitTimeout -> SetupTimedOut
    actor.InitFailed(_) | actor.InitExited(_) -> SetupExited
  }
}

/// The process as a child of a gleam_otp supervisor.
///
/// ## Parameters
///
/// - `config`: the server, the login and the reconnect settings
///
/// ## Returns
///
/// A worker child that starts the process with `config`. The start does
/// not wait for the server: the process connects after it, and a failed
/// attempt is tried again after the reconnect backoff, so a server that is
/// down never fails the supervisor. Until the first login, requests fail
/// as not connected, for example with `RunNotConnected`, and the
/// subscriber gets `ConnectFailed` for each failed attempt. The supervisor's shutdown makes the process send
/// Terminate before it stops.
///
/// db_connection does the same: its `init` returns at once and connects
/// in the next event, and a failed connect is logged and tried again after
/// its backoff (db_connection 2.8.1, `DBConnection.Connection`).
pub fn supervised(config: ConnectionConfig) -> ChildSpecification(Connection) {
  supervision.worker(fn() { start_child(config) })
}

fn start_child(
  config: ConnectionConfig,
) -> Result(actor.Started(Connection), actor.StartError) {
  actor.new_with_initialiser(config.setup_timeout_milliseconds, fn(subject) {
    process.send(subject, OpenAttempt(0, 0))
    initialise(subject, config)
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Sets up the process with no I/O: the open comes as its first request.
fn initialise(
  subject: Subject(Message),
  config: ConnectionConfig,
) -> Result(actor.Initialised(State, Message, Connection), String) {
  process.trap_exits(True)
  let state = new_state(config, subject)
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_trapped_exits(ExitSignal)
    |> process.select_monitors(CallerDown)
    |> process.select_other(SocketMessage)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Connection(
    subject:,
    pid: process.self(),
    reply_margin_milliseconds: config.cancel_timeout_milliseconds
      + config.setup_timeout_milliseconds,
    span_target: span_target(config),
  ))
  |> Ok
}

/// Stops the process: it sends Terminate to the server and closes the
/// socket.
///
/// ## Parameters
///
/// - `connection`: the connection to stop
///
/// ## Returns
///
/// `Nil`, also when the process is gone already.
pub fn stop(connection: Connection) -> Nil {
  call(connection, StopRequest, 5000) |> result.unwrap(Nil)
}
