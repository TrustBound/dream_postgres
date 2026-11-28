import dream_postgres/codec.{text}
import dream_postgres/config.{type Config, intercept, secrets}
import dream_postgres/secrets
import snippets/request_tagging.{tag_with_app_name}

/// The config of the app, shared by the app and its tests. `server` holds
/// the settings of the server of each run.
pub fn app_config(server: Config) -> Config {
  server
  |> intercept(tag_with_app_name)
  |> secrets(
    secrets.new()
    |> secrets.text("sk_live_", with: "sk_test_")
    |> secrets.column("token", text, with: "token-redacted"),
  )
}
