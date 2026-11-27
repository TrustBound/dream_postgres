//// A listener: one gleam_otp actor that owns its own connection process,
//// outside any pool, and gives the notifications of `NOTIFY` to the
//// processes that subscribe to a channel.
////
//// The first subscriber of a channel makes the listener send `LISTEN` for
//// it, and when the last one goes, by `unsubscribe` or because its process
//// stopped, the listener sends `UNLISTEN`. Channel names are exact: the
//// listener quotes them, so `Jobs` and `jobs` are two channels.
////
//// The connection process sends each notification to the listener as it
//// arrives, and the listener sends it on to each subscriber of its channel,
//// in the order the server sent them.
////
//// A subscriber hears whether its session listens. When the connection is
//// lost, each subscriber gets `NotListening` at once, and the connection
//// process connects again. The new session listens on nothing, so the
//// listener sends `LISTEN` again for each channel, and each subscriber
//// gets `Listening`, or `ListenFailed` when that `LISTEN` failed. The
//// server keeps no notification for a session that is gone, so the
//// notifications between `NotListening` and `Listening` may be missed. A
//// subscribe while the connection is not up, lost or not connected yet
//// under a supervisor, is kept the same way: the subscriber gets
//// `NotListening` at once, and `Listening` once the session is up.
////
//// A call to the listener has no timeout: the listener answers each one
//// after at most its own `LISTEN` or `UNLISTEN`, and a listener that is gone
//// gives `ListenerProcessDown`. So a subscription never exists without the
//// handle that ends it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/connection.{
  type ConnectError, type Connection, type ConnectionConfig,
  type ConnectionEvent, type Notification, type ScriptError, Connected,
  ConnectionConfig, ConnectionEnded, ConnectionProcessDown, DeadlinePassed,
  Disconnected, ReconnectFailed, Reconnected, ScriptCopyRefused, ScriptFailed,
  ScriptNotConnected, ScriptRefused, ScriptRequestFailed, ScriptUnencodable,
}
import dream_postgres/internal/cell.{type ServerReport, type TransactionStatus}
import gleam/bit_array.{byte_size}
import gleam/dict.{type Dict}
import gleam/erlang/process.{
  type Down, type Monitor, type Pid, type Subject, subject_owner,
}
import gleam/list.{any, each, filter, unique}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result.{map_error, replace, replace_error, try}
import gleam/string.{replace as replace_text}

// Types -----------------------------------------------------------------------

/// Everything a listener needs.
pub type ListenerConfig {
  ListenerConfig(
    /// The connection of the listener. The listener sets its `events` and
    /// its `notifications` to its own subjects.
    connection: ConnectionConfig,
    /// The longest time that each `LISTEN` and `UNLISTEN` can take.
    deadline_milliseconds: Int,
  )
}

/// What a subscriber gets from the listener.
pub type ListenerMessage {
  /// A notification on the channel of the subscription.
  NotificationArrived(notification: Notification)
  /// The session does not listen on the channel of the subscription: the
  /// connection is not up yet, or it is lost. `Listening` or
  /// `ListenFailed` follows once the listener sent `LISTEN` on a session
  /// that is up.
  NotListening
  /// The listener sent `LISTEN` for the channel on a session that is up:
  /// the first one, or a new one after a loss. Notifications on the
  /// channel between the last `NotListening` and this message may be
  /// missed.
  Listening(channel: String)
  /// The `LISTEN` for the channel failed on a session that is up, so the
  /// session does not listen on it. The listener tries again after the
  /// next reconnect. A `LISTEN` that meets a loss gives no message: the
  /// subscriber got `NotListening` already, and `Listening` follows the
  /// next reconnect.
  ListenFailed(channel: String, error: ListenFailure)
}

/// Why the `LISTEN` for a channel failed on a session that is up.
pub type ListenFailure {
  /// The server refused the `LISTEN`. The session stays usable.
  ListenRefused(report: ServerReport, transaction_status: TransactionStatus)
  /// The server answered the `LISTEN` as no PostgreSQL server does: with
  /// an error after a first result, or with a COPY. The session stays
  /// usable.
  ListenAnswerUnexpected
  /// The `LISTEN` did not end by the deadline of the listener. `cancelled`
  /// says whether the server confirmed a cancel.
  ListenDeadlinePassed(cancelled: Bool)
  /// The channel name holds a zero byte, so the `LISTEN` cannot be
  /// written. No byte went to the server.
  ChannelHasZeroByte
  /// The connection process of the listener is gone, for example because
  /// an exit signal stopped it.
  ListenerConnectionDown
}

