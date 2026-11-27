//// A listener under a supervisor and a name, in an owner process that is
//// not linked to the test, the supervisor calls that restart it, and the
//// acts that crash its session or its registry.

import dream_postgres/driver/connection.{type Connection, Backoff}
import dream_postgres/driver/listener.{
  type Listener, type ListenerConfig, type ListenerMessage,
  type ListenerProcessMessage, from_name, monitor_registry, supervised,
}
import dream_test/context.{type Context}
import driver/listener_gate.{
  type Gate, break_gate, open_gate, start_gate, stop_gate, wait_refused,
}
import driver/server_connection.{start_connection}
import driver/server_listener.{
  listener_config, receive_message, send_notification, subscribe_to,
}
import driver/servers.{type Server}
import fixtures/backoff_strategies.{capped_delay}
import gleam/erlang/atom
import gleam/erlang/process.{
  type Down, type ExitReason, type Name, type Pid, type Subject,
}
import gleam/int.{to_string}
import gleam/otp/static_supervisor
import gleam/result.{flatten, map, map_error, replace_error, try}
import gleam/string.{inspect}

/// A supervisor with one listener under a name, and the handle of the name.
pub type NamedListener {
  NamedListener(
    name: Name(ListenerProcessMessage),
    handle: Listener,
    supervisor: Pid,
    /// Stops the owner, and with it the supervisor and the listener.
    owner: Subject(Nil),
  )
}

/// Starts a supervisor of a listener to `server` under a new name, in an
/// owner process that is not linked to the test.
pub fn start_named_listener(server: Server) -> Result(NamedListener, String) {
  listener_config(
    server.port,
    "svc_named_listener",
    Backoff(10, 60_000, capped_delay),
  )
  |> try(start_configured_named_listener)
}

/// Starts a supervisor of a listener with `config` under a new name, in an
/// owner process that is not linked to the test and traps exits.
pub fn start_configured_named_listener(
  config: ListenerConfig,
) -> Result(NamedListener, String) {
  let name = process.new_name("listener_test_named")
  let started = process.new_subject()
  process.spawn_unlinked(fn() { supervise_listener(config, name, started) })
  use #(supervisor, owner) <- try(
    process.receive(started, 5000)
    |> map_error(fn(_timeout) { "the owner gave no supervisor in 5 seconds" })
    |> flatten,
  )
  Ok(NamedListener(name:, handle: from_name(name), supervisor:, owner:))
}

