//// A listener: it gives the notifications of `NOTIFY` to the processes
//// that subscribe to a channel, from a connection process of its own,
//// outside any pool.
////
//// A listener is two gleam_otp actors:
////
//// - The registry keeps the subscriptions: the channel, the subscriber's
////   sink, and a monitor on the process that owns the sink's subject. It
////   does no I/O.
////   Each call of this module goes to it. It decides when a channel needs
////   `LISTEN` or `UNLISTEN`, and asks the session to send it.
//// - The session owns the connection process. It sends each `LISTEN` and
////   `UNLISTEN` that the registry asks for, and passes each notification
////   and each change of the connection to the registry.
////
//// The first subscriber of a channel makes the registry ask for `LISTEN`,
//// and when the last one goes, by `unsubscribe` or because its process
//// stopped, the registry asks for `UNLISTEN`. Channel names are exact: the
//// session quotes them, so `Jobs` and `jobs` are two channels.
////
//// The connection process sends each notification to the session as it
//// arrives, the session passes it to the registry, and the registry sends
//// it on to each subscriber of its channel, in the order the server sent
//// them.
////
//// The registry sends each message to a subscriber through the
//// subscriber's sink, so the map of the sink runs in the registry's
//// process. When that map crashes, the registry drops the sink: it ends
//// the subscription, the same as when the subscriber's process stops, and
//// asks for `UNLISTEN` when it was the last one of its channel. The other
//// subscribers and the listener go on (see `driver/sink`).
////
//// A subscriber hears whether its session listens. When the connection is
//// lost, each subscriber gets `NotListening` at once, and the connection
//// process connects again. The new session listens on nothing, so the
//// registry asks for `LISTEN` again for each channel, and each subscriber
//// gets `Listening`, or `ListenFailed` when that `LISTEN` failed. The
//// server keeps no notification for a session that is gone, so the
//// notifications between `NotListening` and `Listening` may be missed.
////
//// The rule for a subscribe is exact. The session is up from the moment
//// the registry handles the session's report that its connection logged
//// in, until the registry handles a loss or the end of that session.
////
//// - A subscribe that the registry handles while the session is up sends
////   `LISTEN` (for the first subscriber of the channel) and returns once
////   the session listens. The subscriber gets no message for it.
//// - A subscribe that the registry handles while the session is not up
////   (not connected yet, lost, or no session) sends nothing. The
////   subscriber gets `NotListening` at once, then `Listening` or
////   `ListenFailed` after the next login.
//// - A `LISTEN` that meets a loss the registry has not handled yet gives
////   `NotListening` the same way.
////
//// So a subscriber gets `NotListening` first if and only if the session is
//// not up when the registry handles its subscribe. A test that needs one
//// exact sequence controls the connection: with the server out of reach,
//// for example behind a closed TCP gate, a subscribe always gets
//// `NotListening`, then `Listening` once the gate opens. With a listener
//// from `start`, which returns once its session is up, a subscribe always
//// gets no message.
////
//// A crash of the session is a loss too. Under a supervisor
//// (`supervised`), the registry and the session are the two children of a
//// small supervisor with the strategy rest_for_one. When the session
//// stops, each subscriber that listened gets `NotListening`, and the
//// supervisor starts a new session. The new session tells the registry
//// when its connection is up, the registry asks it for `LISTEN` on each
//// channel, and each subscriber gets `Listening` or `ListenFailed`, with
//// no new subscribe. A crash of the registry ends every subscription: the
//// supervisor starts the registry and the session again, with no
//// subscriber. A subscriber sees that crash with `monitor_registry`.
////
//// A listener from `start` has no supervisor: the registry is linked to
//// the caller, and the session to the registry. A crash of its session
//// stops the registry too.
////
//// A call to the listener has no timeout: the registry answers each one
//// after at most one `LISTEN` or `UNLISTEN` of its session, and a listener
//// that is gone gives `ListenerProcessDown`. So a subscription never exists
//// without the handle that ends it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/listener/process_message.{
  type ListenerConfig, type ListenerError, type ListenerMessage,
  type ListenerProcessMessage, type ReplyTo, type SessionMessage,
  type Subscription, ChannelTooLong, ListenerProcessDown, StopRequest,
  SubscribeRequest, SubscriberHasNoProcess, UnsubscribeRequest, call_process,
  send_to_registry,
}
import dream_postgres/driver/listener/registry.{
  Linked, Named, start as start_registry,
}
import dream_postgres/driver/listener/session.{start as start_session}
import dream_postgres/driver/sink.{type Sink}
import gleam/bit_array.{byte_size}
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Subject, subject_owner,
}
import gleam/otp/actor
import gleam/otp/static_supervisor.{AnySignificant, RestForOne}
import gleam/otp/supervision.{type ChildSpecification, Transient}
import gleam/result.{map_error, replace_error, try}