/// Why a subscribe failed.
pub type ListenerError {
  /// The channel name has more than 63 bytes. PostgreSQL cuts such a name
  /// short, so its notifications would come with another name.
  ChannelTooLong(channel: String)
  /// The subscriber subject has no process: it has a name that no process
  /// has.
  SubscriberHasNoProcess
  /// The `LISTEN` failed on a session that is up, so the subscription is
  /// not kept. A connection that is not up is not a failure: the
  /// subscription is kept and gets `NotListening`.
  SubscribeFailed(error: ListenFailure)
  /// The listener process is gone.
  ListenerProcessDown
}

/// Why an unsubscribe failed.
pub type UnsubscribeError {
  /// The listener process is gone.
  ListenerGone
}

/// Why a listener did not start.
pub type StartError {
  /// Its connection could not connect and log in.
  ConnectFailed(error: ConnectError)
  /// The listener process itself did not start.
  ListenerNotStarted(error: actor.StartError)
}

/// A listener process.
pub opaque type Listener {
  Listener(subject: Subject(Message), pid: Pid)
}

/// One subscription to one channel. `unsubscribe` ends it.
pub opaque type Subscription {
  Subscription(monitor: Monitor)
}

/// A reply target: an alias of the caller (see the FFI module).
type ReplyTo(reply)

type Message {
  SubscribeRequest(
    channel: String,
    subscriber: Subject(ListenerMessage),
    owner: Pid,
    reply: ReplyTo(Result(Subscription, ListenerError)),
  )
  UnsubscribeRequest(subscription: Subscription, reply: ReplyTo(Nil))
  StopRequest(reply: ReplyTo(Nil))
  NotificationReceived(notification: Notification)
  ConnectionEventReceived(event: ConnectionEvent)
  SubscriberDown(monitor: Monitor)
}

/// What the starter of `start` waits for.
type Opening {
  Opened(result: Result(Nil, ConnectError))
  ListenerDown(reason: process.ExitReason)
}

/// A subscriber of one channel. `listening` says whether the session
/// listens on the channel: it is `False` from a loss until the `LISTEN`
/// after the reconnect.
type Subscriber {
  Subscriber(
    channel: String,
    subject: Subject(ListenerMessage),
    listening: Bool,
  )
}

/// What a `LISTEN` gave.
type Listened {
  /// The session listens on the channel.
  ListenWorked
  /// The session is not up: it is lost, or a supervised connection did not
  /// connect yet. The listener listens after the next reconnect.
  ListenLost
  /// The `LISTEN` failed on a session that is up.
  ListenNotDone(failure: ListenFailure)
}

/// What a subscribe does.
type Admission {
  /// Adds the subscriber. With `listening` `False`, it gets `NotListening`.
  Admit(listening: Bool)
  /// Refuses the subscriber with the failure of its `LISTEN`.
  Refuse(failure: ListenFailure)
}

type State {
  State(
    connection: Connection,
    /// The starter of `start`, until the first attempt of the connection
    /// ended. A supervised listener has none.
    starter: Option(Subject(Result(Nil, ConnectError))),
    deadline_milliseconds: Int,
    /// Each subscription, by the monitor of its subscriber's process.
    subscriptions: Dict(Monitor, Subscriber),
  )
}

/// The longest channel name, in bytes: PostgreSQL's NAMEDATALEN less one.
const longest_channel_bytes = 63

@external(erlang, "dream_postgres_listener_ffi", "call")
fn call_process(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
) -> Result(reply, Nil)

@external(erlang, "dream_postgres_listener_ffi", "reply")
fn reply(to: ReplyTo(reply), value: reply) -> Nil

// Starting and stopping -------------------------------------------------------

/// Starts a listener, linked to the caller, and waits until its connection
/// connected and logged in.
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
    start_process(config, Some(opened)) |> map_error(ListenerNotStarted),
  )
  wait_until_opened(started, opened)
}

