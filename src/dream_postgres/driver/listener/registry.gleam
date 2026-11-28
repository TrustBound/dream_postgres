//// The registry of a listener: the actor that keeps the subscriptions and
//// decides when a channel needs `LISTEN` or `UNLISTEN`. It does no I/O (see
//// `driver/listener`).
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection/event.{type ConnectError}
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/listener/process_message.{
  type ListenFailure, type Listened, type ListenerConfig, type ListenerError,
  type ListenerMessage, type ListenerProcessMessage, type ReplyTo,
  type SessionMessage, type Subscription, CloseRequest, ListenFailed, ListenLost,
  ListenNotDone, ListenRequest, ListenWorked, Listening, MonitoredProcessDown,
  NotListening, NotificationArrived, NotificationReceived, SessionConnectFailed,
  SessionLost, SessionStarted, SessionUp, StopRequest, SubscribeFailed,
  SubscribeRequest, Subscription, UnlistenRequest, UnsubscribeRequest,
  call_process, reply, request_of,
}
import dream_postgres/driver/listener/session.{start as start_session}
import dream_postgres/driver/sink.{
  type Delivery, type Sink, Delivered, MapFailed,
}
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Subject,
}
import gleam/list.{any, filter, fold, unique}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result.{replace, replace_error, try}

// Types -----------------------------------------------------------------------

/// Where a registry runs.
pub type Placement {
  /// Started by `start`: the registry starts its session, linked to it,
  /// and answers the starter after the first attempt of the connection.
  Linked(starter: Subject(Result(Nil, ConnectError)))
  /// A child of the listener's supervisor, under the name: the supervisor
  /// starts the session.
  Named(name: Name(ListenerProcessMessage))
}

/// A subscriber of one channel. `listening` says whether the session
/// listens on the channel: it is `False` from a loss until the `LISTEN`
/// after the reconnect.
type Subscriber {
  Subscriber(
    channel: String,
    /// Where each message to the subscriber goes.
    sink: Sink(ListenerMessage),
    listening: Bool,
  )
}

/// What a subscribe does.
type Admission {
  /// Adds the subscriber. With `listening` `False`, it gets `NotListening`.
  Admit(listening: Bool)
  /// Refuses the subscriber with the failure of its `LISTEN`.
  Refuse(failure: ListenFailure)
}

/// The session that the registry asks, and the registry's monitor of it.
type SessionLink {
  SessionLink(subject: Subject(SessionMessage), pid: Pid, monitor: Monitor)
}

type RegistryState {
  RegistryState(
    /// The session that runs now. A registry has none until its session
    /// started, and none from the end of a session until the next one
    /// started.
    session: Option(SessionLink),
    /// Whether the session is up: the registry handled the session's
    /// report that its connection logged in, and no loss or new session
    /// since. Only an up session gets a `LISTEN` for a subscribe.
    up: Bool,
    /// The starter of `start`, until the first attempt of the connection
    /// ended. A supervised listener has none.
    starter: Option(Subject(Result(Nil, ConnectError))),
    /// Each subscription, by the monitor of its subscriber's process.
    subscriptions: Dict(Monitor, Subscriber),
  )
}

// Starting --------------------------------------------------------------------

/// The start of the registry does no I/O. A registry of `start` also
/// starts its session, which connects after it.
pub fn start(
  config: ListenerConfig,
  placement: Placement,
) -> Result(actor.Started(Subject(ListenerProcessMessage)), actor.StartError) {
  let timeout = config.connection.setup_timeout_milliseconds
  actor.new_with_initialiser(timeout, initialise_registry(_, config, placement))
  |> actor.on_message(handle_registry_message)
  |> with_name(placement)
  |> actor.start
}

fn with_name(
  builder: actor.Builder(
    RegistryState,
    ListenerProcessMessage,
    Subject(ListenerProcessMessage),
  ),
  placement: Placement,
) -> actor.Builder(
  RegistryState,
  ListenerProcessMessage,
  Subject(ListenerProcessMessage),
) {
  case placement {
    Named(name) -> actor.named(builder, name)
    Linked(_starter) -> builder
  }
}

