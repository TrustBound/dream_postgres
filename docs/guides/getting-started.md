# Getting started with dream_postgres

Database setup tends to fail late. A typo in `DATABASE_URL`, or a database that isn't up yet, often shows up as a 500 on the first request instead of a clear message when the app starts. This guide takes you from an empty project to a program that connects from `DATABASE_URL`, stops at startup with a message that says what's wrong, runs its first query and hands the result to the rest of your code. You'll also test that code, and the tests need no database.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Step 1: Connect from DATABASE_URL](#step-1-connect-from-database_url)
- [Step 2: Stop at startup when the database doesn't answer](#step-2-stop-at-startup-when-the-database-doesnt-answer)
- [Step 3: Run your first query](#step-3-run-your-first-query)
- [Which way to connect](#which-way-to-connect)
- [When things go wrong](#when-things-go-wrong)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Start a connection pool from a `DATABASE_URL`.
- Stop at startup with a message that names the problem: a bad URL, or a database that doesn't answer.
- Run a query and turn its result into a value your code can use.
- Keep the connection in a context that the rest of your program gets.
- Test that code with results you build by hand.

## Before you start

Add the package, and `dream_postgres_client` with it. dream_postgres sets up the pool and reads the results, but you write the queries with `dream_postgres_client`, a fork of [Pog](https://hexdocs.pm/pog) with the same API, so your code imports it directly, as `import dream_postgres_client`:

```sh
gleam add dream_postgres dream_postgres_client
```

dream_postgres has no dependency on Dream or on any web framework, so it works in any Gleam project on the Erlang target.

You also need a PostgreSQL server. If you have Docker, put this `docker-compose.yml` in your project. It's the server this package's own tests run against: PostgreSQL 16 on port 5436, so it doesn't clash with a PostgreSQL you already run on 5432, and with its data in memory (tmpfs), so each start gives you an empty database. It also turns off `fsync`, `synchronous_commit` and `full_page_writes`, which makes it faster, so use it only for data you can lose:

### The PostgreSQL service of docker-compose.yml <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/docker-compose.yml#L18-L44"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```yaml
services:
  # The server for most tests. SSL is off.
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: dream
      POSTGRES_PASSWORD: dream
      POSTGRES_DB: dream_test
    ports:
      # Port 5436 on this machine, so the tests do not use a PostgreSQL
      # server that already listens on 5432.
      - "5436:5432"
    tmpfs:
      - /var/lib/postgresql/data:rw,size=2g
    command:
      - postgres
      - -c
      - fsync=off
      - -c
      - synchronous_commit=off
      - -c
      - full_page_writes=off
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dream -d dream_test"]
      interval: 1s
      timeout: 5s
      retries: 30
```

Start it, and wait until it accepts connections:

### Start the server <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/scripts/db-up.sh#L7"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
docker compose up -d --wait postgres
```

Its URL is `postgresql://dream:dream@localhost:5436/dream_test`. Step 3 reads a `users` table. Create it in `psql` (`docker compose exec postgres psql -U dream -d dream_test`):

### Make the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/fixtures/sql/getting_started_users.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL);
INSERT INTO users (name) VALUES ('Ada'), ('Grace');
```

Gleam's standard library has no function to read an environment variable. The [envoy](https://hexdocs.pm/envoy) package has one: `envoy.get("DATABASE_URL")` returns `Ok(url)` or `Error(Nil)`. The examples in this guide take the URL as a parameter, so you can call them from `main` with the value you read, or from a test with any URL you like.

## Step 1: Connect from DATABASE_URL

Most hosting platforms give your app one `DATABASE_URL`. `from_url` reads it and starts a pool of connections:

### Start a pool from DATABASE_URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_getting_started_connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/string

pub fn connect(database_url: String) -> Result(postgres.Connection, String) {
  case postgres.from_url(database_url) {
    Ok(connection) -> Ok(connection)
    Error(postgres.InvalidUrl(error)) ->
      Error("DATABASE_URL is not valid: " <> string.inspect(error))
    Error(postgres.PoolStartExited) -> Error("The database pool did not start")
  }
}
```

Here's what happens:

- `from_url` reads the URL, sets a pool size of 15 and starts the pool. Each call registers its pool under a new name, so you don't have to pick one.
- `Ok(connection)` holds a `postgres.Connection`. It's the same type as `dream_postgres_client.Connection`, so you pass it to `dream_postgres_client.execute` to run a query.
- `InvalidUrl(error)` means the URL itself is wrong. The `UrlError` inside says what's wrong, for example `MissingDatabase` or `UnsupportedParameter("connect_timeout")`.
- `PoolStartExited` means the pool process didn't start.

No error from `from_url` holds the password from the URL, so it's safe to print or log one with `string.inspect`. Here's what `connect` returns for a URL with an `sslmode` this package doesn't support:

### What connect returns for an sslmode it does not support <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_getting_started_connect_error.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
connect("postgresql://app:secret@db.example.com/app?sslmode=prefer")
  -> Error("DATABASE_URL is not valid: UnsupportedSslMode(\"prefer\")")
```

There's one thing `from_url` can't tell you: whether a database is listening. The pool connects in the background, so `from_url` returns `Ok` as soon as the pool process runs, even when nothing listens at the host and port in the URL. Step 2 fixes that.

## Step 2: Stop at startup when the database doesn't answer

If the database is down or the URL points at the wrong host, you want to know when the app starts, not when the first user clicks something. `postgres.check` does that: it runs `SELECT 1` on the connection, and returns `Ok(Nil)` when the database answers or the query's error when it doesn't. Call it right after `from_url`. This module grows Step 1 into a `start` function with its own error type:

### Start the pool and check that the database answers <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_getting_started_startup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/result
import gleam/string

pub type StartupError {
  BadDatabaseUrl(error: postgres.UrlError)
  PoolDidNotStart
  DatabaseDidNotAnswer(error: postgres.QueryError)
}

pub fn start(
  database_url: String,
) -> Result(postgres.Connection, StartupError) {
  use connection <- result.try(
    postgres.from_url(database_url)
    |> result.map_error(startup_error),
  )
  use Nil <- result.try(
    postgres.check(connection)
    |> result.map_error(DatabaseDidNotAnswer),
  )
  Ok(connection)
}

fn startup_error(error: postgres.FromUrlError) -> StartupError {
  case error {
    postgres.InvalidUrl(url_error) -> BadDatabaseUrl(url_error)
    postgres.PoolStartExited -> PoolDidNotStart
  }
}

pub fn describe(error: StartupError) -> String {
  case error {
    BadDatabaseUrl(url_error) ->
      "DATABASE_URL is not valid: " <> string.inspect(url_error)
    PoolDidNotStart -> "The database pool did not start"
    DatabaseDidNotAnswer(query_error) ->
      "The database did not answer: " <> string.inspect(query_error)
  }
}
```

A few things to notice:

- `StartupError` keeps the three failures apart, so `main` can print a message that says what to fix. Each variant keeps the error value too, if you'd rather log it than print it.
- `from_url` and `check` fail with different error types: `postgres.FromUrlError` and `postgres.QueryError`. `result.try` needs one error type, so `result.map_error` puts each error into a `StartupError` first.
- `check` returns `Ok(Nil)`, so `start` binds it as `Nil`.
- `result.try` stops at the first `Error`, so a bad URL never gets as far as `check`.

Here's what `start` returns, passed through `describe` when it fails, for the server from [Before you start](#before-you-start), for a wrong password, for a password with an `@` that isn't encoded, and for a URL where nothing listens:

### What start returns <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_getting_started_start.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
start("postgresql://dream:dream@localhost:5436/dream_test")
  -> Ok(connection)

start("postgresql://dream:wrong-password@localhost:5436/dream_test")
  -> Error("The database did not answer: ConnectionUnavailable")

start("postgresql://app:p@ss@db.example.com/app")
  -> Error("DATABASE_URL is not valid: MalformedUrl")

start("postgresql://user:pass@127.0.0.1:<a port where nothing listens>/myapp")
  -> Error("The database did not answer: ConnectionUnavailable")
```

`Ok(connection)` stands for the connection that `start` gives back: it holds a pool name that changes on each call. The port of the last URL is a free port, which changes on each test run. The two `ConnectionUnavailable` answers aren't instant. The query waits while the pool tries to connect, and gives up after 2 to 3 seconds. A user that doesn't exist and a database name that doesn't exist give the same error after the same wait. The error doesn't say which of these it was, but the server's log does: `password authentication failed for user "dream"`, for example. One check at startup covers all of them.

In your `main`, call `start` once. On `Error(error)`, print `describe(error)` to standard error and exit, so whatever runs your app (a container platform, systemd, a release script) sees the failure and the message.

## Step 3: Run your first query

Now the program has a connection that works. Keep it in a context value that your handlers get, and write each query as a function that takes the connection:

### Find a user and greet them <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_getting_started_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/query
import dream_postgres_client
import gleam/dynamic/decode

pub type Context {
  Context(db: dream_postgres_client.Connection)
}

pub type User {
  User(id: Int, name: String)
}

pub fn greet_user(context: Context, id: Int) -> String {
  find_user(context.db, id)
  |> greeting
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(
  dream_postgres_client.Returned(User),
  dream_postgres_client.QueryError,
) {
  dream_postgres_client.query("SELECT id, name FROM users WHERE id = $1")
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning(user_decoder())
  |> dream_postgres_client.execute(db)
}

pub fn greeting(
  result: Result(
    dream_postgres_client.Returned(User),
    dream_postgres_client.QueryError,
  ),
) -> String {
  case query.first_row(result) {
    Ok(user) -> "Hello, " <> user.name
    Error(query.NotFound) -> "No user with that id"
    Error(query.DatabaseError) -> "The database is not available"
  }
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  decode.success(User(id:, name:))
}
```

Here's how the pieces fit:

- `Context` is the value your program builds once at startup and passes to the code that needs the database. A web app usually keeps it in its request context, next to its other services.
- `find_user` builds a Pog query. `$1` is a parameter, and `dream_postgres_client.parameter(dream_postgres_client.int(id))` fills it, so the value never becomes part of the SQL text. `dream_postgres_client.returning` decodes each row with `user_decoder`, and `dream_postgres_client.execute` runs it on the pool.
- `greeting` takes the result and nothing else. `query.first_row` turns it into one of three cases: the first row, `NotFound` when the query returned no rows, or `DatabaseError` when the query failed.
- `greet_user` joins the two: `find_user(context.db, id) |> greeting`.

With the table and the two rows from [Before you start](#before-you-start), here's what `greet_user` and `find_user` return:

### What greet_user and find_user return <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_getting_started_greet_user.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
greet_user(Context(db:), 1)
  -> "Hello, Ada"

greet_user(Context(db:), 3)
  -> "No user with that id"

find_user(db, 2)
  -> Ok(Returned(1, [User(2, "Grace")]))
```

`find_user` shows the result as `string.inspect` writes it, so `dream_postgres_client.Returned(count: 1, rows: [...])` shows as `Returned(1, [...])`. Splitting the query from the code that reads its result is what makes this easy to test. `greeting` doesn't need a database at all. Here's what it returns for a result with two rows, and what `greet_user` returns when no database listens:

### What greeting returns, and greet_user with no database <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_getting_started_greeting.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
greeting(Ok(dream_postgres_client.Returned(count: 2, rows: [User(1, "Ada"), User(2, "Grace")])))
  -> "Hello, Ada"

greet_user(Context(db: <a pool where nothing listens>), 1)
  -> "The database is not available"
```

`first_row` takes the first row and ignores the rest, so it fits a query that finds a row by its primary key. When you write more than a few queries, [Squirrel](https://hexdocs.pm/squirrel) can generate functions like `find_user` from `.sql` files. The [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md) guide uses functions in that shape.

## Which way to connect

`from_url` is the shortest path, but it isn't the only one.

| Your situation | Use | Why |
|:---|:---|:---|
| Your platform gives you a `DATABASE_URL`, and a pool of 15 connections suits you | `postgres.from_url(url)` | One call reads the URL and starts the pool. |
| You have a URL, but you want another pool size or other pool settings | `postgres.parse_config(pool_name, url)`, then the setters, then `postgres.connect(config)` | `parse_config` gives you the `Config` before anything starts. |
| Your settings come as separate values, such as a host and a password from a secret store | `postgres.new(pool_name)` and the builder functions | No URL, so nothing to encode. |
| The pool should run under your app's supervisor | A config, then `dream_postgres_client.supervised(config)` | The supervisor restarts the pool if it crashes. |

The [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md) guide shows each of these.

## When things go wrong

| What happened | What you see | What to do |
|:---|:---|:---|
| The URL has a typo, a missing part or a `libpq` keyword this package doesn't read | `Error(InvalidUrl(error))` from `from_url`, where `error` names the problem | Fix the URL. The [connecting guide](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md#step-1-say-exactly-whats-wrong-with-a-url) turns each `UrlError` into a message. |
| The URL has a server parameter that the server doesn't know, such as `serach_path`, or a value it refuses, such as `timezone=Mars%2FPhobos` | `from_url` returns `Ok`. The first query returns `Error(dream_postgres_client.ConnectionUnavailable)` after 2 to 3 seconds. | The Step 2 check catches it. The PostgreSQL server log names the parameter. |
| The password has an `@`, `/`, `:` or `#` that isn't encoded | `Error(InvalidUrl(MalformedUrl))` | Percent-encode it: `@` is `%40`, `/` is `%2F`, `:` is `%3A`, `#` is `%23`. |
| No database listens at the host and port | `from_url` returns `Ok`. The first query returns `Error(dream_postgres_client.ConnectionUnavailable)` after 2 to 3 seconds. | Check at startup, as Step 2 does. |
| The password is wrong, the user doesn't exist, or the database doesn't exist | `from_url` returns `Ok`. The first query returns `Error(dream_postgres_client.ConnectionUnavailable)` after 2 to 3 seconds, the same as when nothing listens. | The Step 2 check catches it. The PostgreSQL server log names the cause. |
| The table doesn't exist, or the SQL has an error | `Error(dream_postgres_client.PostgresqlError(..))` from `dream_postgres_client.execute` at once, for example `PostgresqlError("42P01", "undefined_table", "relation \"users\" does not exist")`. `first_row` turns it into `DatabaseError`. | Log the Pog error before you turn it into `DatabaseError`. The [queries guide](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md#step-5-keep-the-cause-of-a-failure) shows how. |

## Test your code

The code that reads results is where your logic lives, and you can test it with results you build by hand: `dream_postgres_client.Returned(count: 1, rows: [...])` for a query that worked, and a `dream_postgres_client.QueryError` value for one that didn't. Startup code that fails on a bad URL needs no database either, because the URL is read before anything connects.

The tests here use [dream_test](https://hexdocs.pm/dream_test). Add it as a dev dependency, with the version range this package tests with:

### The dream_test dependency of this package <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/gleam.toml#L28-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_test = ">= 3.0.0 and < 4.0.0"
```

### Test the greeting and the startup check <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_getting_started_testing.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/result
import snippets/guide_getting_started_startup.{describe as describe_error, start}
import snippets/guide_getting_started_users.{User, greeting}

pub fn tests() -> TestSuite {
  describe("my app's database code", [
    it("greets the user of the first row", fn() {
      // Arrange
      let result =
        Ok(
          dream_postgres_client.Returned(count: 1, rows: [
            User(id: 1, name: "Ada"),
          ]),
        )

      // Act
      let text = greeting(result)

      // Assert
      text
      |> should
      |> be_equal("Hello, Ada")
      |> or_fail_with("Expected a greeting for Ada")
    }),
    it("says so when no user has the id", fn() {
      // Arrange
      let result = Ok(dream_postgres_client.Returned(count: 0, rows: []))

      // Act
      let text = greeting(result)

      // Assert
      text
      |> should
      |> be_equal("No user with that id")
      |> or_fail_with("Expected the no-user message")
    }),
    it("stops at startup when the URL has no database name", fn() {
      // Act
      let started =
        start("postgresql://app:secret@localhost:5432")
        |> result.map_error(describe_error)

      // Assert
      started
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("DATABASE_URL is not valid: MissingDatabase"))
      |> or_fail_with("Expected the URL error")
    }),
  ])
}
```

Each test builds its input, calls one function and checks one value:

- The first two tests give `greeting` the two results a working database can return: a row, and no rows.
- The third test calls `start` with a URL that has no database name. `start` returns before it connects, so the test runs in milliseconds.

To test the queries themselves against a real database, run a test database (the `docker-compose.yml` in [Before you start](#before-you-start) works), create the tables in your test setup and pass its URL to `start`. That's how this package tests the code in this guide: each test makes its own schema, runs the SQL from [Before you start](#before-you-start) in it and checks the real rows. Keep tests like that to the queries: most of your logic is in functions like `greeting`, and those don't need a database.

## Common pitfalls

**Treating `Ok` from `from_url` as "the database is up".** *Symptom:* the app starts fine, then every request fails with `ConnectionUnavailable`. *Fix:* `from_url` only starts the pool. Run a query at startup, as in [Step 2](#step-2-stop-at-startup-when-the-database-doesnt-answer).

**Calling `from_url` for each request.** *Symptom:* the database starts to refuse connections after the app has run for a while. *Fix:* each call starts another pool of up to 15 connections, and the old pools keep running. Call it once at startup and pass the connection around in your context, as in [Step 3](#step-3-run-your-first-query).

**A password with special characters.** *Symptom:* `InvalidUrl(MalformedUrl)`, or a login that fails with a password you know is right. *Fix:* percent-encode `@`, `/`, `:` and `#` in the password. The package decodes the user, the password and the database name.

## Where to go next

- [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md): SSL, pool size, IPv6, a supervised pool, and a clear message for each URL error.
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md): turn query results and their errors into responses, with tests.
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md): the package at a glance.
- [API reference on HexDocs](https://hexdocs.pm/dream_postgres/): `dream_postgres/client` and `dream_postgres/query`.
- [Pog on HexDocs](https://hexdocs.pm/pog/), which has the same API as `dream_postgres_client`: queries, parameters, decoders and transactions.
