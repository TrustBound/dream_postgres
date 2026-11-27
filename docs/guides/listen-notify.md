# Listen for notifications

PostgreSQL sends a notification to each session that listens on its channel, when a statement runs `NOTIFY channel, 'payload'` or `pg_notify`. This guide shows how to listen with dream_postgres, which messages a subscriber gets and in which order, and how to run a listener under a supervisor. Each code block is a file that the tests of this package run against PostgreSQL.

## Table of Contents

- [How a listener works](#how-a-listener-works)
- [Start a listener and listen](#start-a-listener-and-listen)
- [The four messages](#the-four-messages)
- [The order of the messages](#the-order-of-the-messages)
- [End a subscription](#end-a-subscription)
- [Run a listener under a supervisor](#run-a-listener-under-a-supervisor)
- [Know when the subscriptions end](#know-when-the-subscriptions-end)
- [Where to go next](#where-to-go-next)

## How a listener works

A listener has one connection of its own, outside the pool. A subscription connects one subject to one channel. The first subscription of a channel makes the listener send `LISTEN`. When the last subscription of a channel ends, the listener sends `UNLISTEN`. A subscription ends with `unlisten`, or when the process of its subject ends.

A listener is two processes:

- The registry keeps the subscriptions. Each call of a listener goes to it.
- The session owns the connection. It sends each `LISTEN` and `UNLISTEN` that the registry asks for, and gives each notification to the registry.

The registry sends each notification to each subscriber of its channel, in the order that the server sent them.

The channel name is exact: `Jobs` and `jobs` are two channels.

## Start a listener and listen

`start_listener` takes a config, as `start` does. It uses the server, the login and the TLS of the config. The pool settings of the config do not apply. It waits until its connection is up, so a server that does not answer gives an error. Each `LISTEN` can take the query timeout of the config.

### Start a listener and listen on a channel <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_for_jobs.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres.{
  type Config, type ListenMessage, type Listener, type PostgresError,
  type Subscription, listen, start_listener,
}
import gleam/erlang/process.{type Subject}
import gleam/result

/// Starts a listener and subscribes the subject to the channel `jobs`.
pub fn listen_for_jobs(
  config: Config,
  jobs: Subject(ListenMessage),
) -> Result(#(Listener, Subscription), Error(PostgresError)) {
  use listener <- result.try(start_listener(config))
  use subscription <- result.try(listen(listener, "jobs", jobs))
  Ok(#(listener, subscription))
}
```

`listen` gives a `Subscription`. It fails with `ChannelTooLong` for a channel name of more than 63 bytes, because PostgreSQL cuts such a name short. It fails with `SubscriberHasNoProcess` for a subject that has no process. In both cases nothing goes to the server.

A notification comes to the subject as a `ListenMessage`. This function waits for the next notification, and skips the messages about the listening state:

### Wait for the next notification <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/next_job.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres.{
  type ListenMessage, ListenFailed, Listening, NotListening, NotificationArrived,
}
import gleam/erlang/process.{type Subject}

/// The payload of the next notification, or `Error(Nil)` when none came
/// within 5 seconds. It skips the messages about the listening state.
pub fn next_job(jobs: Subject(ListenMessage)) -> Result(String, Nil) {
  case process.receive(jobs, 5000) {
    Ok(NotificationArrived(payload:, ..)) -> Ok(payload)
    Ok(NotListening) | Ok(Listening(..)) | Ok(ListenFailed(..)) ->
      next_job(jobs)
    Error(Nil) -> Error(Nil)
  }
}
```

The test of these functions sends `NOTIFY jobs, 'build-42'` through the pool, and `next_job` gives `Ok("build-42")`.

## The four messages

| Message | What it means |
|---|---|
| `NotificationArrived(channel, payload, process_id)` | A notification on the channel. `process_id` is the server process that sent it. |
| `NotListening` | The session does not listen on the channel: the connection is not up yet, or it is lost. A notification that comes before `Listening` can be lost. |
| `Listening(channel)` | The session listens on the channel again, after `NotListening`. |
| `ListenFailed(channel, error)` | The `LISTEN` for the channel failed after a reconnect. The listener tries again after the next reconnect. |

## The order of the messages

The rule is exact. The session is up from the moment that the registry gets the session's report that its connection logged in, until the registry gets a loss or the end of that session.

- When the registry handles a subscribe while the session is up, it sends `LISTEN` for the first subscriber of the channel. `listen` returns once the session listens. The subscriber gets no message for it.
- When the registry handles a subscribe while the session is not up, it sends nothing. The subscriber gets `NotListening` at once, then `Listening` or `ListenFailed` after the next login.
- A `LISTEN` that meets a loss that the registry did not handle yet gives `NotListening` in the same way.

So a subscriber gets `NotListening` first if and only if the session is not up when the registry handles its subscribe. A listener from `start_listener` returns once its session is up, so a subscribe to it gets no message, unless the connection is lost in between.

When the connection is lost, each subscriber gets `NotListening` at once, and the listener connects again. The new session listens on nothing, so the listener sends `LISTEN` again for each channel. Then each subscriber gets `Listening`, or `ListenFailed` when that `LISTEN` failed. The server keeps no notification for a session that is gone, so the notifications between `NotListening` and `Listening` can be missed. When your app must see every event, keep the events in a table too, and read the table after `Listening`.

## End a subscription

`unlisten` ends one subscription. `stop_listener` stops the listener and its connection. Its subscribers get no message.

### End a subscription and stop the listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/stop_listening.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres.{
  type Listener, type PostgresError, type Subscription, stop_listener, unlisten,
}
import gleam/result

/// Ends the subscription, then stops the listener.
pub fn stop_listening(
  listener: Listener,
  subscription: Subscription,
) -> Result(Nil, Error(PostgresError)) {
  use Nil <- result.try(unlisten(listener, subscription))
  stop_listener(listener)
  Ok(Nil)
}
```

## Run a listener under a supervisor

`supervised_listener` gives the child specification of a listener under a name. Make the name one time when the program starts, with `process.new_name`: each name is an atom.

### Start a listener under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_listener_supervisor.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres.{type Config, type ListenerName, supervised_listener}
import dream_postgres/error.{describe}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result

/// Starts the app's supervisor with a listener under the name
/// `notifications`.
pub fn start_listener_supervisor(
  config: Config,
  notifications: ListenerName,
) -> Result(actor.Started(Supervisor), String) {
  use listener_child <- result.try(
    supervised_listener(config, name: notifications)
    |> result.map_error(describe),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(listener_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}
```

The start does not wait for the server. Until the connection is up, each subscriber gets `NotListening`. The config is checked when `supervised_listener` runs, so a wrong config is an error before the supervisor starts.

`named_listener` gives the listener that runs under the name. It holds only the name, so it stays valid when the supervisor starts the listener again. While no listener runs under the name, `listen` and `unlisten` fail with `ListenerStopped`.

### Listen through the name of a listener <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/listen_by_name.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres.{
  type ListenMessage, type ListenerName, type PostgresError, type Subscription,
  listen, named_listener,
}
import gleam/erlang/process.{type Subject}

/// Subscribes the subject to `jobs` on the listener that runs under the
/// name, as a supervisor starts it.
pub fn listen_by_name(
  notifications: ListenerName,
  jobs: Subject(ListenMessage),
) -> Result(Subscription, Error(PostgresError)) {
  listen(named_listener(notifications), "jobs", jobs)
}
```

Under a supervisor, the registry and the session are the two children of a small supervisor with the strategy `rest_for_one`:

- When the session crashes, the subscriptions stay. Each subscriber that listened gets `NotListening`. The supervisor starts a new session, and each subscriber gets `Listening` or `ListenFailed`, with no new `listen`.
- When the registry crashes, every subscription ends. The supervisor starts the registry and the session again, with no subscriber.

`stop_listener` stops a supervised listener for good.

A listener from `start_listener` has no supervisor. Its registry is linked to the caller, and its session is linked to the registry. A crash of its session stops the registry too.

## Know when the subscriptions end

The end of the registry ends every subscription, with no message to the subscribers. `monitor_listener` gives a monitor of the registry, owned by the calling process. The caller gets the `Down` of the monitor when the registry ends, by a crash or by `stop_listener`. A crash of the session alone gives no `Down`, because the subscriptions stay.

This selector gives the messages of the subject and the end of the registry:

### Watch for the end of the registry <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/job_events.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres.{
  type ListenMessage, type ListenerName, type PostgresError, monitor_listener,
  named_listener,
}
import gleam/erlang/process.{type Down, type Selector, type Subject}
import gleam/result

pub type JobEvent {
  JobMessage(message: ListenMessage)
  /// The registry of the listener ended, and every subscription with it.
  ListenerEnded(down: Down)
}

/// A selector of the messages of `jobs` and of the end of the listener's
/// registry.
pub fn job_events(
  notifications: ListenerName,
  jobs: Subject(ListenMessage),
) -> Result(Selector(JobEvent), Error(PostgresError)) {
  use monitor <- result.try(monitor_listener(named_listener(notifications)))
  process.new_selector()
  |> process.select_map(jobs, JobMessage)
  |> process.select_specific_monitor(monitor, ListenerEnded)
  |> Ok
}
```

After a `ListenerEnded`, a supervised listener comes back with no subscription. Call `listen` again through `named_listener`, and call `monitor_listener` again. `monitor_listener` fails with `ListenerStopped` when no listener runs.

The test of this selector stops the listener with `stop_listener`, and the selector gives `ListenerEnded`.

## Where to go next

- [Connecting](connecting.md): the config that a listener shares with a pool
- [Tracing](tracing.md): a listener's `LISTEN` and `UNLISTEN` make no span
