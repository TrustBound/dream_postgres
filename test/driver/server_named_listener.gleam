//// A listener under a supervisor and a name, in an owner process that is
//// not linked to the test, and the supervisor calls that restart it.

import dream_postgres/driver/connection.{Backoff}
import dream_postgres/driver/listener.{
  type Listener, type ListenerProcessMessage, from_name, supervised,
}
import driver/server_listener.{listener_config}
import driver/servers.{type Server}
import fixtures/backoff_strategies.{capped_delay}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/otp/static_supervisor
import gleam/result.{flatten, map, map_error, try}
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
  use config <- try(listener_config(
    server.port,
    "svc_named_listener",
    Backoff(10, 60_000, capped_delay),
  ))
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
  config: listener.ListenerConfig,
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
  process.send(named.owner, Nil)
  Ok(Nil)
}

/// Stops the listener and starts it again under the same name, as its
/// supervisor does after it failed, and returns once the new one runs.
@external(erlang, "driver_listener_test_ffi", "restart_first_child")
pub fn restart_listener(supervisor: Pid) -> Result(Nil, String)

/// The restart type of the listener's child spec, for example
/// `transient`.
@external(erlang, "driver_listener_test_ffi", "first_child_restart")
pub fn listener_restart_type(supervisor: Pid) -> Result(String, String)
