//// Connecting guide: say what is wrong with a URL
////
//// Turns each `UrlError` into a message that tells the operator what to fix.

import dream_postgres/client as postgres
import gleam/int

pub fn explain(error: postgres.UrlError) -> String {
  case error {
    postgres.MalformedUrl ->
      "DATABASE_URL is not a URL. Percent-encode @, :, / and # in the password."
    postgres.MissingScheme ->
      "DATABASE_URL must start with postgresql:// or postgres://"
    postgres.UnsupportedScheme(scheme) ->
      "DATABASE_URL has the scheme " <> scheme <> ", not postgresql"
    postgres.MissingHost -> "DATABASE_URL has no host"
    postgres.InvalidPort(port) ->
      "DATABASE_URL has the port " <> int.to_string(port) <> ", not 1 to 65535"
    postgres.MissingDatabase -> "DATABASE_URL has no database name"
    postgres.InvalidDatabase(path) ->
      "DATABASE_URL has the path " <> path <> ", not one database name"
    postgres.MissingUser -> "DATABASE_URL has a password but no user"
    postgres.InvalidUserEncoding ->
      "The user in DATABASE_URL has a bad percent-encoding"
    postgres.InvalidPasswordEncoding ->
      "The password in DATABASE_URL has a bad percent-encoding"
    postgres.InvalidDatabaseEncoding ->
      "The database name in DATABASE_URL has a bad percent-encoding"
    postgres.UnsupportedParameter(name) ->
      "DATABASE_URL has the parameter " <> name <> ". Remove it."
    postgres.UnsupportedSslMode(mode) ->
      "DATABASE_URL has sslmode="
      <> mode
      <> ". Use disable, require or verify-full."
    postgres.UnsupportedFragment -> "DATABASE_URL has a # part. Remove it."
  }
}