fn initialise_registry(
  subject: Subject(ListenerProcessMessage),
  config: ListenerConfig,
  placement: Placement,
) -> Result(
  actor.Initialised(
    RegistryState,
    ListenerProcessMessage,
    Subject(ListenerProcessMessage),
  ),
  String,
) {
  case placement {
    Linked(starter) ->
      start_session(config, process.self())
      |> replace(registry_initialised(subject, Some(starter)))
      |> replace_error("the session did not start")
    Named(_name) -> Ok(registry_initialised(subject, None))
  }
}

fn registry_initialised(
  subject: Subject(ListenerProcessMessage),
  starter: Option(Subject(Result(Nil, ConnectError))),
) -> actor.Initialised(
  RegistryState,
  ListenerProcessMessage,
  Subject(ListenerProcessMessage),
) {
  let state =
    RegistryState(session: None, up: False, starter:, subscriptions: dict.new())
  let selector =
    process.new_selector()
    |> process.select_record(
      atom.create("dream_postgres_listener_request"),
      1,
      request_of,
    )
    |> process.select_monitors(monitored_process_down)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(subject)
}

fn monitored_process_down(down: Down) -> ListenerProcessMessage {
  MonitoredProcessDown(down.monitor)
}

// Messages --------------------------------------------------------------------

fn handle_registry_message(
  state: RegistryState,
  message: ListenerProcessMessage,
) -> actor.Next(RegistryState, ListenerProcessMessage) {
  case message {
    SubscribeRequest(channel:, subscriber:, owner:, reply: reply_to) ->
      actor.continue(add_subscriber(state, channel, subscriber, owner, reply_to))
    UnsubscribeRequest(subscription:, reply: reply_to) -> {
      let state = remove_subscriber(state, subscription.monitor)
      reply(reply_to, Nil)
      actor.continue(state)
    }
    StopRequest(reply: reply_to) -> {
      close_session(state)
      reply(reply_to, Nil)
      actor.stop()
    }
    SessionStarted(session:, pid:) ->
      actor.continue(session_started(state, session, pid))
    SessionUp -> actor.continue(session_up(state))
    SessionLost -> actor.continue(lost(RegistryState(..state, up: False)))
    SessionConnectFailed(error) -> first_connect_failed(state, error)
    NotificationReceived(notification) ->
      actor.continue(deliver(state, notification))
    MonitoredProcessDown(monitor) ->
      actor.continue(monitored_process_ended(state, monitor))
  }
}

/// Adds a subscriber, or refuses it.
fn add_subscriber(
  state: RegistryState,
  channel: String,
  subscriber_sink: Sink(ListenerMessage),
  owner: Pid,
  reply_to: ReplyTo(Result(Subscription, ListenerError)),
) -> RegistryState {
  let #(state, answer) = case admission(state, channel) {
    Admit(listening:) ->
      added(state, Subscriber(channel, subscriber_sink, listening), owner)
    Refuse(error) -> #(state, Error(SubscribeFailed(error)))
  }
  reply(reply_to, answer)
  state
}

/// A subscribe while the session is not up gets no `LISTEN`: the
/// subscriber gets `NotListening`, and the `LISTEN` of the next session
/// up gives it `Listening` or `ListenFailed`. On an up session only the
/// first subscriber of a channel needs a `LISTEN`, and a later one
/// listens when the others do.
fn admission(state: RegistryState, channel: String) -> Admission {
  case state.up, subscribers_on(state, channel) {
    False, _subscribers -> Admit(False)
    True, [] -> listen(state, channel) |> listen_admission
    True, subscribers -> Admit(any(subscribers, is_listening))
  }
}

/// A `LISTEN` that failed because the connection is not up is kept: the
/// connection process connects, and the registry asks for `LISTEN` then.
fn listen_admission(listened: Listened) -> Admission {
  case listened {
    ListenWorked -> Admit(True)
    ListenLost -> Admit(False)
    ListenNotDone(failure) -> Refuse(failure)
  }
}

fn added(
  state: RegistryState,
  subscriber: Subscriber,
  owner: Pid,
) -> #(RegistryState, Result(Subscription, ListenerError)) {
  let monitor = process.monitor(owner)
  let subscriptions = dict.insert(state.subscriptions, monitor, subscriber)
  let state = RegistryState(..state, subscriptions:)
  let state = case subscriber.listening {
    True -> state
    False -> tell(NotListening)(state, #(monitor, subscriber))
  }
  #(state, Ok(Subscription(monitor)))
}

