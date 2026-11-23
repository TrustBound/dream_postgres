# Connecting to PostgreSQL in production

A URL like `postgresql://postgres:secret@localhost/myapp` is all you need on your laptop. Production asks for more: TLS to a managed database, a pool size that fits the server's connection limit, sometimes an IPv6 address, and a URL from a hosting provider that carries parameters you didn't choose. When one of those is wrong, you want the app to say so at startup, in words an operator can act on. This guide walks through each setting, the errors you'll meet, and how to test your connection code.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Choose how to configure the pool](#choose-how-to-configure-the-pool)
- [Step 1: Say exactly what's wrong with a URL](#step-1-say-exactly-whats-wrong-with-a-url)
- [Step 2: Read a URL and set the pool size](#step-2-read-a-url-and-set-the-pool-size)
- [Step 3: Build a config from separate settings](#step-3-build-a-config-from-separate-settings)
- [Step 4: Run the pool under a supervisor](#step-4-run-the-pool-under-a-supervisor)
- [SSL modes](#ssl-modes)
- [The URL format](#the-url-format)
- [What goes wrong at startup](#what-goes-wrong-at-startup)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Turn each kind of bad URL into a message that tells the operator what to fix.
- Read a `DATABASE_URL` with SSL, IPv6 and an application name, and set your own pool size.
- Build the same config from separate settings, such as a host and a password from a secret store.
- Run the pool under an OTP supervisor.
- Test the config your code builds, and what happens when no database listens.

## Before you start

You need the package and Pog:

```sh
gleam add dream_postgres pog
```

The [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md) guide shows a first connection and a startup check. This guide builds on it, but you can read it on its own.

The examples are plain functions that take a URL or settings and return a value. You don't need a database to run most of them: reading a URL doesn't connect, and a pool starts even when nothing listens. For the ones that talk to a server, the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#before-you-start) guide shows a `docker-compose.yml` that starts PostgreSQL 16 on port 5436. The outputs shown below come from the package's tests, which run against that server, or against a port where nothing listens.

## Choose how to configure the pool

There are three ways to get a `Config` (the pool settings), and one more way to start the pool.

| Your situation | Use | Why |
|:---|:---|:---|
| Your platform gives you a `DATABASE_URL`, and the defaults suit you | `postgres.from_url(url)` | One call. It sets a pool size of 15 and starts the pool. |
| You have a URL, but want your own pool size or another Pog setting | `postgres.parse_config(pool_name, url)`, the setters, then `postgres.connect(config)` | `parse_config` reads the URL and doesn't connect, so you can change the config first. |
| Your settings come as separate values | `postgres.new(pool_name)` and the builder functions | Nothing to percent-encode, and each value has its own setter. |
| The pool should restart with the rest of your app | Any of the configs above, then `pog.supervised(config)` | A supervisor restarts the pool if it crashes. |

`postgres.Config` is the same type as `pog.Config`, so every Pog setter works on it too: `pog.ssl`, `pog.ip_version`, `pog.queue_target` and the rest.

## Step 1: Say exactly what's wrong with a URL

A `DATABASE_URL` usually comes from somewhere you don't control: a hosting dashboard, a secret store, a colleague's message. When it's wrong, `parse_config` and `from_url` return a `UrlError` that names the problem. `string.inspect` of it is fine for a log, but an operator reading `UnsupportedSslMode("prefer")` at 3 a.m. still has to look up what to do. This function turns each error into a sentence with the fix:

### Explain each URL error <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_explain_url_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
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
```

Every variant of `UrlError` has a branch, so when a new version of the package adds one, the compiler points you here. None of the variants holds the password, so each message is safe to print.

Here's what it returns for URLs you'll meet in practice:

```text
postgresql://app:secret@db.example.com/app?sslmode=require&channel_binding=require
  -> DATABASE_URL has the parameter channel_binding. Remove it.

postgresql://app:secret@db.example.com/app?sslmode=prefer
  -> DATABASE_URL has sslmode=prefer. Use disable, require or verify-full.

postgresql://app:p@ss@db.example.com/app
  -> DATABASE_URL is not a URL. Percent-encode @, :, / and # in the password.

postgresql://app:secret@db.example.com:5432
  -> DATABASE_URL has no database name

mysql://app:secret@db.example.com/app
  -> DATABASE_URL has the scheme mysql, not postgresql

db.example.com:5432/app
  -> DATABASE_URL has the scheme db.example.com, not postgresql
```

The last one is worth a second look. A URL without `postgresql://` reads as a URL whose scheme is the host name, so you get `UnsupportedScheme`, not `MissingScheme`.

## Step 2: Read a URL and set the pool size

`from_url` always uses 15 connections. To choose your own number, read the URL with `parse_config`, change the config, and start the pool with `connect`:

### Read a URL and set the pool size <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_pool_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/result
import pog
import snippets/guide_connecting_explain_url_error.{explain}

pub fn pool_config(
  pool_name: process.Name(pog.Message),
  database_url: String,
  pool_size: Int,
) -> Result(postgres.Config, postgres.UrlError) {
  postgres.parse_config(pool_name, database_url)
  |> result.map(postgres.pool_size(_, pool_size))
}

pub fn connect_pool(
  database_url: String,
  pool_size: Int,
) -> Result(postgres.Connection, String) {
  let pool_name = process.new_name("app_database")
  use config <- result.try(
    pool_config(pool_name, database_url, pool_size)
    |> result.map_error(explain),
  )
  postgres.connect(config)
  // The start error can hold the config, and the config holds the password
  |> result.replace_error("The database pool did not start")
}
```

How it works:

- `pool_config` is pure: it reads the URL and returns a `Config`, or a `UrlError`. That makes it easy to test, as [Test your code](#test-your-code) shows.
- `postgres.pool_size(_, pool_size)` is the builder function with the config left open, so `result.map` can apply it to the config inside the `Ok`.
- `connect_pool` gives the pool a name with `process.new_name`. The pool registers under that name, and the `Connection` that `connect` returns refers to it.
- `explain` is the function from Step 1. In your app, import it from the module where you put it.
- `connect` returns an `actor.StartError` when the pool process doesn't start. `connect_pool` replaces it with its own message, because the reason inside a start error can hold the config, and the config holds the password.

The URL also sets SSL, IPv6 and the application name. Here's the config that `pool_config` returns for a URL with all three and a pool size of 30:

```text
pool_config(name, "postgresql://app:secret@[2001:db8::10]:6432/app?sslmode=verify-full&application_name=billing", 30)
  host:                  "2001:db8::10"
  port:                  6432
  ssl:                   SslVerified
  ip_version:            Ipv6
  connection_parameters: [#("client_encoding", "UTF8"), #("application_name", "billing")]
  pool_size:             30
```

The host in brackets is an IPv6 address, so `parse_config` sets `Ipv6` for you. `application_name` is the name PostgreSQL shows for your connections in `pg_stat_activity`, which helps when several apps share one database. Ask the server and you'll see it:

```text
from_url("postgresql://dream:dream@localhost:5436/dream_test?application_name=billing")
SELECT current_setting('application_name')
  -> "billing"
```

Why `client_encoding` is in the list: pgo, the driver under Pog, adds its own `application_name`, the name of the Erlang node, such as `nonode@nohost`. PostgreSQL keeps the last `application_name` it gets. pgo puts its value before the first of your parameters whose name sorts after `application_name`. So when there's an `application_name`, this package puts `client_encoding` just before it, and your name comes last. `UTF8` is the encoding that Pog reads and writes. On a UTF-8 database it's also the server's default, so text comes back the same. If you set `client_encoding` yourself, your value stays. Without an `application_name`, the list stays as it is, and the server shows the node name.

**How big should the pool be?** Each connection in the pool is one connection on the PostgreSQL server, and the server has a limit (`max_connections`, 100 by default). Add up the pools of every instance of your app, plus anything else that connects, and stay under that limit. A pool that's too small makes requests wait for a free connection: with a pool of 1, two queries of half a second each, sent at the same time, run one after the other on the same connection, and the second answers after about 1 second. A pool that's too big makes the server refuse connections when you scale out. And don't set the size to 0: `pool_size(0)` is accepted, the pool starts, and every query returns `ConnectionUnavailable` after about 2 seconds.

## Step 3: Build a config from separate settings

When your settings come as separate values, there's no URL to read and nothing to encode. Start from `new` with a pool name, set each value, and call `connect`:

### Build a config and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/actor

pub fn database_config() -> postgres.Config {
  let pool_name = process.new_name("db_pool")
  postgres.new(pool_name)
  |> postgres.host("localhost")
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("postgres")
  |> postgres.password("secret")
  |> postgres.pool_size(15)
}

pub fn connect_database() -> Result(postgres.Connection, actor.StartError) {
  database_config()
  |> postgres.connect()
}
```

The builder functions each set one field and return the new config: `host`, `port`, `database`, `user`, `password` and `pool_size`. Fields you don't set keep Pog's defaults: host `127.0.0.1`, port 5432, database `postgres`, user `postgres`, no password, a pool of 10, no SSL and IPv4.

For production you'll want SSL and an application name too. The package has no setter for those, but `Config` is a `pog.Config`, so Pog's setters slot into the same pipeline:

### Add SSL and an application name <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_builder_ssl.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import pog

pub fn production_config(
  pool_name: process.Name(pog.Message),
  host: String,
  password: String,
) -> postgres.Config {
  postgres.new(pool_name)
  |> postgres.host(host)
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("myapp")
  |> postgres.password(password)
  |> postgres.pool_size(20)
  |> pog.ssl(pog.SslVerified)
  |> pog.connection_parameter(name: "application_name", value: "myapp-web")
}
```

`pog.ssl(pog.SslVerified)` turns on TLS and checks the server's certificate, and `pog.connection_parameter` puts `application_name` in the config. `connect` puts `client_encoding` before it, as [Step 2](#step-2-read-a-url-and-set-the-pool-size) explains, so the server shows `myapp-web`. The [SSL modes](#ssl-modes) section explains the TLS choices.

One difference from the URL path: `host` doesn't look at the address. With `parse_config`, a host like `[2001:db8::10]` sets IPv6. With the builder, `postgres.host("2001:db8::10")` keeps IPv4, so add `|> pog.ip_version(pog.Ipv6)` yourself.

## Step 4: Run the pool under a supervisor

`connect` starts the pool linked to the process that calls it. That's fine for a script. In a long-running app, you'll want the pool in your supervision tree, so it restarts if it crashes. Pog has `pog.supervised` for that, and it takes the same config:

### Start the pool under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_supervised.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/result
import pog
import snippets/guide_connecting_explain_url_error.{explain}

pub fn start_supervised(
  database_url: String,
) -> Result(postgres.Connection, String) {
  let pool_name = process.new_name("app_database")
  use config <- result.try(
    postgres.parse_config(pool_name, database_url)
    |> result.map_error(explain),
  )
  use _supervisor <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(postgres.pool_size(config, 15)))
    |> supervisor.start()
    |> result.replace_error("The supervisor did not start"),
  )
  Ok(pog.named_connection(pool_name))
}
```

What changes here:

- `pog.supervised(config)` is a child specification. The supervisor starts the pool and restarts it under the same name if it stops.
- A supervisor doesn't hand back the pool's `Connection`. `pog.named_connection(pool_name)` makes one from the name, and it keeps working after a restart, because the new pool registers under the same name.
- In a real app you add the pool to the supervisor that starts the rest of your app, and pass the connection to the children that need it.
- `parse_config` already puts `client_encoding` before the `application_name` of the URL, so the server shows that name under `pog.supervised` too.

When no database listens, this works the same as `connect`: `start_supervised` returns `Ok`, and a query on the connection returns `Error(pog.ConnectionUnavailable)`.

## SSL modes

The `sslmode` parameter of the URL maps to `pog.Ssl`. With the builder, you pass the `pog.Ssl` value to `pog.ssl` yourself.

The results below come from the package's tests. They run against two PostgreSQL 16 servers: one with SSL off, and one with SSL on, whose certificate comes from a test CA and names only `localhost`.

| `sslmode` | `pog.Ssl` | What the connection does |
|:---|:---|:---|
| `disable` | `SslDisabled` | No TLS, also when the server has SSL turned on. This is also what you get with no `sslmode` at all. The server's `pg_stat_ssl` shows `ssl = false` for the connection. |
| `require` | `SslUnverified` | TLS 1.3, with no check of the certificate or the host name: it connects to a server whose certificate comes from a CA the client doesn't trust, at an address the certificate doesn't name. Against a server with SSL turned off, the pool never connects: each query returns `ConnectionUnavailable` after about 2 seconds. There's no fallback to plain text. |
| `verify-ca` | `SslVerified` | The same as `verify-full`: it checks the certificate and the host name. `libpq` (the client library behind `psql`) checks only the certificate here, so a URL with an address the certificate doesn't name works in `psql` and fails here. |
| `verify-full` | `SslVerified` | TLS. Checks that a CA the client trusts signed the certificate, and that the certificate names the host of the URL. |
| `prefer`, `allow` or anything else | none | `UnsupportedSslMode(mode)`, because the pool can't fall back from TLS to plain text. |

The client trusts the CA list of OTP's `public_key` application, which is the CA certificates of the operating system. A managed database whose certificate comes from a public CA passes the check. A certificate from a private CA doesn't, until you load that CA as the next section shows.

A failed check looks like every other failed connection: the pool starts, and each query returns `ConnectionUnavailable` after about 2 seconds. The cause shows only in the log. OTP's `ssl` application logs a notice for each try of each connection:

```text
TLS client: ... generated CLIENT ALERT: Fatal - Unknown CA
TLS client: ... generated CLIENT ALERT: Fatal - Bad Certificate, - {bad_cert,{hostname_check_failed,{requested,"127.0.0.1"},{received,[{dNSName,"localhost"}]}}}
```

`Unknown CA` means the client doesn't trust the CA that signed the certificate. `hostname_check_failed` means the certificate doesn't name the host of the URL: here the URL has `127.0.0.1`, and the certificate names only `localhost`.

### Trust a private certificate authority

Neither this package nor Pog has a setting for a CA file. `pog.Config` has no field for one, and Pog gives every `SslVerified` pool the list from `public_key:cacerts_get()`. You can change that list with `public_key:cacerts_load`, before you start the pool:

### Load a CA file, then start the pool <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_private_ca.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/result
import pog

pub fn connect_with_private_ca(
  url: String,
  ca_file: String,
) -> Result(pog.Connection, String) {
  case load_ca_certificates(ca_file) == atom.to_dynamic(atom.create("ok")) {
    False -> Error("Can't read the CA certificates in " <> ca_file)
    True ->
      postgres.from_url(url)
      |> result.replace_error("The pool did not start")
  }
}

// Replaces the CA list of the whole BEAM with the certificates of the
// file. Pog reads that list when a pool starts.
@external(erlang, "public_key", "cacerts_load")
fn load_ca_certificates(path: String) -> Dynamic
```

How it works:

- `ca_file` is a PEM file with the CA certificate, as your provider gives it.
- `public_key:cacerts_load` returns the atom `ok` when it read the file. For a file that doesn't exist, `connect_with_private_ca` returns `Error("Can't read the CA certificates in ...")`.
- With the test CA loaded, `sslmode=verify-full` and `sslmode=verify-ca` connect with TLS to `localhost`, the name in the test server's certificate. To `127.0.0.1`, both return `ConnectionUnavailable`.
- The pool keeps the list it read when it started, so it keeps trusting the CA when the list changes later.

`cacerts_load` replaces the list. It doesn't add to it: after the call, `public_key:cacerts_get()` returns the certificates of that file only. That counts for the whole BEAM, so other pools and other TLS clients that use `public_key:cacerts_get()` lose the CA certificates of the operating system too. If your app also needs those, put them in the same PEM file.

## The URL format

```text
postgresql://user:password@host:port/database?sslmode=verify-full&application_name=myapp
```

| Part | Required | When it's missing | Notes |
|:---|:---|:---|:---|
| `postgresql://` or `postgres://` | yes | `MissingScheme`, or `UnsupportedScheme` when the text before `:` looks like one | Any other scheme gives `UnsupportedScheme(scheme)`. |
| `user` | no | the user `postgres` | Percent-decoded. A password with no user gives `MissingUser`. |
| `password` | no | no password | Percent-decoded. It starts after the first `:`, so a `:` later in the password is kept. |
| `host` | yes | `MissingHost` | An IPv6 address in brackets, such as `[::1]`, sets IPv6. |
| `port` | no | 5432 | 1 to 65535, or `InvalidPort(port)`. A port that isn't a number gives `MalformedUrl`. |
| `database` | yes | `MissingDatabase` | One path segment, percent-decoded. `/a/b` gives `InvalidDatabase("/a/b")`. Encode a `/` in the name as `%2F`. |
| `sslmode` | no | `SslDisabled` | See [SSL modes](#ssl-modes). |
| `application_name` | no | not set | Sets the PostgreSQL connection parameter of that name, with `client_encoding=UTF8` before it, so that the server shows the name. |
| any other parameter | no | | `UnsupportedParameter(name)` |
| a `#` part | no | | `UnsupportedFragment` |

A bad percent-encoding, such as `%zz`, gives `InvalidUserEncoding`, `InvalidPasswordEncoding` or `InvalidDatabaseEncoding`. Settings the URL can't express, such as the pool size, keep the values from `new`.

## What goes wrong at startup

| What happened | What you see | What to do |
|:---|:---|:---|
| The URL is wrong | `Error(UrlError)` from `parse_config`, or `Error(InvalidUrl(UrlError))` from `from_url` | Print it with `explain` from [Step 1](#step-1-say-exactly-whats-wrong-with-a-url). |
| Nothing listens at the host and port | `connect` and `from_url` return `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | Call `postgres.check` after `from_url` or `connect`, as the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#step-2-stop-at-startup-when-the-database-doesnt-answer) guide does. |
| The password is wrong, or the user or the database doesn't exist | `connect` and `from_url` return `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | `postgres.check` at startup gives the same error. The PostgreSQL server log says which one it was. |
| Any `sslmode` but `disable`, and the server has SSL turned off | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds | Turn on SSL on the server, or use `sslmode=disable` on a network you trust. |
| `verify-ca` or `verify-full`, and the client doesn't trust the CA of the server's certificate | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds. The log shows `Fatal - Unknown CA`. | Load the CA with `public_key:cacerts_load`, as [Trust a private certificate authority](#trust-a-private-certificate-authority) shows. |
| `verify-ca` or `verify-full`, and the certificate doesn't name the host of the URL | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds. The log shows `hostname_check_failed`. | Put a host name from the certificate in the URL. |
| The pool size is 0 | `connect` returns `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | Set a pool size of 1 or more. |
| You call `connect` twice with the same pool name | The second call returns `Error(actor.StartError)`. The first pool keeps running. | Make a new name with `process.new_name` for each pool, or start the pool once. |
| The pool process doesn't start | `Error(actor.StartError)` from `connect`, `Error(PoolStartExited)` from `from_url` | Don't log the `StartError` with `string.inspect`: its reason can hold the config, and the config holds the password. |

## Test your code

Most of your connection code is pure: it reads a URL and builds a config. Test that by checking the fields of the config. For the part that starts a pool, point it at a port where nothing listens. The pool starts, and a query fails with `ConnectionUnavailable`, which is exactly the path your startup check has to handle.

These tests use [dream_test](https://hexdocs.pm/dream_test), added from GitHub as the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#test-your-code) guide shows:

### Test the config and a pool with no database <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_testing.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/erlang/process
import gleam/result
import pog
import snippets/guide_connecting_pool_config.{connect_pool, pool_config}

pub fn tests() -> TestSuite {
  describe("my app's database connection", [
    it("reads the host, the SSL mode and the pool size", fn() {
      // Arrange
      let pool_name = process.new_name("test_database")
      let url = "postgresql://app:secret@db.internal/app?sslmode=verify-full"

      // Act
      let config = pool_config(pool_name, url, 25)

      // Assert
      config
      |> result.map(fn(config) { #(config.host, config.ssl, config.pool_size) })
      |> should
      |> be_equal(Ok(#("db.internal", pog.SslVerified, 25)))
      |> or_fail_with("Expected the host, SSL and pool size")
    }),
    it("explains a URL with a parameter it does not support", fn() {
      // Arrange
      let url = "postgresql://app:secret@db.internal/app?connect_timeout=10"

      // Act
      let connected = connect_pool(url, 25)

      // Assert
      connected
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(
        "DATABASE_URL has the parameter connect_timeout. Remove it.",
      ))
      |> or_fail_with("Expected the unsupported parameter")
    }),
    it("gives ConnectionUnavailable when no database listens", fn() {
      // Arrange
      // Nothing listens on port 1 of this machine
      let assert Ok(db) =
        connect_pool("postgresql://app:secret@127.0.0.1:1/app", 2)

      // Act
      let answer = postgres.check(db)

      // Assert
      answer
      |> should
      |> be_equal(Error(pog.ConnectionUnavailable))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
  ])
}
```

What each test covers:

- The first test checks the three values your production config depends on. A typo in the code that sets them shows up here, not in production.
- The second test checks the message an operator sees for a URL from a provider that adds `connect_timeout`.
- The third test starts a real pool on port 1 of `127.0.0.1`, where nothing listens, and calls `postgres.check`. It takes about 2 seconds, so keep tests like it few.

To check that the pool really connects, give `connect_pool` the URL of a test server, such as the one from [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#before-you-start), and run a query on it. This package's tests do that for `connect_pool` and `start_supervised`.

## Common pitfalls

**Extra parameters from a hosting provider.** *Symptom:* `UnsupportedParameter("channel_binding")`, `UnsupportedParameter("connect_timeout")` or similar, for a URL that `psql` accepts. *Fix:* this package reads only `sslmode` and `application_name`, and it refuses the rest so that no setting is silently dropped. Remove the parameter from the URL, or build the config with the builder functions.

**`sslmode=prefer`.** *Symptom:* `UnsupportedSslMode("prefer")`. `prefer` is the `libpq` default, so you'll find it in URLs that other tools generate. *Fix:* use `require` for TLS without a certificate check, or `verify-full` for TLS with one.

**`verify-ca` with an address the certificate doesn't name.** *Symptom:* with `sslmode=verify-ca` and an IP address in the URL, the pool doesn't connect and queries return `ConnectionUnavailable`, although `psql` connects with the same URL. *Fix:* this package checks the host name for `verify-ca` too, because it maps `verify-ca` to the same `pog.SslVerified` as `verify-full`. Put a host name from the certificate in the URL, or use `require`.

**A database with a private CA.** *Symptom:* with `sslmode=verify-full`, queries return `ConnectionUnavailable`, and the log shows `Fatal - Unknown CA`, but `sslmode=require` connects. *Fix:* the client trusts only the CA certificates of the operating system. Load your provider's CA file with `public_key:cacerts_load` before you start the pool, as [Trust a private certificate authority](#trust-a-private-certificate-authority) shows.

**`application_name` with `pog.supervised` or `pog.start` and the builder.** *Symptom:* `pg_stat_activity` shows the Erlang node name, such as `nonode@nohost`, not the `application_name` you set with `pog.connection_parameter`. *Cause:* the config went to Pog without `connect` or `parse_config`, so this package didn't put `client_encoding` before the name. *Fix:* add `|> pog.connection_parameter(name: "client_encoding", value: "UTF8")` after the `application_name` line, or start the pool with `connect`.

**A password with special characters.** *Symptom:* `MalformedUrl`, or a login that fails. *Fix:* percent-encode `@`, `/`, `:` and `#` in the password (`%40`, `%2F`, `%3A`, `%23`).

**An IPv6 address with the builder.** *Symptom:* the pool never connects to an IPv6 host that a URL connects to. *Fix:* `postgres.host` doesn't set the IP version. Add `|> pog.ip_version(pog.Ipv6)`.

**Pools that add up to more than the server allows.** *Symptom:* connections fail after you add instances of the app. *Fix:* the pool size counts per instance. Keep the total under the server's `max_connections`.

## Where to go next

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): a first connection, a startup check and a first query.
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md): turn query results and their errors into responses.
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md): the package at a glance.
- [API reference on HexDocs](https://hexdocs.pm/dream_postgres/dream_postgres/client.html): `from_url`, `parse_config`, `UrlError` and the builder functions.
- [Pog on HexDocs](https://hexdocs.pm/pog/pog.html): `pog.Config`, `pog.ssl`, `pog.supervised` and the other pool settings.
