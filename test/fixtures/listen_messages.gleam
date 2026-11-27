//// Waits for the messages of a subscription and for the end of a
//// listener, for the listener tests.

import gleam/erlang/process.{type Down, type Monitor, type Subject}
import gleam/int
import gleam/list

/// The next `count` messages of the subject, in order, each within
/// `milliseconds`.
///
/// ## Example
///
/// ```gleam
/// listen_messages.receive_messages(messages, count: 2, within: 5000)
/// // -> Ok([NotListening, Listening("jobs")])
/// ```
pub fn receive_messages(
  subject: Subject(message),
  count count: Int,
  within milliseconds: Int,
) -> Result(List(message), String) {
  list.repeat(Nil, count)
  |> list.try_map(fn(_position) {
    process.receive(subject, milliseconds)
    |> result_or_timeout(milliseconds)
  })
}

fn result_or_timeout(
  received: Result(message, Nil),
  milliseconds: Int,
) -> Result(message, String) {
  case received {
    Ok(message) -> Ok(message)
    Error(Nil) ->
      Error("no message within " <> int.to_string(milliseconds) <> " ms")
  }
}

/// Waits for the `Down` of the monitor, at most `milliseconds`.
///
/// ## Example
///
/// ```gleam
/// listen_messages.wait_for_down(monitor, within: 5000)
/// // -> Ok(Nil)
/// ```
pub fn wait_for_down(
  monitor: Monitor,
  within milliseconds: Int,
) -> Result(Nil, String) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, ended)
  |> process.selector_receive(milliseconds)
  |> result_or_timeout(milliseconds)
}

fn ended(_down: Down) -> Nil {
  Nil
}
