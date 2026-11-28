# Connecting to PostgreSQL

This guide shows each setting of a pool: the server and the login, TLS, a pool under a supervisor, reconnects, the statement cache for PgBouncer, notices and pool events. The [pool tuning guide](pool-tuning.md) covers the pool size and the times of the pool.

## Table of Contents

- [The config](#the-config)
- [Start and stop a pool](#start-and-stop-a-pool)
- [Connect with a URL](#connect-with-a-url)
- [TLS](#tls)
- [Run the pool under a supervisor](#run-the-pool-under-a-supervisor)
- [Reconnects](#reconnects)
- [PgBouncer and the statement cache](#pgbouncer-and-the-statement-cache)
- [Notices](#notices)
- [Pool events](#pool-events)

## The config

`default_config()` gives a config with these values. Each setting function takes a config and gives a new config with one value changed.

| Setting | Function | Default |
|---|---|---|
| Host name or IP address | `host` | `localhost` |
| Port | `port` | `5432` |
| Database | `database` | `postgres` |
| User | `user` | `postgres` |
| Password | `password` | no password |
| Number of connections | `pool_size` | 10 |
| Longest time of one query | `query_timeout` | 5000 ms |
| Longest wait for a free connection | `checkout_timeout` | 5000 ms |
| Longest time of each TCP connect, TLS answer and TLS handshake | `connect_timeout` | 5000 ms |
| Longest time of one setup: the TCP connect, TLS and the login together | `setup_timeout` | 10_000 ms |
| Longest time of a cancel after a query timeout | `cancel_timeout` | 2000 ms |
| Interval between health checks | `health_check_interval` | 30_000 ms |
| Longest time of the rollback when a call gives back a connection | `return_rollback_timeout` | 5000 ms |
| Reconnect delays | `reconnect_delays` | 100 ms, doubled up to 10 seconds |
| Reconnect strategy | `reconnect_strategy` | `full_jitter` |
| TLS | `tls` | `TlsRequired(check: CheckAuthorityAndHost(SystemAuthorities), direct: False)` |
| Statement cache | `statement_cache` | `CacheStatements(limit: 512)` |
| Subject for notices | `notices` | none |
| Subject for pool events | `pool_events` | none |
| Interceptors | `intercept` | none, see the [interceptors guide](interceptors.md) |
| Secrets | `secrets` | none, see the [recorded queries guide](recorded-queries.md) |
| Recorder | `record` | none, see the [recorded queries guide](recorded-queries.md) |

The login uses the method that the server asks for: SCRAM-SHA-256, MD5, a cleartext password, or no password. With TLS on, SCRAM uses channel binding when the server offers SCRAM-SHA-256-PLUS, as libpq does by default.

## Start and stop a pool

`start` checks the config and starts the pool, linked to the calling process:

### Start a pool <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{
  TlsOff, database, default_config, host, password, pool_size, port, tls, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

/// Starts a pool of 4 connections to the database `dream_test` on this
/// machine. The local test server has no certificate, so TLS is off.
pub fn connect(port_number: Int) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> port(port_number)
  |> database("dream_test")
  |> user("dream")
  |> password("dream")
  |> pool_size(4)
  |> tls(TlsOff)
  |> start
}
```

A wrong config, such as an empty host or a pool size below 1, is an `Invalid` error from `start`. The connections connect in the background, so a server that does not answer shows as the error of the first query. While no connection is connected and the last connect failed, a call gets that connect error at once. So a wrong password or a server that is down reaches the caller with no wait.

`stop` stops the pool and closes its connections. The calls that hold a connection get at most 5 seconds to finish.

## Connect with a URL

`config_from_url(url)` reads a `postgres://` or `postgresql://` URL as libpq reads it, and gives a config:

`postgresql://user:password@host:port/database?sslmode=verify-full`

- The user, the password, the host and the database are percent-decoded. Write `%40` for an `@` in the password.
- An IPv6 host goes in square brackets: `postgres://[2001:db8::1234]:5432/app`.
- A part that the URL does not give keeps the value of `default_config`. The database is the exception: with no database, the database is the user, as in libpq.
- The URL must name a host. With no host, libpq uses a Unix socket, and dream_postgres has no Unix socket connection.
- With no `sslmode`, the TLS is the TLS of `default_config`, which is the same as `verify-full`. libpq starts with `prefer`, which checks no certificate.

The other settings of the config keep their defaults. Change them with the setting functions after `config_from_url`:

### Start a pool from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/database_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{pool_size}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}
import dream_postgres/url.{config_from_url}
import gleam/result

/// Starts a pool of 4 connections from a database URL, such as
/// `postgresql://app:secret@db.example.com:5432/app?sslmode=verify-full`.
pub fn connect_with_url(
  database_url: String,
) -> Result(Connection, Error(PostgresError)) {
  use config <- result.try(config_from_url(database_url))
  config
  |> pool_size(4)
  |> start
}
```

The URL takes these query parameters of libpq:

| Parameter | Value | TLS of the config |
|---|---|---|
| `sslmode` | `disable` | `TlsOff` |
| `sslmode` | `prefer` | `TlsPreferred` |
| `sslmode` | `require` | `TlsRequired(check: NoCertificateCheck, direct: False)` |
| `sslmode` | `verify-ca` | `TlsRequired(check: CheckAuthority(SystemAuthorities), direct: False)` |
| `sslmode` | `verify-full` | `TlsRequired(check: CheckAuthorityAndHost(SystemAuthorities), direct: False)` |
| `sslrootcert` | a path | the authorities of the PEM file, in place of `SystemAuthorities`. With `require`, the certificate is checked against the file, as libpq does. |
| `sslrootcert` | `system` | `SystemAuthorities`. It needs `verify-full`, as in libpq. |
| `sslnegotiation` | `postgres` | no change |
| `sslnegotiation` | `direct` | `direct: True`. It needs `require`, `verify-ca` or `verify-full`, as in libpq. |

A URL that the client cannot use exactly gives an `Invalid` error with the reason `InvalidConfig(InvalidDatabaseUrl(fault))`. Nothing in the URL is silently ignored. No fault and no message holds the password.

| The URL | `UrlFault` |
|---|---|
| has no `://` | `MissingScheme` |
| has a scheme other than `postgres` or `postgresql` | `UnsupportedScheme` |
| names more than one host, such as `host1:5432,host2:5432` | `MultipleHosts` |
| has an IPv6 host with no closing bracket, or with text after the bracket that is not a port | `MalformedBracketedHost` |
| has no host, which libpq takes as the default Unix socket | `UnixSocketNotSupported` |
| has a host that is an absolute path, which libpq takes as a Unix socket directory | `UnixSocketHost` |
| has a port that is not a number in 1 to 65535 | `InvalidUrlPort` |
| has a `%` that is not followed by two hex digits, or that decodes to bytes that are not UTF-8 | `InvalidPercentEncoding`, with the part |
| has a query parameter with no `=` | `ParameterWithoutValue` |
| has any other query parameter, such as `connect_timeout` or `application_name` | `UnsupportedParameter` |
| gives a query parameter two times | `ParameterGivenTwice` |
| has an `sslmode` that libpq does not have | `UnknownSslMode` |
| has `sslmode=allow`, which the client does not have | `UnsupportedSslMode` |
| has an `sslnegotiation` other than `postgres` or `direct` | `UnknownSslNegotiation` |
| has `sslnegotiation=direct` with `disable` or `prefer` | `DirectNegotiationNeedsRequiredTls` |
| has an `sslrootcert` file with `disable` or `prefer` | `RootCertificateNeedsCertificateCheck` |
| has `sslrootcert=system` with a mode below `verify-full` | `SystemRootCertificateNeedsVerifyFull` |

## TLS

`tls` sets how each connection uses TLS. The `Tls` type has three values:

| Value | What it does |
|---|---|
| `TlsOff` | Plain TCP. Use it only on a network that nobody else can read. |
| `TlsPreferred` | TLS when the server has it, and plain TCP when the server refuses it. The certificate is not checked. |
| `TlsRequired(check:, direct:)` | TLS, or no connection. `check` says how to check the certificate. |

`check` is a `CertificateCheck`:

| Value | What it checks |
|---|---|
| `NoCertificateCheck` | Nothing. Only the traffic is encrypted. |
| `CheckAuthority(authorities)` | One of the authorities signed the certificate. |
| `CheckAuthorityAndHost(authorities)` | One of the authorities signed the certificate, and the certificate names the host of the config. |

The authorities are `SystemAuthorities` (the authorities of the operating system), `AuthorityFile(path)` (a PEM file), or `AuthorityCertificates(certificates)` (DER certificates as bit arrays).

With `direct: True`, the connection starts TLS at once and does not ask the server first. PostgreSQL 17 and later accept this.

These settings follow the `sslmode` and `sslnegotiation` settings of libpq:

| libpq | dream_postgres |
|---|---|
| `sslmode=disable` | `TlsOff` |
| `sslmode=prefer` | `TlsPreferred` |
| `sslmode=require` | `TlsRequired(check: NoCertificateCheck, direct: False)` |
| `sslmode=verify-ca` | `TlsRequired(check: CheckAuthority(..), direct: False)` |
| `sslmode=verify-full` | `TlsRequired(check: CheckAuthorityAndHost(..), direct: False)` |
| `sslnegotiation=direct` | `TlsRequired(.., direct: True)` |

The default is `TlsRequired(check: CheckAuthorityAndHost(SystemAuthorities), direct: False)`, the same as `verify-full`. A server with no TLS, or with a certificate that the system does not trust, gives no connection.

When your server has a certificate from your own authority, give the PEM file of that authority:

### Check the certificate against your own authority <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/verified_tls.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/config.{
  type Config, AuthorityFile, CheckAuthorityAndHost, TlsRequired, tls,
}

/// Requires TLS, and checks the certificate of the server: an authority of
/// the file must sign it, and it must name the host of the config.
pub fn verified_tls(config: Config, authority_file: String) -> Config {
  config
  |> tls(TlsRequired(
    check: CheckAuthorityAndHost(AuthorityFile(authority_file)),
    direct: False,
  ))
}
```

The test of this example connects to a test server with a certificate from a test authority. The other examples of the guides use `TlsOff`, because the local test server of most tests has no certificate.

## Run the pool under a supervisor

A pool that runs for the whole life of an app goes under the app's supervisor. `supervised` gives the child specification of the pool, under a name. `named_connection` gives a connection that holds only that name:

### Start the pool under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/supervised_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{text}
import dream_postgres/config.{type Config}
import dream_postgres/error.{type PostgresError, describe}
import dream_postgres/pool.{type PoolName, named_connection, supervised}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result

/// Starts the app's supervisor with the pool under it. The pool runs
/// under `pool_name`, also after a restart.
pub fn start_supervisor(
  config: Config,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  use pool_child <- result.try(
    supervised(config, name: pool_name)
    |> result.map_error(describe),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}

/// Any process can reach the pool by its name.
pub fn current_database(
  pool_name: PoolName,
) -> Result(String, Error(PostgresError)) {
  "SELECT current_database()"
  |> query
  |> one(single(text), named_connection(pool_name))
}
```

Make the name one time when the program starts, with `process.new_name("database")`. Each name is an atom, and the Erlang VM never frees an atom.

`supervised` checks the config, so a wrong config is an error before the supervisor starts. After a restart, the new pool runs under the same name, so a connection from `named_connection` keeps working. While no pool runs under the name, each call fails with `PoolStopped`, an `Unavailable` error.

A config with a recorder in `Playback` mode also works with `supervised`. The pool under the name then has no database: it starts no connection, and `named_connection` answers from the recording. The [recorded queries guide](recorded-queries.md#record-then-play-back) shows the recorder.

### Play back under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_app_supervisor.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/config.{type Config, record}
import dream_postgres/error.{describe}
import dream_postgres/pool.{type PoolName, supervised}
import dream_postgres/recorder.{type Recorder}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import snippets/app_config.{app_config}

/// Starts the app's supervisor with the pool of the app config under
/// `pool_name`. With a recorder in `Playback` mode, the pool has no
/// database, and `named_connection(pool_name)` answers from the recording.
pub fn start_app_supervisor(
  server: Config,
  test_recorder: Recorder,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  use pool_child <- result.try(
    app_config(server)
    |> record(test_recorder)
    |> supervised(name: pool_name)
    |> result.map_error(describe),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}
```

## Reconnects

When a connection loses its session, it connects again. Before each attempt it waits. The wait comes from the reconnect delays and the reconnect strategy:

- `reconnect_delays` sets the first delay and the longest delay. The delay doubles after each failed attempt, up to the longest delay. The default is 100 ms, up to 10 seconds.
- `reconnect_strategy` sets a function that gets a `ReconnectStep` and gives the wait in milliseconds. dream_postgres keeps the wait between 0 and the longest delay.

A `ReconnectStep` has three fields:

| Field | Meaning |
|---|---|
| `attempt` | The number of failed attempts so far, 0 for the first wait |
| `capped_delay_milliseconds` | The first delay, doubled for each failed attempt, up to the longest delay |
| `previous_wait_milliseconds` | The wait before the previous attempt, 0 for the first wait |

The default strategy, `full_jitter`, waits a random time from 0 to the capped delay. Connections that lost the server at the same moment then come back at different moments. This example waits longer, and uses no random part:

### Slower reconnects with no jitter <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/reconnect_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/config.{type Config, reconnect_delays, reconnect_strategy}
import dream_postgres/reconnect.{type ReconnectStep}

/// Waits 500 ms before the first reconnect, doubles the wait after each
/// failed attempt, and never waits longer than 30 seconds.
pub fn slow_reconnects(config: Config) -> Config {
  config
  |> reconnect_delays(
    first_delay_milliseconds: 500,
    longest_delay_milliseconds: 30_000,
  )
  |> reconnect_strategy(without_jitter)
}

/// Waits the whole capped delay of each step, with no random part.
pub fn without_jitter(step: ReconnectStep) -> Int {
  step.capped_delay_milliseconds
}
```

A connection that lost its session does not go to a call until it is connected again.

## PgBouncer and the statement cache

By default, each connection prepares a statement one time under a name, and runs it again by that name. Each connection keeps at most 512 statements, and closes the statement that it used least recently to make space. `statement_cache(CacheStatements(limit: n))` sets another limit.

PgBouncer in transaction mode can send the next transaction to another server session, where the named statement does not exist. Behind such a pooler, use `NoStatementCache`. Each statement is then prepared again for each run, with no name:

### Behind PgBouncer <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/behind_pgbouncer.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/config.{type Config, NoStatementCache, statement_cache}

/// Prepares each statement again for each run, with no name, because
/// PgBouncer in transaction mode can send the next transaction to another
/// server session.
pub fn behind_pgbouncer(config: Config) -> Config {
  config
  |> statement_cache(NoStatementCache)
}
```

## Notices

A statement can send notices, such as a `NOTICE` or a `WARNING` from `RAISE`. `notices` sends each notice of each connection of the pool to a subject, as it arrives:

### Send notices to a subject <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/server_notices.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{type Config, type ServerNotice, notices}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}
import gleam/erlang/process.{type Subject}
import gleam/pair
import gleam/result

/// Starts a pool that sends each notice of the server to a new subject of
/// the calling process.
pub fn start_with_notices(
  config: Config,
) -> Result(#(Connection, Subject(ServerNotice)), Error(PostgresError)) {
  let notice_subject = process.new_subject()
  config
  |> notices(notice_subject)
  |> start
  |> result.map(pair.new(_, notice_subject))
}

/// The text of a notice for a log line, such as
/// `NOTICE: the table is empty`.
pub fn notice_line(notice: ServerNotice) -> String {
  notice.localized_severity <> ": " <> notice.message
}
```

A `ServerNotice` has the fields of a server error: the severity, the SQLSTATE, the message, the detail, the hint, and more. A notice that came before the pool stopped reaches the subject before `stop` returns.

## Pool events

`pool_events` sends each event of the pool to a subject, in the order that the pool changed. Each event names the slot of a connection: its place in the pool, from 0.

| Event | Meaning |
|---|---|
| `Connected(slot)` | The connection connected and logged in. |
| `Disconnected(slot, reason)` | The connection lost its session. It connects again. |
| `Reconnected(slot)` | The connection connected and logged in again after a loss. |
| `ConnectFailed(slot, error)` | A connect or a reconnect failed. |
| `Replacing(slot)` | The pool stops the connection process and starts a new one, after a failed rollback or health check, or after the process exited. |
| `Free(slot)` | The connection is free for the next call. |
| `Waiting(count)` | A call found no free connection, and waits with `count` calls. |
| `Held(slot)` | A call holds the connection. |
| `Returned(slot)` | The call that held the connection ended. |
| `Refused(error)` | The pool gave a call no connection. |
| `Stopping` | The pool started to stop. |

This example starts a pool with a subject for its events, and turns each event into a log line:

### Send pool events to a subject <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/pool_events.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{
  type Config, type PoolEvent, ConnectFailed, Connected, Disconnected, Free,
  Held, Reconnected, Refused, Replacing, Returned, Stopping, Waiting,
  pool_events,
}
import dream_postgres/error.{type PostgresError, describe}
import dream_postgres/pool.{type Connection, start}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/pair
import gleam/result

/// Starts a pool that sends each event of the pool to a new subject of
/// the calling process.
pub fn start_with_pool_events(
  config: Config,
) -> Result(#(Connection, Subject(PoolEvent)), Error(PostgresError)) {
  let event_subject = process.new_subject()
  config
  |> pool_events(event_subject)
  |> start
  |> result.map(pair.new(_, event_subject))
}

/// The text of a pool event for a log line.
pub fn event_line(event: PoolEvent) -> String {
  case event {
    Connected(slot:) -> slot_text(slot) <> " connected"
    Disconnected(slot:, reason:) ->
      slot_text(slot) <> " lost its session: " <> describe(reason)
    Reconnected(slot:) -> slot_text(slot) <> " connected again"
    ConnectFailed(slot:, error: failure) ->
      slot_text(slot) <> " did not connect: " <> describe(failure)
    Replacing(slot:) -> slot_text(slot) <> " is replaced"
    Free(slot:) -> slot_text(slot) <> " is free"
    Held(slot:) -> slot_text(slot) <> " is held"
    Returned(slot:) -> slot_text(slot) <> " came back"
    Waiting(count:) -> int.to_string(count) <> " calls wait for a connection"
    Refused(error: failure) -> "a call got no connection: " <> describe(failure)
    Stopping -> "the pool stops"
  }
}

fn slot_text(slot: Int) -> String {
  "connection " <> int.to_string(slot)
}
```

An event that came before the pool stopped reaches the subject before `stop` returns.