// Types -----------------------------------------------------------------------

/// Why an unsubscribe failed.
pub type UnsubscribeError {
  /// The registry of the listener is gone.
  ListenerGone
}

/// Why a listener did not start.
pub type StartError {
  /// Its connection could not connect and log in.
  ConnectFailed(error: ConnectError)
  /// The registry or the session did not start.
  ListenerNotStarted(error: actor.StartError)
}

/// A listener's registry, or the name it runs under. Each call finds the
/// process that has the subject now, so a handle of `from_name` stays
/// valid when a supervisor starts the listener again.
pub opaque type Listener {
  Listener(subject: Subject(ListenerProcessMessage))
}

/// What the starter of `start` waits for.
type Opening {
  Opened(result: Result(Nil, ConnectError))
  ListenerDown(reason: process.ExitReason)
}

/// The longest channel name, in bytes: PostgreSQL's NAMEDATALEN less one.
const longest_channel_bytes = 63

// Starting and stopping -------------------------------------------------------

/// Starts a listener, linked to the caller, and waits until its connection
/// connected and logged in. The registry is linked to the caller, and the
/// session to the registry. No supervisor starts the session again: a
/// crash of the session stops the listener.
///
/// ## Parameters
///
/// - `config`: the connection and the deadline of each `LISTEN`
///
/// ## Returns
///
/// - `Ok(Listener)`: the listener is connected and has no subscriber yet
/// - `Error(StartError)`: the connect, the login or the start failed. No
///   process stays.
pub fn start(config: ListenerConfig) -> Result(Listener, StartError) {
  let opened = process.new_subject()
  use started <- try(
    start_registry(config, Linked(opened)) |> map_error(ListenerNotStarted),
  )
  wait_until_opened(started, opened)
}

/// Waits for the end of the first attempt of the connection, or for the
/// end of the registry, with no timer: the connection ends its attempt by
/// its own setup deadline. After a failed attempt it also waits for the
/// end of the registry, which stops at once after its session, so no
/// process stays.
fn wait_until_opened(
  started: actor.Started(Subject(ListenerProcessMessage)),
  opened: Subject(Result(Nil, ConnectError)),
) -> Result(Listener, StartError) {
  let monitor = process.monitor(started.pid)
  let opening =
    process.new_selector()
    |> process.select_map(opened, Opened)
    |> process.select_specific_monitor(monitor, listener_down)
  case process.selector_receive_forever(opening) {
    Opened(Ok(Nil)) -> {
      process.demonitor_process(monitor)
      Ok(Listener(started.data))
    }
    Opened(Error(error)) -> {
      process.selector_receive_forever(opening)
      Error(ConnectFailed(error))
    }
    ListenerDown(reason) -> Error(ListenerNotStarted(actor.InitExited(reason)))
  }
}

fn listener_down(down: Down) -> Opening {
  ListenerDown(down.reason)
}