/// Waits for the end of the first attempt of the connection, or for the
/// end of the listener, with no timer: the connection ends its attempt by
/// its own setup deadline. After a failed attempt it also waits for the
/// end of the listener, which stops at once, so no process stays.
fn wait_until_opened(
  started: actor.Started(Listener),
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
      Ok(started.data)
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

/// The listener as a child of a gleam_otp supervisor.
///
/// ## Parameters
///
/// - `config`: the connection and the deadline of each `LISTEN`
///
/// ## Returns
///
/// A worker child that starts the listener with `config`. The start does
/// not wait for the server: the connection connects after it and tries
/// again after its backoff, so a server that is down never fails the
/// supervisor. Until the connection is up, each subscriber gets
/// `NotListening`.
pub fn supervised(config: ListenerConfig) -> ChildSpecification(Listener) {
  supervision.worker(fn() { start_process(config, None) })
}

/// The start of the listener does no I/O: its connection process starts
/// supervised, and connects after it.
fn start_process(
  config: ListenerConfig,
  starter: Option(Subject(Result(Nil, ConnectError))),
) -> Result(actor.Started(Listener), actor.StartError) {
  let timeout = config.connection.setup_timeout_milliseconds
  actor.new_with_initialiser(timeout, initialise(_, config, starter))
  |> actor.on_message(handle_message)
  |> actor.start
}

fn initialise(
  subject: Subject(Message),
  config: ListenerConfig,
  starter: Option(Subject(Result(Nil, ConnectError))),
) -> Result(actor.Initialised(State, Message, Listener), String) {
  let notifications = process.new_subject()
  let events = process.new_subject()
  let connection_config =
    ConnectionConfig(
      ..config.connection,
      events: Some(events),
      notifications: Some(notifications),
    )
  connection.supervised(connection_config).start()
  |> result.map(initialised(subject, config, _, starter, notifications, events))
  |> replace_error("the connection process did not start")
}

fn initialised(
  subject: Subject(Message),
  config: ListenerConfig,
  started: actor.Started(Connection),
  starter: Option(Subject(Result(Nil, ConnectError))),
  notifications: Subject(Notification),
  events: Subject(ConnectionEvent),
) -> actor.Initialised(State, Message, Listener) {
  let state =
    State(
      connection: started.data,
      starter:,
      deadline_milliseconds: config.deadline_milliseconds,
      subscriptions: dict.new(),
    )
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(notifications, NotificationReceived)
    |> process.select_map(events, ConnectionEventReceived)
    |> process.select_monitors(down_message)
  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(Listener(subject:, pid: process.self()))
}

fn down_message(down: Down) -> Message {
  SubscriberDown(down.monitor)
}

/// Stops the listener and its connection.
///
/// ## Parameters
///
/// - `listener`: the listener to stop
///
/// ## Returns
///
/// `Nil`, also when the listener is gone already. Its subscribers get no
/// message.
pub fn stop(listener: Listener) -> Nil {
  call(listener, StopRequest) |> result.unwrap(Nil)
}

// Subscribing -----------------------------------------------------------------

/// Subscribes a subject to a channel. The first subscription of a channel
/// sends `LISTEN`. The listener monitors the subject's process and ends the
/// subscription when that process stops.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `channel`: the exact channel name, at most 63 bytes
/// - `subscriber`: where each notification, `NotListening`, `Listening`
///   and `ListenFailed` goes
///
/// ## Returns
///
/// - `Ok(Subscription)`: the session listens on the channel, or the
///   connection is not up and the subscriber got `NotListening`
/// - `Error(ListenerError)`: the name is too long, the subject has no
///   process, the `LISTEN` failed with a `ListenFailure`, or the listener
///   is gone
pub fn subscribe(
  listener: Listener,
  channel: String,
  subscriber: Subject(ListenerMessage),
) -> Result(Subscription, ListenerError) {
  use Nil <- try(check_channel(channel))
  use owner <- try(
    subject_owner(subscriber) |> replace_error(SubscriberHasNoProcess),
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
/// listener sends `UNLISTEN`.
///
/// ## Parameters
///
/// - `listener`: the listener
/// - `subscription`: the subscription to end
///
/// ## Returns
///
/// - `Ok(Nil)`: the subscription is ended, also when it was ended already
/// - `Error(ListenerGone)`: the listener is gone
pub fn unsubscribe(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, UnsubscribeError) {
  call(listener, UnsubscribeRequest(subscription, _))
  |> replace_error(ListenerGone)
}

/// Waits for the answer until it comes, or gives `Error(Nil)` when the
/// listener is gone.
fn call(
  listener: Listener,
  make: fn(ReplyTo(reply)) -> Message,
) -> Result(reply, Nil) {
  call_process(listener.pid, send_request(listener, make, _))
}

fn send_request(
  listener: Listener,
  make: fn(ReplyTo(reply)) -> Message,
  reply_to: ReplyTo(reply),
) -> Nil {
  process.send(listener.subject, make(reply_to))
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    SubscribeRequest(channel:, subscriber:, owner:, reply: reply_to) ->
      actor.continue(add_subscriber(state, channel, subscriber, owner, reply_to))
    UnsubscribeRequest(subscription:, reply: reply_to) -> {
      let state = remove_subscriber(state, subscription.monitor)
      reply(reply_to, Nil)
      actor.continue(state)
    }
    StopRequest(reply: reply_to) -> {
      connection.stop(state.connection)
      reply(reply_to, Nil)
      actor.stop()
    }
    NotificationReceived(notification) -> {
      deliver(state, notification)
      actor.continue(state)
    }
    ConnectionEventReceived(event) -> connection_event(state, event)
    SubscriberDown(monitor) -> actor.continue(remove_subscriber(state, monitor))
  }
}

/// Adds a subscriber, or refuses it.
fn add_subscriber(
  state: State,
  channel: String,
  subject: Subject(ListenerMessage),
  owner: Pid,
  reply_to: ReplyTo(Result(Subscription, ListenerError)),
) -> State {
  let #(state, answer) = case admission(state, channel) {
    Admit(listening:) ->
      added(state, Subscriber(channel, subject, listening), owner)
    Refuse(error) -> #(state, Error(SubscribeFailed(error)))
  }
  reply(reply_to, answer)
  state
}

/// Only the first subscriber of a channel needs a `LISTEN`. A later one
/// listens when the others do.
fn admission(state: State, channel: String) -> Admission {
  case subscribers_on(state, channel) {
    [] -> listen(state, channel) |> listen_admission
    subscribers -> Admit(any(subscribers, is_listening))
  }
}

/// A `LISTEN` that failed because the connection is not up is kept: the
/// connection process connects, and the listener listens then.
fn listen_admission(listened: Listened) -> Admission {
  case listened {
    ListenWorked -> Admit(True)
    ListenLost -> Admit(False)
    ListenNotDone(failure) -> Refuse(failure)
  }
}

fn added(
  state: State,
  subscriber: Subscriber,
  owner: Pid,
) -> #(State, Result(Subscription, ListenerError)) {
  let monitor = process.monitor(owner)
  let subscriptions = dict.insert(state.subscriptions, monitor, subscriber)
  case subscriber.listening {
    True -> Nil
    False -> process.send(subscriber.subject, NotListening)
  }
  #(State(..state, subscriptions:), Ok(Subscription(monitor)))
}

