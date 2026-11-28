import dream_postgres/config.{type Config}
import dream_postgres/error.{describe}
import dream_postgres/listener.{type ListenerName, supervised_listener}
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