/// The listener as a child of a gleam_otp supervisor: a supervisor of its
/// own, with the strategy rest_for_one and two children. The first is the
/// registry, registered under `name`. The second is the session. When the
/// supervisor starts the registry again, the new registry takes the name,
/// so a handle of `from_name` stays valid. The name must come from
/// `process.new_name`, made once when the program starts.
///
/// ## Parameters
///
/// - `config`: the connection and the deadline of each `LISTEN`
/// - `name`: the name of the registry
///
/// ## Returns
///
/// A transient supervisor child: the supervisor starts it again after an
/// abnormal exit, and not after `stop`. The start does not wait for the
/// server: the connection connects after it and tries again after its
/// backoff, so a server that is down never fails the supervisor. Until the
/// connection is up, each subscriber gets `NotListening`.
///
/// A crash of the session keeps the subscriptions: each subscriber that
/// listened gets `NotListening`, the new session listens on each channel,
/// and each subscriber gets `Listening` or `ListenFailed`. A crash of the
/// registry, or a new start of the whole child, ends each subscription:
/// each subscriber gets `ListenerProcessDown` from its next call, sees the
/// `Down` of `monitor_registry`, and subscribes again.
///
/// The supervisor's shutdown stops the session, and its connection sends
/// Terminate before it stops. `stop` makes the listener's own supervisor
/// stop with the reason `shutdown`, so the process that starts this child
/// must be a supervisor, or a process that traps exits.
pub fn supervised(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> ChildSpecification(Listener) {
  supervision.supervisor(fn() { start_supervisor(config, name) })
  |> supervision.restart(Transient)
}

/// The registry is significant: its normal end after `stop` shuts the
/// supervisor down. Both children are transient: the session ends normally
/// only when the registry closed it.
fn start_supervisor(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> Result(actor.Started(Listener), actor.StartError) {
  let registry =
    supervision.worker(fn() { start_registry(config, Named(name)) })
    |> supervision.restart(Transient)
    |> supervision.significant(True)
  let session =
    supervision.worker(fn() { start_named_session(config, name) })
    |> supervision.restart(Transient)
  static_supervisor.new(RestForOne)
  |> static_supervisor.auto_shutdown(AnySignificant)
  |> static_supervisor.add(registry)
  |> static_supervisor.add(session)
  |> static_supervisor.start
  |> result.map(started_listener(_, name))
}

fn started_listener(
  started: actor.Started(static_supervisor.Supervisor),
  name: Name(ListenerProcessMessage),
) -> actor.Started(Listener) {
  actor.Started(pid: started.pid, data: from_name(name))
}

/// The listener that runs, or will run, under a name. It makes the handle
/// from the name alone, with no call to the listener, so a handle made
/// once stays valid when the supervisor starts the listener again under
/// the name.
///
/// ## Parameters
///
/// - `name`: the name of `supervised`
///
/// ## Returns
///
/// A handle of the listener. While no registry has the name, each call
/// with it gives `ListenerProcessDown`, and `stop` gives `Nil`.
pub fn from_name(name: Name(ListenerProcessMessage)) -> Listener {
  Listener(subject: process.named_subject(name))
}

/// A monitor of the listener's registry: the process that keeps the
/// subscriptions. The end of the registry ends each subscription, so a
/// subscriber that must know it monitors the registry. A crash of the
/// session alone keeps the registry, and gives no `Down`.
///
/// The caller adds the `Down` to the selector that it receives its
/// `ListenerMessage`s with: `process.select_specific_monitor(selector,
/// monitor, mapping)`, where `mapping` makes a message of the caller's own
/// type from the `Down`. After the `Down`, the caller takes the monitor off
/// the selector with `process.deselect_specific_monitor`, subscribes
/// again through a handle of `from_name`, and monitors the new registry.
///
/// ## Parameters
///
/// - `listener`: the listener
///
/// ## Returns
///
/// - `Ok(Monitor)`: a monitor of the registry that runs now, owned by the
///   caller. A registry that stops at once gives its `Down` at once.
/// - `Error(ListenerProcessDown)`: no registry runs
pub fn monitor_registry(listener: Listener) -> Result(Monitor, ListenerError) {
  subject_owner(listener.subject)
  |> result.map(process.monitor)
  |> replace_error(ListenerProcessDown)
}

/// Finds the registry by its name once, so the session sends to its
/// process ID. The supervisor starts the session after the registry, so
/// the name has a process.
fn start_named_session(
  config: ListenerConfig,
  name: Name(ListenerProcessMessage),
) -> Result(actor.Started(Subject(SessionMessage)), actor.StartError) {
  process.named(name)
  |> replace_error(actor.InitFailed("the registry of the listener is gone"))
  |> try(start_session(config, _))
}

/// Stops the listener and its connection.
///
/// ## Parameters
///
/// - `listener`: the listener to stop
///
/// ## Returns
///
/// `Nil` once the connection closed, also when the listener is gone
/// already. Its subscribers get no message. A supervised listener's
/// supervisor then stops, and is not started again.
pub fn stop(listener: Listener) -> Nil {
  call(listener, StopRequest) |> result.unwrap(Nil)
}

// Subscribing -----------------------------------------------------------------

/// Subscribes a sink to a channel. The first subscription of a channel
/// makes the session send `LISTEN`. The registry monitors the process that
/// owns the sink's subject, and ends the subscription when that process
/// stops, or when the sink's map crashes.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `channel`: the exact channel name, at most 63 bytes
/// - `subscriber`: where each notification, `NotListening`, `Listening`
///   and `ListenFailed` goes. Its map runs in the registry's process.
///
/// ## Returns
///
/// - `Ok(Subscription)`: the session is up and listens on the channel,
///   and the subscriber gets no message for it; or the session is not up,
///   and the subscriber got `NotListening`, with `Listening` or
///   `ListenFailed` after the next login (see the module documentation)
/// - `Error(ListenerError)`: the name is too long, the sink's subject has
///   no process, the `LISTEN` failed with a `ListenFailure`, or the
///   registry is gone
pub fn subscribe(
  listener: Listener,
  channel: String,
  subscriber: Sink(ListenerMessage),
) -> Result(Subscription, ListenerError) {
  use Nil <- try(check_channel(channel))
  use owner <- try(
    sink.owner(subscriber) |> replace_error(SubscriberHasNoProcess),
  )
  call(listener, SubscribeRequest(channel, subscriber, owner, _))
  |> replace_error(ListenerProcessDown)
  |> result.flatten
}

fn check_channel(channel: String) -> Result(Nil, ListenerError) {
  case byte_size(<<channel:utf8>>) > longest_channel_bytes {
    True -> Error(ChannelTooLong(channel))
    False -> Ok(Nil)
  }
}

/// Ends a subscription. When it was the last one of its channel, the
/// session sends `UNLISTEN`.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `subscription`: the subscription to end
///
/// ## Returns
///
/// - `Ok(Nil)`: the subscription is ended, also when it was ended already
/// - `Error(ListenerGone)`: the registry is gone
pub fn unsubscribe(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, UnsubscribeError) {
  call(listener, UnsubscribeRequest(subscription, _))
  |> replace_error(ListenerGone)
}

/// Waits for the answer of the registry until it comes, or gives
/// `Error(Nil)` when the registry is gone.
fn call(
  listener: Listener,
  make: fn(ReplyTo(reply)) -> ListenerProcessMessage,
) -> Result(reply, Nil) {
  use registry <- try(subject_owner(listener.subject))
  call_process(registry, send_request(registry, make, _))
}

fn send_request(
  registry: Pid,
  make: fn(ReplyTo(reply)) -> ListenerProcessMessage,
  reply_to: ReplyTo(reply),
) -> Nil {
  send_to_registry(registry, make(reply_to))
}