fn supervise_listener(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
  started: Subject(Result(#(Pid, Subject(Nil)), String)),
) -> Result(Nil, Nil) {
  process.trap_exits(True)
  let owner = process.new_subject()
  process.send(
    started,
    static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(supervised(config, name))
      |> static_supervisor.start
      |> map(fn(supervisor) { #(supervisor.pid, owner) })
      |> map_error(fn(error) {
        "could not start the supervisor: " <> inspect(error)
      }),
  )
  process.receive(owner, 60_000)
}

/// Stops the owner, which stops the supervisor and the listener.
pub fn stop_named_listener(named: NamedListener) -> Result(Nil, String) {
  Ok(stop_owner(named))
}

/// Stops the owner after a setup step failed, and gives the error of the
/// step.
pub fn stop_named_listener_after_error(
  named: NamedListener,
  error: String,
) -> String {
  stop_owner(named)
  error
}

fn stop_owner(named: NamedListener) -> Nil {
  process.send(named.owner, Nil)
}

/// Stops the listener and starts it again under the same name, as its
/// supervisor does after it failed, and returns once the new one runs.
@external(erlang, "driver_listener_test_ffi", "restart_first_child")
pub fn restart_listener(supervisor: Pid) -> Result(Nil, String)

/// The restart type of the listener's child spec, for example
/// `transient`.
@external(erlang, "driver_listener_test_ffi", "first_child_restart")
pub fn listener_restart_type(supervisor: Pid) -> Result(String, String)

/// The session process of the listener, read from the state of its
/// registry. A registry that waits for its session does not answer this
/// read.
@external(erlang, "driver_listener_test_ffi", "session_pid")
pub fn listener_session_pid(listener: Listener) -> Pid

/// The number of `driver_connection_test_ffi`, which no other caller gets.
@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_number() -> Int

// A crash of the registry -----------------------------------------------------

/// Monitors the registry of the listener with `monitor_registry`, kills
/// the registry, and gives the reason of the monitor's `Down`.
pub fn crash_registry(named: NamedListener) -> Result(ExitReason, String) {
  use monitor <- try(monitor_registry(named.handle) |> map_error(inspect))
  use registry <- try(
    process.named(named.name) |> replace_error("no registry has the name"),
  )
  process.kill(registry)
  process.new_selector()
  |> process.select_specific_monitor(monitor, down_reason)
  |> process.selector_receive(5000)
  |> replace_error("no Down of the registry within 5 seconds")
}

fn down_reason(down: Down) -> ExitReason {
  down.reason
}

// A crash of the session ------------------------------------------------------

/// A listener under a name, through a gate proxy (see `listener_gate`) to
/// a driver server, a control connection straight to the server, a
/// subscriber of the calling process, and a channel that no other test
/// uses.
pub type GatedNamedListener {
  GatedNamedListener(
    named: NamedListener,
    gate: Gate,
    control: Connection,
    subscriber: Subject(ListenerMessage),
    channel: String,
  )
}

/// Starts a gate proxy to `server` with the gate closed, a listener under
/// a name through it, and a control connection. The closed gate keeps the
/// connection of the listener from connecting until the act opens it.
pub fn start_gated_named_listener(
  server: Server,
) -> Result(GatedNamedListener, String) {
  use #(port, gate) <- try(start_gate(server.port))
  break_gate(gate)
  start_behind_gate(server, port, gate)
  |> map_error(fn(error) {
    stop_gate(gate)
    error
  })
}

fn start_behind_gate(
  server: Server,
  port: Int,
  gate: Gate,
) -> Result(GatedNamedListener, String) {
  let number = to_string(unique_number())
  use config <- try(listener_config(
    port,
    "svc895_crash_" <> number,
    Backoff(10, 50, capped_delay),
  ))
  use named <- try(start_configured_named_listener(config))
  start_connection(server.port)
  |> map(GatedNamedListener(
    named,
    gate,
    _,
    process.new_subject(),
    "svc895_crash_" <> number,
  ))
  |> map_error(stop_named_listener_after_error(named, _))
}

/// Stops the listener, the gate proxy and the control connection.
pub fn stop_gated_named_listener(
  gated: GatedNamedListener,
) -> Result(Nil, String) {
  Ok(stop_gated(gated))
}

fn stop_gated(gated: GatedNamedListener) -> Nil {
  stop_owner(gated.named)
  stop_gate(gated.gate)
  connection.stop(gated.control)
}

/// What the subscriber got after the session of its listener crashed: at
/// the crash, after the new session connected, and for a notification
/// sent after that.
pub type SessionCrash {
  SessionCrash(
    lost: Result(ListenerMessage, String),
    again: Result(ListenerMessage, String),
    notified: Result(ListenerMessage, String),
  )
}

/// What the subscriber of a gated listener under a name got after its
/// session crashed, with the listener.
pub type CrashOutcome {
  CrashOutcome(gated: GatedNamedListener, crash: SessionCrash)
}

/// The context of a describe whose tests each check one message of one
/// shared act: the setup starts a gated listener under a name on `server`
/// and runs `crash_session` once, and the teardown stops the listener.
pub fn session_crash_setup(server: Server) -> Context(CrashOutcome) {
  context.setup(
    setup: fn() {
      use gated <- try(start_gated_named_listener(server))
      crash_session(gated)
      |> map(CrashOutcome(gated, _))
      |> map_error(fn(error) {
        stop_gated(gated)
        error
      })
    },
    teardown: fn(outcome: CrashOutcome) {
      stop_gated_named_listener(outcome.gated)
    },
  )
}

/// Subscribes while the gate is closed, opens the gate and waits until
/// the session listens, kills the session, and gives what the subscriber
/// got after the kill, with no new subscribe.
pub fn crash_session(
  gated: GatedNamedListener,
) -> Result(SessionCrash, String) {
  let handle = gated.named.handle
  use _subscription <- try(subscribe_to(handle, gated.channel, gated.subscriber))
  use _not_listening <- try(receive_message(gated.subscriber))
  open_gate(gated.gate)
  use _listening <- try(receive_message(gated.subscriber))
  process.kill(listener_session_pid(handle))
  let lost = receive_message(gated.subscriber)
  let again = receive_message(gated.subscriber)
  use Nil <- try(send_notification(gated.control, gated.channel, "again"))
  let notified = receive_message(gated.subscriber)
  Ok(SessionCrash(lost:, again:, notified:))
}

// A subscribe that the registry handles after the login, before the report
// of it --------------------------------------------------------------------

/// The first two messages of a subscriber whose subscribe the registry
/// handled after the connection of its session logged in, but before the
/// registry handled the session's report of that login.
///
/// The order is forced, with no timing: the registry is suspended while
/// the subscribe waits in its mailbox, the gate opens, and the session's
/// report of the login comes in behind it. Then the registry resumes and
/// handles the subscribe first.
pub fn subscribe_before_up_report(
  gated: GatedNamedListener,
) -> Result(#(ListenerMessage, ListenerMessage), String) {
  wait_refused(gated.gate)
  let registry = registry_pid(gated.named.handle)
  watch_received(registry)
  suspend_process(registry)
  let answers = process.new_subject()
  let subscriber = process.new_subject()
  let channel = gated.channel
  let handle = gated.named.handle
  process.spawn(fn() {
    process.send(answers, subscribe_to(handle, channel, subscriber))
  })
  use Nil <- try(wait_received(registry, atom.create("subscribe_request")))
  open_gate(gated.gate)
  use Nil <- try(wait_received(registry, atom.create("session_up")))
  resume_process(registry)
  use subscribed <- try(
    process.receive(answers, 5000)
    |> replace_error("the subscribe gave no answer within 5 seconds"),
  )
  use _subscription <- try(subscribed)
  use first <- try(receive_message(subscriber))
  use second <- try(receive_message(subscriber))
  Ok(#(first, second))
}

@external(erlang, "driver_listener_test_ffi", "registry_pid")
fn registry_pid(listener: Listener) -> Pid

@external(erlang, "driver_listener_test_ffi", "watch_received")
fn watch_received(process: Pid) -> Nil

@external(erlang, "driver_listener_test_ffi", "suspend_process")
fn suspend_process(process: Pid) -> Nil

@external(erlang, "driver_listener_test_ffi", "resume_process")
fn resume_process(process: Pid) -> Nil

@external(erlang, "driver_listener_test_ffi", "wait_received")
fn wait_received(process: Pid, tag: atom.Atom) -> Result(Nil, String)

/// The first two messages of a subscriber whose subscribe the registry
/// handled while the session was up, but after the connection was lost
/// and before the registry handled the report of that loss. Its `LISTEN`
/// meets the loss.
///
/// The order is forced as in `subscribe_before_up_report`: a first
/// subscriber shows that the session is up, the registry is suspended
/// while the second subscribe waits in its mailbox, the gate breaks the
/// connection, and the session's report of the loss comes in behind the
/// subscribe. The gate opens once the registry handled the subscribe.
pub fn subscribe_during_unreported_loss(
  gated: GatedNamedListener,
) -> Result(#(ListenerMessage, ListenerMessage), String) {
  let handle = gated.named.handle
  let first = process.new_subject()
  use _first_subscription <- try(subscribe_to(handle, gated.channel, first))
  use _not_listening <- try(receive_message(first))
  open_gate(gated.gate)
  use _listening <- try(receive_message(first))
  let registry = registry_pid(handle)
  watch_received(registry)
  suspend_process(registry)
  let answers = process.new_subject()
  let second = process.new_subject()
  let channel = gated.channel <> "_second"
  process.spawn(fn() {
    process.send(answers, subscribe_to(handle, channel, second))
  })
  use Nil <- try(wait_received(registry, atom.create("subscribe_request")))
  break_gate(gated.gate)
  use Nil <- try(wait_received(registry, atom.create("session_lost")))
  resume_process(registry)
  use subscribed <- try(
    process.receive(answers, 5000)
    |> replace_error("the subscribe gave no answer within 5 seconds"),
  )
  use _subscription <- try(subscribed)
  use lost <- try(receive_message(second))
  open_gate(gated.gate)
  use again <- try(receive_message(second))
  Ok(#(lost, again))
}