/// Removes the subscriber of a monitor, if it is still there. When it was
/// the last one of its channel, the listener sends `UNLISTEN`.
fn remove_subscriber(state: State, monitor: Monitor) -> State {
  case dict.get(state.subscriptions, monitor) {
    Ok(subscriber) -> removed(state, monitor, subscriber.channel)
    Error(Nil) -> state
  }
}

fn removed(state: State, monitor: Monitor, channel: String) -> State {
  process.demonitor_process(monitor)
  let state =
    State(..state, subscriptions: dict.delete(state.subscriptions, monitor))
  case has_subscribers(state, channel) {
    True -> state
    False -> unlisten(state, channel)
  }
}

/// Sends `UNLISTEN`. Its result changes nothing: after a loss the new
/// session does not listen on the channel, because the channel has no
/// subscriber to listen again for, and after a refusal the notifications
/// of the channel reach no subscriber.
fn unlisten(state: State, channel: String) -> State {
  case run(state, "UNLISTEN " <> quoted(channel)) {
    Ok(Nil) | Error(_loss_or_refusal) -> state
  }
}

fn listen(state: State, channel: String) -> Listened {
  run(state, "LISTEN " <> quoted(channel)) |> listened
}

/// The SQL is one `LISTEN` in one Query message. Its only encode failure
/// is the zero byte: the message is far below the 2 GiB limit, because
/// the channel has at most 63 bytes. A PostgreSQL server answers it with
/// one result or one error, so `ScriptFailed` and `ScriptCopyRefused` come
/// only from a server that breaks the protocol.
fn listened(result: Result(Nil, ScriptError)) -> Listened {
  case result {
    Ok(Nil) -> ListenWorked
    Error(ScriptRequestFailed(ConnectionEnded(_)))
    | Error(ScriptNotConnected(_)) -> ListenLost
    Error(ScriptRequestFailed(ConnectionProcessDown)) ->
      ListenNotDone(ListenerConnectionDown)
    Error(ScriptRequestFailed(DeadlinePassed(cancelled:))) ->
      ListenNotDone(ListenDeadlinePassed(cancelled))
    Error(ScriptUnencodable(_zero_byte)) -> ListenNotDone(ChannelHasZeroByte)
    Error(ScriptRefused(report:, transaction_status:)) ->
      ListenNotDone(ListenRefused(report, transaction_status))
    Error(ScriptFailed(..)) | Error(ScriptCopyRefused(..)) ->
      ListenNotDone(ListenAnswerUnexpected)
  }
}

