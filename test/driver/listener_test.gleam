//// Tests for `dream_postgres/driver/listener`, LISTEN and NOTIFY, on the
//// driver servers of PostgreSQL 16 to 19. A second connection controls
//// the server: it sends the notifications, ends the listener's backend,
//// and reads the listener's last statement from `pg_stat_activity`. Each
//// listener has its own application name and its own channels, so tests
//// that run at the same time do not meet, and no test sleeps.

import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type DriverError, Backoff,
  CacheStatements, ConnectionConfig, Notification, ServerEndedConnection,
  TransportRefused,
}
import dream_postgres/driver/listener.{
  type Listener, type ListenerConfig, type ListenerError, type ListenerMessage,
  type Subscription, ChannelTooLong, ConnectFailed, ListenFailed, ListenedAgain,
  ListenerConfig, ListenerProcessDown, ListenerTimedOut, NotificationArrived,
  SubscriberHasNoProcess,
}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/transport.{ConnectRefused, NoTls, TransportConfig}
import dream_postgres/internal/cell.{Text}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int.{to_string}
import gleam/list.{map}
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/result.{try}
import gleam/string.{repeat}

@external(erlang, "port_ffi", "free_port")
fn free_port() -> Int

/// Why a test could not do its steps.
type TestError {
  SetupFailed
  RequestFailed(error: DriverError)
  SubscribeFailed(error: ListenerError)
  NoMessage
  UnexpectedRows
}

/// The tests of the listener.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/listener", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("subscribing", subscribe_tests()),
    group("starting and stopping", start_tests()),
  ])
}

// Settings --------------------------------------------------------------------

fn first_server() -> Server {
  servers.Server(version: 16, port: 5441)
}

fn connection_config(
  port: Int,
  application_name: String,
  first_delay: Int,
) -> Result(ConnectionConfig, TestError) {
  use address <- try(
    transport.address("localhost", port) |> result.replace_error(SetupFailed),
  )
  use login_config <- try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password(servers.password),
      parameters: [#("application_name", application_name)],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.replace_error(SetupFailed),
  )
  Ok(ConnectionConfig(
    transport: TransportConfig(address, NoTls, 5000, 500),
    login: login_config,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(first_delay, 60_000),
    events: None,
    notifications: None,
    statements: CacheStatements(512),
  ))
}

fn listener_config(
  port: Int,
  application_name: String,
  first_delay: Int,
) -> Result(ListenerConfig, TestError) {
  use settings <- try(connection_config(port, application_name, first_delay))
  Ok(ListenerConfig(connection: settings, deadline_milliseconds: 5000))
}

/// A listener and the control connection of one test.
type Setup {
  Setup(listener: Listener, control: Connection, application_name: String)
}

/// Starts a listener with its own application name and a control
/// connection, gives them to `body`, and stops them.
fn with_setup(
  port: Int,
  application_name: String,
  first_delay: Int,
  body: fn(Setup) -> Result(value, TestError),
) -> Result(value, TestError) {
  use settings <- try(listener_config(port, application_name, first_delay))
  use control_settings <- try(connection_config(port, "svc827_control", 10))
  use started <- try(
    listener.start(settings) |> result.replace_error(SetupFailed),
  )
  use control <- try(
    connection.start(control_settings) |> result.replace_error(SetupFailed),
  )
  let value = body(Setup(started, control, application_name))
  connection.stop(control)
  listener.stop(started)
  value
}

fn subscribe(
  setup: Setup,
  channel: String,
  subscriber: Subject(ListenerMessage),
) -> Result(Subscription, TestError) {
  listener.subscribe(setup.listener, channel, subscriber, 5000)
  |> result.map_error(SubscribeFailed)
}

fn unsubscribe(
  setup: Setup,
  subscription: Subscription,
) -> Result(Nil, TestError) {
  listener.unsubscribe(setup.listener, subscription, 5000)
  |> result.map_error(SubscribeFailed)
}

