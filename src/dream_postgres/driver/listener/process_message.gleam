//// The values that pass between a listener, its registry and its session:
//// the settings, the messages of the two actors, what a subscriber gets,
//// and the calls from one process to the other.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/cell.{type ServerReport, type TransactionStatus}
import dream_postgres/driver/connection/event.{
  type ConnectError, type ConnectionEvent,
}
import dream_postgres/driver/connection/outcome.{type Notification}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/sink.{type Sink}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}

/// Everything a listener needs.
pub type ListenerConfig {
  ListenerConfig(
    /// The connection of the listener. The session sets its `events` and
    /// its `notifications` to sinks of its own subjects, and its `notices`
    /// to `None`.
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
  /// connection is not up yet, it is lost, or the session stopped.
  /// `Listening` or `ListenFailed` follows once the session sent `LISTEN`
  /// on a connection that is up.
  NotListening
  /// The session sent `LISTEN` for the channel on a connection that is
  /// up: the first one, or a new one after a loss or a new session.
  /// Notifications on the channel between the last `NotListening` and this
  /// message may be missed.
  Listening(channel: String)
  /// The `LISTEN` for the channel failed on a connection that is up, so
  /// the session does not listen on it. The registry asks again after the
  /// next reconnect. A `LISTEN` that meets a loss gives no message: the
  /// subscriber got `NotListening` already, and `Listening` follows the
  /// next reconnect.
  ListenFailed(channel: String, error: ListenFailure)
}

/// Why the `LISTEN` for a channel failed on a connection that is up.
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
  /// The connection process of the session is gone, for example because
  /// an exit signal stopped it.
  ListenerConnectionDown
}

/// Why a subscribe failed.
pub type ListenerError {
  /// The channel name has more than 63 bytes. PostgreSQL cuts such a name
  /// short, so its notifications would come with another name.
  ChannelTooLong(channel: String)
  /// The subject of the subscriber's sink has no process: it has a name
  /// that no process has.
  SubscriberHasNoProcess
  /// The `LISTEN` failed on a connection that is up, so the subscription
  /// is not kept. A connection that is not up is not a failure: the
  /// subscription is kept and gets `NotListening`.
  SubscribeFailed(error: ListenFailure)
  /// The registry of the listener is gone.
  ListenerProcessDown
}

/// One subscription to one channel. `unsubscribe` ends it.
pub type Subscription {
  Subscription(monitor: Monitor)
}

/// A reply target: an alias of the caller (see the FFI module).
pub type ReplyTo(reply)

/// What the registry of a listener receives: the calls of this module, and
/// the reports of its session. A program names a supervised listener with
/// `process.new_name`, for this type.
pub type ListenerProcessMessage {
  SubscribeRequest(
    channel: String,
    subscriber: Sink(ListenerMessage),
    owner: Pid,
    reply: ReplyTo(Result(Subscription, ListenerError)),
  )
  UnsubscribeRequest(subscription: Subscription, reply: ReplyTo(Nil))
  StopRequest(reply: ReplyTo(Nil))
  /// A session started. The registry monitors it, and asks it from now on.
  SessionStarted(session: Subject(SessionMessage), pid: Pid)
  /// The connection of the session connected, the first time or again.
  SessionUp
  /// The connection of the session lost its session.
  SessionLost
  /// An attempt of the connection to connect for the first time failed.
  SessionConnectFailed(error: ConnectError)
  /// A notification that the connection of the session got.
  NotificationReceived(notification: Notification)
  /// A process that the registry monitors stopped: a subscriber's or the
  /// session.
  MonitoredProcessDown(monitor: Monitor)
}

/// What the session of a listener receives: the requests of its registry,
/// and what its connection process sends.
pub type SessionMessage {
  ListenRequest(channel: String, reply: ReplyTo(Listened))
  UnlistenRequest(channel: String, reply: ReplyTo(Nil))
  /// Closes the connection, and stops the session.
  CloseRequest(reply: ReplyTo(Nil))
  ConnectionNotified(notification: Notification)
  ConnectionChanged(event: ConnectionEvent)
}

/// What a `LISTEN` gave.
pub type Listened {
  /// The session listens on the channel.
  ListenWorked
  /// The connection is not up: it is lost, a supervised connection did not
  /// connect yet, or the session is gone. The registry asks again after the
  /// next reconnect or the next session.
  ListenLost
  /// The `LISTEN` failed on a connection that is up.
  ListenNotDone(failure: ListenFailure)
}

@external(erlang, "dream_postgres_listener_ffi", "call")
pub fn call_process(
  pid: Pid,
  send_request: fn(ReplyTo(reply)) -> Nil,
) -> Result(reply, Nil)

@external(erlang, "dream_postgres_listener_ffi", "reply")
pub fn reply(to: ReplyTo(reply), value: reply) -> Nil

/// Sends a message to the registry's process ID, tagged for its selector.
/// A send to a process that is gone does nothing.
@external(erlang, "dream_postgres_listener_ffi", "deliver")
pub fn send_to_registry(registry: Pid, message: ListenerProcessMessage) -> Nil

/// The message inside a message of `send_to_registry`.
@external(erlang, "dream_postgres_listener_ffi", "request_of")
pub fn request_of(message: Dynamic) -> ListenerProcessMessage