fn run(state: State, sql: String) -> Result(Nil, ScriptError) {
  connection.run_housekeeping_script(
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

// Notifications and reconnects ------------------------------------------------

fn deliver(state: State, notification: Notification) -> Nil {
  subscribers_of(state, notification.channel)
  |> each(process.send(_, NotificationArrived(notification)))
}

/// A loss tells each subscriber that listens. Once the session is up, the
/// first one or a new one after a loss, the listener sends `LISTEN` for
/// each channel and tells its subscribers the result. A failed attempt
/// needs nothing: the connection process tries again by itself. The first
/// attempt of a listener from `start` also answers its starter, and a
/// failed one stops the listener.
fn connection_event(
  state: State,
  event: ConnectionEvent,
) -> actor.Next(State, Message) {
  case event, state.starter {
    Connected, Some(starter) -> {
      process.send(starter, Ok(Nil))
      actor.continue(State(..state, starter: None))
    }
    Connected, None | Reconnected, _ ->
      actor.continue(list.fold(channels(state), state, listen_on_session))
    connection.ConnectFailed(error), Some(starter) -> {
      process.send(starter, Error(error))
      connection.stop(state.connection)
      actor.stop()
    }
    connection.ConnectFailed(_error), None | ReconnectFailed(_error), _ ->
      actor.continue(state)
    Disconnected(_error), _ -> actor.continue(lost(state))
  }
}

/// Only the subscribers that listen get `NotListening`: one that came
/// while the connection was not up got it already.
fn lost(state: State) -> State {
  dict.values(state.subscriptions)
  |> filter(is_listening)
  |> each(tell_lost)
  State(
    ..state,
    subscriptions: dict.map_values(state.subscriptions, not_listening),
  )
}

fn tell_lost(subscriber: Subscriber) -> Nil {
  process.send(subscriber.subject, NotListening)
}

fn not_listening(_monitor: Monitor, subscriber: Subscriber) -> Subscriber {
  Subscriber(..subscriber, listening: False)
}

fn listen_on_session(state: State, channel: String) -> State {
  let listened = listen(state, channel)
  case listen_message(channel, listened) {
    Some(message) ->
      subscribers_of(state, channel) |> each(process.send(_, message))
    None -> Nil
  }
  let listening = listened == ListenWorked
  State(
    ..state,
    subscriptions: dict.map_values(
      state.subscriptions,
      fn(_monitor, subscriber) {
        listening_after(subscriber, channel, listening)
      },
    ),
  )
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

fn channels(state: State) -> List(String) {
  dict.values(state.subscriptions) |> list.map(channel_of) |> unique
}

fn channel_of(subscriber: Subscriber) -> String {
  subscriber.channel
}

fn has_subscribers(state: State, channel: String) -> Bool {
  subscribers_on(state, channel) != []
}

fn subscribers_of(
  state: State,
  channel: String,
) -> List(Subject(ListenerMessage)) {
  subscribers_on(state, channel) |> list.map(subject_of)
}

fn subject_of(subscriber: Subscriber) -> Subject(ListenerMessage) {
  subscriber.subject
}

fn subscribers_on(state: State, channel: String) -> List(Subscriber) {
  dict.values(state.subscriptions) |> filter(on_channel(_, channel))
}

fn on_channel(subscriber: Subscriber, channel: String) -> Bool {
  subscriber.channel == channel
}
