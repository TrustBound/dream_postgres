import dream_postgres/codec.{text}
import dream_postgres/config.{type Config, intercept, secret_column, secret_text}
import snippets/request_tagging.{tag_with_app_name}

/// The config of the app, shared by the app and its tests. `config` points
/// at the server of each run.
pub fn app_config(config: Config) -> Config {
  config
  |> intercept(tag_with_app_name)
  |> secret_text("sk_live_", with: "sk_test_")
  |> secret_column("token", text, with: "token-redacted")
}
