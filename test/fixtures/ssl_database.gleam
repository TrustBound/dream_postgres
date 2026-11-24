//// The PostgreSQL server with SSL on, for the tests of the SSL modes.
////
//// `make db-up` starts it with the `postgres-ssl` service of
//// `docker-compose.yml`, on port 5437. Its certificate is
//// `test/fixtures/ssl/server.crt`: the test CA of that folder signed it, and
//// its only name is `localhost`. So a URL with the host `localhost` matches
//// the certificate, and a URL with `127.0.0.1` does not. The operating
//// system does not trust the test CA.

import dream_postgres/client as postgres
import dream_postgres_client
import fixtures/test_database
import gleam/int
import gleam/result
import gleam/string

/// The port of the SSL server on this machine.
pub const port = 5437

/// The PEM file with the certificate of the test CA.
pub const ca_file = "test/fixtures/ssl/ca.crt"

/// The host name that the server certificate names.
pub const matching_host = "localhost"

/// An address of the server that the server certificate does not name.
pub const other_address = "127.0.0.1"

@external(erlang, "ssl_ffi", "capture_tls_alerts")
fn capture_tls_alerts_ffi(run: fn() -> a) -> #(a, List(#(String, String)))

/// Drops the TLS alert reports from the output of the test run. A pool
/// whose certificate check fails logs one report for each try of each
/// connection, about 19 in 2 seconds. `tls_alerts` still gets them.
@external(erlang, "ssl_ffi", "drop_tls_alert_reports")
pub fn drop_tls_alert_reports() -> Nil

/// Returns the URL of the SSL server for the host and the `sslmode`.
pub fn url(host host: String, sslmode sslmode: String) -> String {
  "postgresql://dream:dream@"
  <> host
  <> ":"
  <> int.to_string(port)
  <> "/dream_test?sslmode="
  <> sslmode
}

/// Calls `run` and returns each TLS alert report that OTP's `ssl`
/// application logged while `run` ran, as `#(level, text)`, oldest first.
pub fn tls_alerts(run: fn() -> a) -> List(#(String, String)) {
  capture_tls_alerts_ffi(run).1
}

/// Starts a pool from `url`, runs `sql` (a query that returns one text
/// column) and stops the pool.
pub fn query_texts(
  url: String,
  sql: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  postgres.FromUrlError,
) {
  use <- test_database.with_own_pools()
  postgres.from_url(url)
  |> result.map(test_database.texts(_, sql))
}

/// Returns `Ok(Ok(["true"]))` when the pool from `url` connects with TLS,
/// from the server's `pg_stat_ssl` view.
pub fn ssl_in_use(
  url: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  postgres.FromUrlError,
) {
  query_texts(
    url,
    "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
  )
}

/// Checks that the SSL server answers `SELECT 1` without TLS. Returns a
/// message for the developer when it does not.
pub fn check_reachable() -> Result(Nil, String) {
  let url = url(host: other_address, sslmode: "disable")
  case query_texts(url, "SELECT 'answered'") {
    Ok(Ok(_rows)) -> Ok(Nil)
    answer ->
      Error(
        "The SSL tests need the PostgreSQL server with SSL on, and none answered at "
        <> other_address
        <> ":"
        <> int.to_string(port)
        <> ": "
        <> string.inspect(answer)
        <> ".\nStart both test servers with `make db-up`.",
      )
  }
}