/// Runs a statement on the control connection and gives its only text
/// cell.
fn control_text(setup: Setup, sql: String) -> Result(String, TestError) {
  use outcomes <- try(
    connection.run_script(setup.control, sql, 5000)
    |> result.map_error(RequestFailed),
  )
  case map(outcomes, rows) {
    [[[Text(bytes)]]] ->
      bit_array.to_string(bytes) |> result.replace_error(UnexpectedRows)
    _ -> Error(UnexpectedRows)
  }
}

fn rows(outcome: connection.Outcome) {
  outcome.result.rows
}

/// The backend process ID of the control connection.
fn control_pid(setup: Setup) -> Result(Int, TestError) {
  use text <- try(control_text(setup, "SELECT pg_backend_pid()::text"))
  int.parse(text) |> result.replace_error(UnexpectedRows)
}

/// Sends a notification from the control connection.
fn notify(
  setup: Setup,
  channel: String,
  payload: String,
) -> Result(Nil, TestError) {
  control_text(
    setup,
    "SELECT pg_notify("
      <> literal(channel)
      <> ", "
      <> literal(payload)
      <> ")::text",
  )
  |> result.replace(Nil)
}

fn literal(text: String) -> String {
  "'" <> string.replace(text, "'", "''") <> "'"
}

/// The last statement of the listener's backend.
fn listener_statement(setup: Setup) -> Result(String, TestError) {
  control_text(
    setup,
    "SELECT query FROM pg_stat_activity WHERE application_name = "
      <> literal(setup.application_name),
  )
}

/// Asks the control connection again and again, without a sleep, until the
/// listener's last statement is `expected`.
fn wait_for_statement(
  setup: Setup,
  expected: String,
  attempts: Int,
) -> Result(String, TestError) {
  use statement <- try(listener_statement(setup))
  case statement == expected, attempts {
    True, _ -> Ok(statement)
    False, 0 -> Ok(statement)
    False, _ -> wait_for_statement(setup, expected, attempts - 1)
  }
}

/// Ends the listener's backend from the control connection, and waits
/// until the server has no backend of the listener left.
fn end_listener_backend(setup: Setup) -> Result(Nil, TestError) {
  use _ended <- try(control_text(
    setup,
    "SELECT bool_and(pg_terminate_backend(pid))::text FROM pg_stat_activity"
      <> " WHERE application_name = "
      <> literal(setup.application_name),
  ))
  wait_for_no_backend(setup, 1000)
}

fn wait_for_no_backend(setup: Setup, attempts: Int) -> Result(Nil, TestError) {
  use count <- try(control_text(
    setup,
    "SELECT count(*)::text FROM pg_stat_activity WHERE application_name = "
      <> literal(setup.application_name),
  ))
  case count, attempts {
    "0", _ -> Ok(Nil)
    _, 0 -> Error(UnexpectedRows)
    _, _ -> wait_for_no_backend(setup, attempts - 1)
  }
}

fn next_message(
  subscriber: Subject(ListenerMessage),
) -> Result(ListenerMessage, TestError) {
  process.receive(subscriber, 5000) |> result.replace_error(NoMessage)
}

fn name_for(test_name: String, server: Server) -> String {
  "svc827_" <> test_name <> "_" <> to_string(server.version)
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it("gives a notification with the channel, payload and sender", fn() {
      check_notification(server)
    }),
    it("keeps a channel name exact, with capitals and quotes", fn() {
      check_exact_channel(server)
    }),
    it("sends UNLISTEN when the last subscriber unsubscribes", fn() {
      check_unlisten(server)
    }),
    it("keeps listening while another subscriber remains", fn() {
      check_other_subscriber_remains(server)
    }),
    it("removes a subscriber whose process stopped", fn() {
      check_subscriber_down(server)
    }),
    it("listens again after a reconnect and says so", fn() {
      check_listened_again(server)
    }),
    it("gives notifications after a reconnect", fn() {
      check_notification_after_reconnect(server)
    }),
  ])
}