/// Removes the subscriber of a monitor, if it is still there. When it was
/// the last one of its channel, the session sends `UNLISTEN`.
fn remove_subscriber(state: RegistryState, monitor: Monitor) -> RegistryState {
  case dict.get(state.subscriptions, monitor) {
    Ok(subscriber) -> removed(state, monitor, subscriber.channel)
    Error(Nil) -> state
  }
}

fn removed(
  state: RegistryState,
  monitor: Monitor,
  channel: String,
) -> RegistryState {
  process.demonitor_process(monitor)
  let state =
    RegistryState(
      ..state,
      subscriptions: dict.delete(state.subscriptions, monitor),
    )
  case has_subscribers(state, channel) {
    True -> state
    False -> unlisten(state, channel)
  }
}

/// Asks the session for `UNLISTEN`. Its result changes nothing: with no
/// session, or after a loss, the next session does not listen on the
/// channel, because the channel has no subscriber to listen again for, and
/// after a refusal the notifications of the channel reach no subscriber.
fn unlisten(state: RegistryState, channel: String) -> RegistryState {
  call_session(state, UnlistenRequest(channel, _)) |> result.unwrap(Nil)
  state
}

/// Asks the session for `LISTEN`. With no session, or a session that
/// stops before it answers, the connection is not up: the next session
/// listens.
fn listen(state: RegistryState, channel: String) -> Listened {
  call_session(state, ListenRequest(channel, _)) |> result.unwrap(ListenLost)
}

/// Closes the connection of the session, which then stops. With no
/// session there is nothing to close.
fn close_session(state: RegistryState) -> Nil {
  call_session(state, CloseRequest) |> result.unwrap(Nil)
}

/// Waits for the answer of the session until it comes, or gives
/// `Error(Nil)` when the registry has no session or the session is gone.
/// The session never waits for the registry, so the two never wait for
/// each other.
fn call_session(
  state: RegistryState,
  make: fn(ReplyTo(reply)) -> SessionMessage,
) -> Result(reply, Nil) {
  use session <- try(option.to_result(state.session, Nil))
  call_process(session.pid, send_to_session(session, make, _))
}

fn send_to_session(
  session: SessionLink,
  make: fn(ReplyTo(reply)) -> SessionMessage,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(session.subject, make(reply_to))
}

// Sessions, notifications and reconnects --------------------------------------

/// A new session listens on nothing. A subscriber that still listens
/// listened on an earlier session whose end the registry did not see yet,
/// so it gets `NotListening`.
fn session_started(
  state: RegistryState,
  subject: Subject(SessionMessage),
  pid: Pid,
) -> RegistryState {
  let monitor = process.monitor(pid)
  lost(
    RegistryState(
      ..state,
      session: Some(SessionLink(subject:, pid:, monitor:)),
      up: False,
    ),
  )
}

/// Once the connection is up, the first time or again, the registry asks
/// the session for `LISTEN` on each channel and tells its subscribers the
/// result. The first one of a listener from `start` also answers its
/// starter.
fn session_up(state: RegistryState) -> RegistryState {
  let state = answer_starter(RegistryState(..state, up: True))
  list.fold(channels(state), state, listen_on_session)
}

fn answer_starter(state: RegistryState) -> RegistryState {
  case state.starter {
    Some(starter) -> process.send(starter, Ok(Nil))
    None -> Nil
  }
  RegistryState(..state, starter: None)
}

/// A failed first attempt of a listener from `start` answers its starter
/// and stops the listener. Under a supervisor the connection process tries
/// again by itself.
fn first_connect_failed(
  state: RegistryState,
  error: ConnectError,
) -> actor.Next(RegistryState, ListenerProcessMessage) {
  case state.starter {
    Some(starter) -> {
      process.send(starter, Error(error))
      close_session(state)
      actor.stop()
    }
    None -> actor.continue(state)
  }
}

/// The end of the session is a loss: the next session listens again. Any
/// other monitor is a subscriber's.
fn monitored_process_ended(
  state: RegistryState,
  monitor: Monitor,
) -> RegistryState {
  case option.map(state.session, monitor_of) == Some(monitor) {
    True -> lost(RegistryState(..state, session: None, up: False))
    False -> remove_subscriber(state, monitor)
  }
}

