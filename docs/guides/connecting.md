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

You need the package and `dream_pog`, a fork of Pog that this package uses. Import it as `pog`: `import dream_pog as pog`.

```sh
gleam add dream_postgres dream_pog
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
    postgres.UnknownParameterLooksLike(name, keyword) ->
      "DATABASE_URL has the parameter "
      <> name
      <> ", which looks like "
      <> keyword
      <> ". Fix the spelling."
    postgres.UnsupportedSslMode(mode) ->
      "DATABASE_URL has sslmode="
      <> mode
      <> ". Use disable, require, verify-ca or verify-full."
    postgres.SslRootCertSystemNeedsVerifyFull(mode) ->
      "DATABASE_URL has sslrootcert=system with sslmode="
      <> mode
      <> ". Use sslmode=verify-full."
    postgres.SslRootCertWithoutSslMode ->
      "DATABASE_URL has sslrootcert but no sslmode. Add sslmode=verify-full."
    postgres.UnsupportedFragment -> "DATABASE_URL has a # part. Remove it."
  }
}
```

Every variant of `UrlError` has a branch, so when a new version of the package adds one, the compiler points you here. None of the variants holds the password, so each message is safe to print.

Here's what it returns for URLs you'll meet in practice:

### What explain returns <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_explain.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
postgresql://app:secret@db.example.com/app?sslmode=require&channel_binding=require
  -> DATABASE_URL has the parameter channel_binding. Remove it.

postgresql://app:secret@db.example.com/app?sslmode=prefer
  -> DATABASE_URL has sslmode=prefer. Use disable, require, verify-ca or verify-full.

postgresql://app:secret@db.example.com/app?sslmod=require
  -> DATABASE_URL has the parameter sslmod, which looks like sslmode. Fix the spelling.

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
import dream_pog as pog
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/result
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