fn check_notification(server: Server) {
  // Arrange
  let channel = name_for("jobs", server)

  // Act
  let message = {
    use setup <- with_setup(server.port, name_for("notify", server), 10)
    let subscriber = process.new_subject()
    use _subscription <- try(subscribe(setup, channel, subscriber))
    use pid <- try(control_pid(setup))
    use Nil <- try(notify(setup, channel, "hello"))
    use message <- try(next_message(subscriber))
    Ok(#(message, pid))
  }

  // Assert
  message
  |> result.map(sent_by_control(_, channel, "hello"))
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected the notification of the control connection")
}

fn sent_by_control(
  received: #(ListenerMessage, Int),
  channel: String,
  payload: String,
) -> Bool {
  let #(message, pid) = received
  message == NotificationArrived(Notification(pid, channel, payload))
}

fn check_exact_channel(server: Server) {
  // Arrange
  let channel = "Svc827 \"Quoted\" " <> to_string(server.version)

  // Act
  let message = {
    use setup <- with_setup(server.port, name_for("exact", server), 10)
    let subscriber = process.new_subject()
    use _subscription <- try(subscribe(setup, channel, subscriber))
    use Nil <- try(notify(setup, channel, "it's exact"))
    next_message(subscriber) |> result.map(payload_on_channel)
  }

  // Assert
  message
  |> should
  |> be_equal(Ok(#(channel, "it's exact")))
  |> or_fail_with("Expected the notification on the exact channel")
}

fn payload_on_channel(message: ListenerMessage) -> #(String, String) {
  case message {
    NotificationArrived(notification) -> #(
      notification.channel,
      notification.payload,
    )
    ListenedAgain(channel, _result) -> #(channel, "listened again")
  }
}

fn check_unlisten(server: Server) {
  // Arrange
  let channel = name_for("unlisten", server)

  // Act
  let statement = {
    use setup <- with_setup(server.port, name_for("unlisten", server), 10)
    use subscription <- try(subscribe(setup, channel, process.new_subject()))
    use Nil <- try(unsubscribe(setup, subscription))
    listener_statement(setup)
  }

  // Assert
  statement
  |> should
  |> be_equal(Ok("UNLISTEN \"" <> channel <> "\""))
  |> or_fail_with("Expected UNLISTEN as the last statement")
}

fn check_other_subscriber_remains(server: Server) {
  // Arrange
  let channel = name_for("shared", server)

  // Act
  let messages = {
    use setup <- with_setup(server.port, name_for("shared", server), 10)
    let first = process.new_subject()
    let second = process.new_subject()
    use subscription <- try(subscribe(setup, channel, first))
    use _other <- try(subscribe(setup, channel, second))
    use Nil <- try(unsubscribe(setup, subscription))
    use Nil <- try(notify(setup, channel, "still here"))
    use message <- try(next_message(second))
    Ok(#(payload_on_channel(message), process.receive(first, 0)))
  }

  // Assert
  messages
  |> should
  |> be_equal(Ok(#(#(channel, "still here"), Error(Nil))))
  |> or_fail_with("Expected the notification for the second subscriber only")
}

fn check_subscriber_down(server: Server) {
  // Arrange
  let channel = name_for("down", server)

  // Act
  let statement = {
    use setup <- with_setup(server.port, name_for("down", server), 10)
    let answers = process.new_subject()
    process.spawn(fn() { subscribe_and_stop(setup, channel, answers) })
    use _subscribed <- try(
      process.receive(answers, 5000)
      |> result.replace_error(NoMessage)
      |> result.flatten,
    )
    wait_for_statement(setup, "UNLISTEN \"" <> channel <> "\"", 1000)
  }

  // Assert
  statement
  |> should
  |> be_equal(Ok("UNLISTEN \"" <> channel <> "\""))
  |> or_fail_with("Expected UNLISTEN after the subscriber stopped")
}

/// Subscribes its own subject, tells the test, and stops.
fn subscribe_and_stop(
  setup: Setup,
  channel: String,
  answers: Subject(Result(Subscription, TestError)),
) -> Nil {
  process.send(answers, subscribe(setup, channel, process.new_subject()))
}

fn check_listened_again(server: Server) {
  // Arrange
  let channel = name_for("again", server)

  // Act
  let message = {
    use setup <- with_setup(server.port, name_for("again", server), 10)
    let subscriber = process.new_subject()
    use _subscription <- try(subscribe(setup, channel, subscriber))
    use Nil <- try(end_listener_backend(setup))
    next_message(subscriber)
  }

  // Assert
  message
  |> should
  |> be_equal(Ok(ListenedAgain(channel, Ok(Nil))))
  |> or_fail_with("Expected ListenedAgain after the reconnect")
}

fn check_notification_after_reconnect(server: Server) {
  // Arrange
  let channel = name_for("after", server)

  // Act
  let message = {
    use setup <- with_setup(server.port, name_for("after", server), 10)
    let subscriber = process.new_subject()
    use _subscription <- try(subscribe(setup, channel, subscriber))
    use Nil <- try(end_listener_backend(setup))
    use _again <- try(next_message(subscriber))
    use Nil <- try(notify(setup, channel, "back"))
    next_message(subscriber) |> result.map(payload_on_channel)
  }

  // Assert
  message
  |> should
  |> be_equal(Ok(#(channel, "back")))
  |> or_fail_with("Expected the notification on the new session")
}

// Subscribing -----------------------------------------------------------------

fn subscribe_tests() {
  [
    it("gives a notification only to the subscribers of its channel", fn() {
      // Act
      let messages = {
        use setup <- with_setup(first_server().port, "svc827_routing", 10)
        let first = process.new_subject()
        let second = process.new_subject()
        use _first <- try(subscribe(setup, "svc827_routing_one", first))
        use _second <- try(subscribe(setup, "svc827_routing_two", second))
        use Nil <- try(notify(setup, "svc827_routing_one", "one"))
        use message <- try(next_message(first))
        Ok(#(payload_on_channel(message), process.receive(second, 0)))
      }

      // Assert
      messages
      |> should
      |> be_equal(Ok(#(#("svc827_routing_one", "one"), Error(Nil))))
      |> or_fail_with("Expected the notification on the first channel only")
    }),
    it("refuses a channel name of more than 63 bytes", fn() {
      // Arrange
      let channel = repeat("a", 64)

      // Act
      let answer = {
        use setup <- with_setup(first_server().port, "svc827_long", 10)
        Ok(listener.subscribe(
          setup.listener,
          channel,
          process.new_subject(),
          5000,
        ))
      }

      // Assert
      answer
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(ChannelTooLong(channel))))
      |> or_fail_with("Expected ChannelTooLong")
    }),
    it("takes a channel name of 63 bytes", fn() {
      // Arrange
      let channel = "svc827_" <> repeat("b", 56)

      // Act
      let message = {
        use setup <- with_setup(first_server().port, "svc827_longest", 10)
        let subscriber = process.new_subject()
        use _subscription <- try(subscribe(setup, channel, subscriber))
        use Nil <- try(notify(setup, channel, "fits"))
        next_message(subscriber) |> result.map(payload_on_channel)
      }

      // Assert
      message
      |> should
      |> be_equal(Ok(#(channel, "fits")))
      |> or_fail_with("Expected the notification on the longest channel")
    }),
    it("refuses a named subject that no process has", fn() {
      // Arrange
      let subscriber = process.named_subject(process.new_name("svc827"))

      // Act
      let answer = {
        use setup <- with_setup(first_server().port, "svc827_named", 10)
        Ok(listener.subscribe(setup.listener, "svc827_named", subscriber, 5000))
      }

      // Assert
      answer
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(SubscriberHasNoProcess)))
      |> or_fail_with("Expected SubscriberHasNoProcess")
    }),
    it("gives the error of a LISTEN while the connection is lost", fn() {
      // Act
      let answer = {
        use setup <- with_setup(first_server().port, "svc827_lost", 60_000)
        use Nil <- try(end_listener_backend(setup))
        Ok(
          listener.subscribe(
            setup.listener,
            "svc827_lost",
            process.new_subject(),
            5000,
          )
          |> result.map_error(failure_code),
        )
      }

      // Assert
      answer
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error("57P01")))
      |> or_fail_with("Expected the 57P01 of the loss")
    }),
    it("ends a subscription that ended already without an error", fn() {
      // Act
      let answer = {
        use setup <- with_setup(first_server().port, "svc827_twice", 10)
        use subscription <- try(subscribe(
          setup,
          "svc827_twice",
          process.new_subject(),
        ))
        use Nil <- try(unsubscribe(setup, subscription))
        unsubscribe(setup, subscription)
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok for the second unsubscribe")
    }),
    it("gives ListenerTimedOut when the listener does not answer in time", fn() {
      // Act
      let answer = {
        use setup <- with_setup(first_server().port, "svc827_timeout", 10)
        Ok(
          listener.subscribe(
            setup.listener,
            "svc827_timeout",
            process.new_subject(),
            0,
          )
          |> result.replace(Nil),
        )
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(ListenerTimedOut)))
      |> or_fail_with("Expected ListenerTimedOut")
    }),
  ]
}

fn failure_code(error: ListenerError) -> String {
  case error {
    ListenFailed(ServerEndedConnection(report)) -> report.code
    _ -> "not a loss"
  }
}

// Starting and stopping -------------------------------------------------------

fn start_tests() {
  [
    it("gives ConnectFailed for a port with no server", fn() {
      // Arrange
      let settings = listener_config(free_port(), "svc827_refused", 10)

      // Act
      let started = settings |> result.map(listener.start)

      // Assert
      started
      |> result.map(result.replace(_, Nil))
      |> should
      |> be_equal(Ok(Error(ConnectFailed(TransportRefused(ConnectRefused)))))
      |> or_fail_with("Expected ConnectFailed")
    }),
    it("gives ListenerProcessDown to a subscribe after the stop", fn() {
      // Act
      let answers = {
        use settings <- try(listener_config(
          first_server().port,
          "svc827_stopped",
          10,
        ))
        use started <- try(
          listener.start(settings) |> result.replace_error(SetupFailed),
        )
        let subscriber = process.new_subject()
        use subscription <- try(
          listener.subscribe(started, "svc827_stopped", subscriber, 5000)
          |> result.map_error(SubscribeFailed),
        )
        listener.stop(started)
        Ok(#(
          listener.subscribe(started, "svc827_stopped", subscriber, 5000)
            |> result.replace(Nil),
          listener.unsubscribe(started, subscription, 5000),
        ))
      }

      // Assert
      answers
      |> should
      |> be_equal(Ok(#(Error(ListenerProcessDown), Error(ListenerProcessDown))))
      |> or_fail_with("Expected ListenerProcessDown")
    }),
    it("starts under a supervisor", fn() {
      // Act
      let started = {
        use settings <- try(listener_config(
          first_server().port,
          "svc827_supervised",
          10,
        ))
        start_supervised(settings)
      }

      // Assert
      started
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the supervisor to start the listener")
    }),
  ]
}

/// Starts a supervisor with a listener, then stops the supervisor, which
/// stops the listener.
fn start_supervised(settings: ListenerConfig) -> Result(Nil, TestError) {
  use supervisor <- try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(listener.supervised(settings))
    |> static_supervisor.start
    |> result.replace_error(SetupFailed),
  )
  process.send_exit(supervisor.pid)
  Ok(Nil)
}