fn monitor_of(session: SessionLink) -> Monitor {
  session.monitor
}

fn deliver(state: RegistryState, notification: Notification) -> RegistryState {
  entries_on(state, notification.channel)
  |> fold(state, tell(NotificationArrived(notification)))
}

/// A step of a fold over subscriptions: sends the message through the
/// sink of one subscription. A sink whose map crashed is dropped: its
/// subscription ends, the same as when the subscriber's process stops.
fn tell(
  message: ListenerMessage,
) -> fn(RegistryState, #(Monitor, Subscriber)) -> RegistryState {
  fn(state: RegistryState, entry: #(Monitor, Subscriber)) {
    let #(monitor, subscriber) = entry
    sink.deliver(subscriber.sink, message)
    |> keep_subscriber(state, monitor, _)
  }
}

fn keep_subscriber(
  state: RegistryState,
  monitor: Monitor,
  delivery: Delivery,
) -> RegistryState {
  case delivery {
    Delivered -> state
    MapFailed -> remove_subscriber(state, monitor)
  }
}

/// Only the subscribers that listen get `NotListening`: one that came
/// while the connection was not up got it already.
fn lost(state: RegistryState) -> RegistryState {
  let listening = dict.to_list(state.subscriptions) |> filter(entry_listens)
  RegistryState(
    ..state,
    subscriptions: dict.map_values(state.subscriptions, not_listening),
  )
  |> fold(listening, _, tell(NotListening))
}

fn entry_listens(entry: #(Monitor, Subscriber)) -> Bool {
  is_listening(entry.1)
}

fn not_listening(_monitor: Monitor, subscriber: Subscriber) -> Subscriber {
  Subscriber(..subscriber, listening: False)
}

fn listen_on_session(state: RegistryState, channel: String) -> RegistryState {
  let listened = listen(state, channel)
  let listening = listened == ListenWorked
  let entries = entries_on(state, channel)
  let state =
    RegistryState(
      ..state,
      subscriptions: dict.map_values(
        state.subscriptions,
        fn(_monitor, subscriber) {
          listening_after(subscriber, channel, listening)
        },
      ),
    )
  case listen_message(channel, listened) {
    Some(message) -> fold(entries, state, tell(message))
    None -> state
  }
}

/// A `LISTEN` that meets a loss tells nothing: the subscribers got
/// `NotListening` already, and the next reconnect listens again.
fn listen_message(
  channel: String,
  listened: Listened,
) -> Option(ListenerMessage) {
  case listened {
    ListenWorked -> Some(Listening(channel))
    ListenLost -> None
    ListenNotDone(failure) -> Some(ListenFailed(channel, failure))
  }
}

/// The subscribers of `channel` listen when its `LISTEN` worked.
fn listening_after(
  subscriber: Subscriber,
  channel: String,
  listening: Bool,
) -> Subscriber {
  case subscriber.channel == channel {
    True -> Subscriber(..subscriber, listening:)
    False -> subscriber
  }
}

fn is_listening(subscriber: Subscriber) -> Bool {
  subscriber.listening
}

fn channels(state: RegistryState) -> List(String) {
  dict.values(state.subscriptions) |> list.map(channel_of) |> unique
}

fn channel_of(subscriber: Subscriber) -> String {
  subscriber.channel
}

fn has_subscribers(state: RegistryState, channel: String) -> Bool {
  subscribers_on(state, channel) != []
}

/// Each subscription of `channel`, with the monitor that names it.
fn entries_on(
  state: RegistryState,
  channel: String,
) -> List(#(Monitor, Subscriber)) {
  dict.to_list(state.subscriptions) |> filter(entry_on_channel(_, channel))
}

fn entry_on_channel(entry: #(Monitor, Subscriber), channel: String) -> Bool {
  on_channel(entry.1, channel)
}

fn subscribers_on(state: RegistryState, channel: String) -> List(Subscriber) {
  dict.values(state.subscriptions) |> filter(on_channel(_, channel))
}

fn on_channel(subscriber: Subscriber, channel: String) -> Bool {
  subscriber.channel == channel
}