### The config of pool_config <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_pool_config.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
pool_config(name, "postgresql://app:secret@[2001:db8::10]:6432/app?sslmode=verify-full&application_name=billing", 30)
  host:                  "2001:db8::10"
  port:                  6432
  ssl:                   SslVerified
  ip_version:            Ipv6
  connection_parameters: [#("application_name", "billing")]
  pool_size:             30
```

The host in brackets is an IPv6 address, so `parse_config` sets `Ipv6` for you. `application_name` is the name PostgreSQL shows for your connections in `pg_stat_activity`, which helps when several apps share one database. Ask the server and you'll see it:

### The application name the server shows <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_application_name.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
from_url("postgresql://dream:dream@localhost:5436/dream_test?application_name=billing")
SELECT current_setting('application_name')
  -> "billing"
```

Any other name in the query string that isn't a `libpq` connection keyword goes to the server as a run-time parameter, such as `search_path`, `timezone` or `statement_timeout`. The server applies it to each connection of the pool:

### The parameters the server applies <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_server_parameters.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
from_url("postgresql://dream:dream@localhost:5436/dream_test?search_path=app&timezone=UTC&application_name=billing")
SELECT current_setting('search_path') || '|' || current_setting('timezone') || '|' || current_setting('application_name')
  -> "app|UTC|billing"
```

The driver under `dream_pog` sends your `application_name` to the server. Without one, it sends the name of the Erlang node, such as `nonode@nohost`. Set the name with the `application_name` parameter, not with `-c application_name=...` in `options`: the server applies `options` first and the separate parameters after it, so the node name replaces a name from `options`. Write the name in lower case: the driver does not see `Application_Name` as your name, and the server then shows the node name.

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
import dream_pog as pog
import dream_postgres/client as postgres
import gleam/erlang/process

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

`pog.ssl(pog.SslVerified)` turns on TLS and checks the server's certificate, and `pog.connection_parameter` puts `application_name` in the config, so the server shows `myapp-web`. The [SSL modes](#ssl-modes) section explains the TLS choices.

One difference from the URL path: `host` doesn't look at the address. With `parse_config`, a host like `[2001:db8::10]` sets IPv6. With the builder, `postgres.host("2001:db8::10")` keeps IPv4, so add `|> pog.ip_version(pog.Ipv6)` yourself.

## Step 4: Run the pool under a supervisor

`connect` starts the pool linked to the process that calls it. That's fine for a script. In a long-running app, you'll want the pool in your supervision tree, so it restarts if it crashes. Pog has `pog.supervised` for that, and it takes the same config:

### Start the pool under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_supervised.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_pog as pog
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/result
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
- The server shows the `application_name` of the URL under `pog.supervised` too.

When no database listens, this works the same as `connect`: `start_supervised` returns `Ok`, and a query on the connection returns `Error(pog.ConnectionUnavailable)`.

## SSL modes

The `sslmode` parameter of the URL maps to `pog.Ssl`. With the builder, you pass the `pog.Ssl` value to `pog.ssl` yourself.

The results below come from the package's tests. They run against two PostgreSQL 16 servers: one with SSL off, and one with SSL on, whose certificate comes from a test CA and names only `localhost`.

| `sslmode` | `pog.Ssl` | What the connection does |
|:---|:---|:---|
| `disable` | `SslDisabled` | No TLS, also when the server has SSL turned on. This is also what you get with no `sslmode` at all. The server's `pg_stat_ssl` shows `ssl = false` for the connection. |
| `require` | `SslUnverified` | TLS 1.3, with no check of the certificate or the host name: it connects to a server whose certificate comes from a CA the client doesn't trust, at an address the certificate doesn't name. Against a server with SSL turned off, the pool never connects: each query returns `ConnectionUnavailable` after about 2 seconds. There's no fallback to plain text. |
| `verify-ca` | `SslVerifiedChainOnly` | TLS. Checks that a CA the client trusts signed the certificate, but not the host name, as `libpq` (the client library behind `psql`) does. It connects to `127.0.0.1` with a certificate that names only `localhost`. |
| `verify-full` | `SslVerified` | TLS. Checks that a CA the client trusts signed the certificate, and that the certificate names the host of the URL. |
| `prefer`, `allow` or anything else | none | `UnsupportedSslMode(mode)`, because the pool can't fall back from TLS to plain text. |

The client trusts the CA list of OTP's `public_key` application, which is the CA certificates of the operating system. A managed database whose certificate comes from a public CA passes the check. A certificate from a private CA doesn't, until you name the CA file as the next section shows.

A failed check looks like every other failed connection: the pool starts, and each query returns `ConnectionUnavailable` after about 2 seconds. The cause shows only in the log. OTP's `ssl` application logs a notice for each try of each connection:

### The notices of a failed certificate check <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_tls_notices.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
TLS client: ... generated CLIENT ALERT: Fatal - Unknown CA
TLS client: ... generated CLIENT ALERT: Fatal - Bad Certificate, - {bad_cert,{hostname_check_failed,{requested,"127.0.0.1"},{received,[{dNSName,"localhost"}]}}}
```

The `...` stands for the place in OTP's source that logs the alert, which changes from one OTP release to the next. `Unknown CA` means the client doesn't trust the CA that signed the certificate. `hostname_check_failed` means the certificate doesn't name the host of the URL: here the URL has `127.0.0.1`, and the certificate names only `localhost`.

### Trust a private certificate authority

Name the PEM file of your provider's CA in the URL, with `sslrootcert`:

```text illustration
postgresql://app:secret@db.internal/app?sslmode=verify-full&sslrootcert=/etc/ssl/db-ca.pem
```

The pool then trusts the CA certificates of that file, and only those. Other pools keep the CA certificates of the system. `sslmode` and `sslrootcert` give these `pog.Ssl` values, with the meaning `libpq` gives them:

| `sslmode` | no `sslrootcert` | `sslrootcert=<path>` |
|:---|:---|:---|
| not set | `SslDisabled` | `SslRootCertWithoutSslMode` |
| `disable` | `SslDisabled` | `SslDisabled`: the file is not used |
| `require` | `SslUnverified` | `SslVerifiedChainOnlyCaFile(path)`: a CA file makes `require` check the chain, as in `libpq` |
| `verify-ca` | `SslVerifiedChainOnly` | `SslVerifiedChainOnlyCaFile(path)` |
| `verify-full` | `SslVerified` | `SslVerifiedCaFile(path)` |

`sslrootcert=system` names the CA certificates of the system. It gives `SslVerified` with `sslmode=verify-full` or with no `sslmode`, and `SslRootCertSystemNeedsVerifyFull(mode)` with another mode. These are the rules of `pog.url_config` in `dream_pog` too.

With the builder, put the file in the `pog.Ssl` value:

### Trust the CA of one file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_private_ca.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_pog as pog
import dream_postgres/client as postgres
import gleam/otp/actor

pub fn connect_with_private_ca(
  config: postgres.Config,
  ca_file: String,
) -> Result(postgres.Connection, actor.StartError) {
  config
  |> pog.ssl(pog.SslVerifiedCaFile(ca_file))
  |> postgres.connect()
}
```

How it works:

- `ca_file` is a PEM file with the CA certificate, as your provider gives it.
- `connect` reads the file before the pool starts. A file that can't be read, or that holds no certificate, is an error of `connect`, and no pool starts.
- With the test CA file, `sslmode=verify-full` connects with TLS to `localhost`, the name in the test server's certificate, and returns `ConnectionUnavailable` for `127.0.0.1`. `sslmode=verify-ca` connects to both.

For a file that doesn't exist, and for a file with no certificate:

### The errors of a bad CA file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_connecting_ca_file_errors.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
connect_with_private_ca(config, "test/fixtures/ssl/missing.crt")
  -> Error(InitExited(Abnormal("dream_pog: the CA file test/fixtures/ssl/missing.crt cannot be read: enoent")))

connect_with_private_ca(config, "README.md")
  -> Error(InitExited(Abnormal("dream_pog: the CA file README.md holds no PEM certificate")))
```

`from_url` with such a file returns `Error(PoolStartExited)`.

## The URL format

```text illustration
postgresql://user:password@host:port/database?sslmode=verify-full&application_name=myapp
```

| Part | Required | When it's missing | Notes |
|:---|:---|:---|:---|
| `postgresql://` or `postgres://` | yes | `MissingScheme`, or `UnsupportedScheme` when the text before `:` looks like one | Any other scheme gives `UnsupportedScheme(scheme)`. |
| `user` | no | the user `postgres` | Percent-decoded. A password with no user gives `MissingUser`. `%00` gives `InvalidUserEncoding`. |
| `password` | no | no password | Percent-decoded. It starts after the first `:`, so a `:` later in the password is kept. `%00` gives `InvalidPasswordEncoding`. |
| `host` | yes | `MissingHost` | An IPv6 address in brackets, such as `[::1]`, sets IPv6. |
| `port` | no | 5432 | 1 to 65535, or `InvalidPort(port)`. A port that isn't a number gives `MalformedUrl`. |
| `database` | yes | `MissingDatabase` | One path segment, percent-decoded. `/a/b` gives `InvalidDatabase("/a/b")`. Encode a `/` in the name as `%2F`. `%00` gives `InvalidDatabaseEncoding`. |
| `sslmode` | no | `SslDisabled` | See [SSL modes](#ssl-modes). |
| `sslrootcert` | no | the CA certificates of the system | The path of a PEM file with the CA certificates to trust, or `system`. It needs an `sslmode`. See [Trust a private certificate authority](#trust-a-private-certificate-authority). |
| `application_name` | no | not set | Sets the PostgreSQL connection parameter of that name, so that the server shows the name. It wins over `-c application_name=...` in `options`. |
| `options` | no | not set | Goes to the server, which reads it like the command line of a backend. `options=-c%20statement_timeout%3D5s` sets `statement_timeout` to `5s`. Don't set `application_name` here: the server applies the separate parameters after `options`, and the driver always sends an `application_name`. So `options=-c%20application_name%3Dx` alone shows the Erlang node name, such as `nonode@nohost`, and with `application_name=y` in the URL too, the server shows `y`, in either order. |
| a name that starts with `_pq_.` | no | | `UnsupportedParameter(name)`. PostgreSQL reads such a name as a protocol option, not a setting, and closes the connection when it doesn't know it. |
| any other `libpq` connection keyword, such as `connect_timeout`, `channel_binding`, `user`, `password` or `client_encoding`, and `database` | no | | `UnsupportedParameter(name)`. The server can't apply these, so the package refuses them, not drops them. |
| a name at most one edit from a keyword (one character added, removed or changed, or two next to each other swapped, with upper case read as lower case), such as `sslmod`, `ssl_mode`, `sslmdoe` or `SSLMODE` | no | | `UnknownParameterLooksLike(name, keyword)`, for example `UnknownParameterLooksLike("sslmod", "sslmode")`. Fix the spelling. |
| any other name, such as `search_path`, `timezone` or `statement_timeout` | no | not set | Goes to the server as a run-time parameter, with its percent-decoded value. |
| a `#` part | no | | `UnsupportedFragment` |

A bad percent-encoding, such as `%zz`, gives `InvalidUserEncoding`, `InvalidPasswordEncoding` or `InvalidDatabaseEncoding`. So does `%00`: the driver ends each of these at a null byte and would send the rest to the server as another parameter. A database name of `dream_test%00search_path%00evil` would connect to `dream_test` with `search_path` set to `evil`. `connect` refuses a config built with the builder functions in the same case: a user, database name, password or connection parameter that holds a null byte gives `Error(actor.InitFailed("the user holds a null byte, which PostgreSQL cannot take"))`, with the part's name, and no pool starts. Settings the URL can't express, such as the pool size, keep the values from `new`.

How the query string is read:

- Parameters go to the server in the order of the URL. When a name comes twice, the last value wins, as in `libpq`: `search_path=a&search_path=b` gives `b`. That holds for `sslmode`, `sslrootcert` and `application_name` too.
- Keyword names are case-sensitive, as in `libpq`, so `SSLMODE` and `Application_Name` give `UnknownParameterLooksLike`. The server reads its own parameter names in any case: `Search_Path=app` sets `search_path`.
- Names and values are percent-decoded: `search_path=%22my%20app%22%2Cpublic` gives `"my app",public`.
- An empty value goes to the server as it is: `search_path=` gives an empty `search_path`. An empty name gives `UnsupportedParameter("")`, and `%00` in a name or a value gives `MalformedUrl`.
- The package doesn't know the server's parameters. A name the server doesn't know, such as `serach_path`, or a value it refuses, such as `timezone=Mars%2FPhobos`, fails at connection time, as [What goes wrong at startup](#what-goes-wrong-at-startup) shows.

## What goes wrong at startup

| What happened | What you see | What to do |
|:---|:---|:---|
| The URL is wrong | `Error(UrlError)` from `parse_config`, or `Error(InvalidUrl(UrlError))` from `from_url` | Print it with `explain` from [Step 1](#step-1-say-exactly-whats-wrong-with-a-url). |
| Nothing listens at the host and port | `connect` and `from_url` return `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | Call `postgres.check` after `from_url` or `connect`, as the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#step-2-stop-at-startup-when-the-database-doesnt-answer) guide does. |
| The password is wrong, or the user or the database doesn't exist | `connect` and `from_url` return `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | `postgres.check` at startup gives the same error. The PostgreSQL server log says which one it was. |
| Any `sslmode` but `disable`, and the server has SSL turned off | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds | Turn on SSL on the server, or use `sslmode=disable` on a network you trust. |
| `verify-ca` or `verify-full`, and the client doesn't trust the CA of the server's certificate | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds. The log shows `Fatal - Unknown CA`. | Name the CA file with `sslrootcert`, as [Trust a private certificate authority](#trust-a-private-certificate-authority) shows. |
| `verify-full`, and the certificate doesn't name the host of the URL | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds. The log shows `hostname_check_failed`. | Put a host name from the certificate in the URL. |
| A server parameter that the server doesn't know, such as `serach_path`, or a value it refuses, such as `timezone=Mars%2FPhobos`, `timezone=` or `statement_timeout=abc` | `parse_config` and `from_url` return `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | `postgres.check` at startup gives the same error. Only the PostgreSQL server log says why, for example `unrecognized configuration parameter "serach_path"`. Fix the name or the value in the URL. |
| A parameter the user may not set, such as `session_replication_role`, or `role` for a role the user isn't a member of | `Ok`, then `Error(pog.ConnectionUnavailable)` on each query, after about 2 seconds. The server log shows `permission denied to set parameter`. | Remove the parameter, or let an administrator grant the right. |
| The pool size is 0 | `connect` returns `Ok`. Each query returns `Error(pog.ConnectionUnavailable)` after about 2 seconds. | Set a pool size of 1 or more. |
| You call `connect` twice with the same pool name | The second call returns `Error(actor.StartError)`. The first pool keeps running. | Make a new name with `process.new_name` for each pool, or start the pool once. |
| The pool process doesn't start | `Error(actor.StartError)` from `connect`, `Error(PoolStartExited)` from `from_url` | Don't log the `StartError` with `string.inspect`: its reason can hold the config, and the config holds the password. |

## Test your code

Most of your connection code is pure: it reads a URL and builds a config. Test that by checking the fields of the config. For the part that starts a pool, point it at a port where nothing listens. The pool starts, and a query fails with `ConnectionUnavailable`, which is exactly the path your startup check has to handle.

These tests use [dream_test](https://hexdocs.pm/dream_test), added from GitHub as the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#test-your-code) guide shows:

### Test the config and a pool with no database <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_testing.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_pog as pog
import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/erlang/process
import gleam/result
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

**Extra parameters from a hosting provider.** *Symptom:* `UnsupportedParameter("channel_binding")`, `UnsupportedParameter("connect_timeout")` or similar, for a URL that `psql` accepts. *Fix:* this package reads `sslmode`, `application_name` and `options`, and sends server parameters such as `search_path` to the server. It refuses the other `libpq` connection keywords, because the server can't apply them, so no setting is silently dropped. Remove the parameter from the URL, or build the config with the builder functions.

**A misspelled server parameter.** *Symptom:* `from_url` returns `Ok`, and each query returns `ConnectionUnavailable` after about 2 seconds. The server log shows `unrecognized configuration parameter`. *Cause:* the package sends every name that isn't a `libpq` keyword to the server, and the server refuses the connection for a name it doesn't know. *Fix:* call `postgres.check` at startup, and fix the name from the server log. A name one edit from a keyword, such as `sslmod`, gives `UnknownParameterLooksLike` at once, so a misspelled `sslmode` never runs without TLS.

**`sslmode=prefer`.** *Symptom:* `UnsupportedSslMode("prefer")`. `prefer` is the `libpq` default, so you'll find it in URLs that other tools generate. *Fix:* use `require` for TLS without a certificate check, or `verify-full` for TLS with one.

**`verify-ca` where you want a host check.** *Symptom:* a pool with `sslmode=verify-ca` connects to a server at an address that its certificate doesn't name. *Fix:* `verify-ca` checks only that a trusted CA signed the certificate, as in `libpq`. Use `verify-full` to also check the host name.

**A database with a private CA.** *Symptom:* with `sslmode=verify-full`, queries return `ConnectionUnavailable`, and the log shows `Fatal - Unknown CA`, but `sslmode=require` connects. *Fix:* the client trusts only the CA certificates of the operating system. Name your provider's CA file with `sslrootcert`, as [Trust a private certificate authority](#trust-a-private-certificate-authority) shows.

**`Application_Name` in mixed case.** *Symptom:* `pg_stat_activity` shows the Erlang node name, such as `nonode@nohost`, not the name you set with `pog.connection_parameter(name: "Application_Name", ...)`. *Cause:* the driver under `dream_pog` compares the parameter name with case, so it sends the node name too, and PostgreSQL keeps the node name. *Fix:* write `application_name` in lower case.

**A password with special characters.** *Symptom:* `MalformedUrl`, or a login that fails. *Fix:* percent-encode `@`, `/`, `:` and `#` in the password (`%40`, `%2F`, `%3A`, `%23`).

**An IPv6 address with the builder.** *Symptom:* the pool never connects to an IPv6 host that a URL connects to. *Fix:* `postgres.host` doesn't set the IP version. Add `|> pog.ip_version(pog.Ipv6)`.

**Pools that add up to more than the server allows.** *Symptom:* connections fail after you add instances of the app. *Fix:* the pool size counts per instance. Keep the total under the server's `max_connections`.

## Where to go next

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): a first connection, a startup check and a first query.
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md): turn query results and their errors into responses.
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md): the package at a glance.
- [API reference on HexDocs](https://hexdocs.pm/dream_postgres/dream_postgres/client.html): `from_url`, `parse_config`, `UrlError` and the builder functions.
- [Pog on HexDocs](https://hexdocs.pm/pog/pog.html), which has the same API as `dream_pog`: `pog.Config`, `pog.ssl`, `pog.supervised` and the other pool settings.
