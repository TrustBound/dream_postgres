# Test database code with recorded queries

Tests that run against a real database are slow to start. They need a server on every machine that runs them, and they fail when that server isn't there. A mock connection answers only what you told it, not what PostgreSQL really says. A recording sits in between. You run a test once against the real database, and the recorder saves each query and its real result to a file. From then on, the test plays that file back with no database at all. This guide takes a module with two queries to a test that records once and then runs with no database. It also shows the error of a query with no recording, how to keep a secret out of the file, and what to do when a query changes.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which mode to use](#which-mode-to-use)
- [Step 1: Write the module under test](#step-1-write-the-module-under-test)
- [Step 2: Start a recorder and connect](#step-2-start-a-recorder-and-connect)
- [Step 3: Record once against the real database](#step-3-record-once-against-the-real-database)
- [Step 4: Play it back with no database](#step-4-play-it-back-with-no-database)
- [Step 5: Read a query with no recording](#step-5-read-a-query-with-no-recording)
- [Step 6: Keep a secret out of the file](#step-6-keep-a-secret-out-of-the-file)
- [Step 7: Record again after a query changes](#step-7-record-again-after-a-query-changes)
- [How a query finds its recording](#how-a-query-finds-its-recording)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Write two query functions that take a connection, so they don't know about recordings.
- Start a recorder for one test, and get a connection from it.
- Record the test once against PostgreSQL, and read the file it writes.
- Play the test back while no database runs.
- Read the error of a query that has no recording.
- Hide a session token, so the file never holds it.
- Record again after a query changed.

## Before you start

You need the package and `dream_postgres_client` (a fork of Pog):

```sh
gleam add dream_postgres dream_postgres_client
```

The examples use the users table of [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md#before-you-start):

### Make the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/fixtures/sql/queries_users.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
CREATE TABLE users (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email text NOT NULL UNIQUE
);
```

Only the recording run needs the table. The playback runs need no database at all. The tests use [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#test-your-code). The outputs below come from the package's tests, against PostgreSQL 16.

## Which mode to use

A recorder runs in one of three modes. You pick one with a `recorder.Mode` value when you start it:

| Your situation | Mode | What happens |
|:---|:---|:---|
| You want a new recording from the real database | `recorder.Record` | Each query runs on the database. The recorder writes the query, its parameters and its result to the file before the query returns. |
| The test must run without a database | `recorder.Playback` | No pool starts and nothing connects. Each query gets the result of its recording. A query with no recording gets an error that names it. |
| The recorder is in place, but you want plain queries for now | `recorder.Passthrough` | Each query runs on the database, and nothing is written. |

`recorder.new()` starts in `Passthrough` mode. These are the same three modes, with the same names, as the HTTP recorder of [dream_http_client](https://github.com/TrustBound/dream_http_client).

## Step 1: Write the module under test

Here are two query functions: one inserts a user and gives the new id, the other finds a user by id. Each takes a connection as its first parameter. That's the whole trick. The test decides what connection to pass, so the same code runs on a pool, a recording pool or a playback connection.

### Two queries on the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres_client
import gleam/dynamic/decode
import gleam/result

pub type User {
  User(id: Int, name: String, email: String)
}

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Result(Int, dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.text(name))
  |> dream_postgres_client.parameter(dream_postgres_client.text(email))
  |> dream_postgres_client.returning(decode.at([0], decode.int))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(User, dream_postgres_client.QueryError) {
  dream_postgres_client.query("SELECT id, name, email FROM users WHERE id = $1")
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.try(first)
}

// No row is an error here, so a test sees it.
fn first(rows: List(a)) -> Result(a, dream_postgres_client.QueryError) {
  case rows {
    [row, ..] -> Ok(row)
    [] ->
      Error(dream_postgres_client.PostgresqlError(
        "P0002",
        "no_data_found",
        "No row",
      ))
  }
}
```

`find_user` gives an error for no row, so a test sees it. The code under test is a function that uses both:

### The code under test <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam#L13-L18"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn create_and_find(
  db: dream_postgres_client.Connection,
) -> Result(User, dream_postgres_client.QueryError) {
  use id <- result.try(create_user(db, "Ada", "ada@example.com"))
  find_user(db, id)
}
```

## Step 2: Start a recorder and connect

A recorder keeps the queries of one test in one file, `<directory>/<name>.json`. Use the name of the test as the name. Start it, then let it make the connection:

### Start a recorder and connect <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import dream_postgres/recorder
import dream_postgres_client
import gleam/erlang/process
import gleam/result
import gleam/string

pub fn start_recorder(
  mode: recorder.Mode,
  directory: String,
  test_name: String,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(test_name)
  |> recorder.mode(mode)
  |> recorder.start()
}

/// In playback mode, nothing connects to `database_url`.
pub fn connect(
  recording: recorder.Recorder,
  database_url: String,
) -> Result(dream_postgres_client.Connection, String) {
  use config <- result.try(
    postgres.parse_config(process.new_name("test_database"), database_url)
    |> result.map_error(string.inspect),
  )
  recorder.connect(recording, config)
  |> result.map_error(string.inspect)
}
```

How it works:

- `recorder.start` checks the settings. A missing directory or name is an `Error` with a message that says what to fix. A wrong mode name does not compile.
- `recorder.connect` takes a `Config`. In record and passthrough mode it starts the pool with `client.connect`. In playback mode it starts no pool and opens no connection: the config isn't used, so the database doesn't have to exist.
- To read the mode from an environment variable, such as `RECORD_QUERIES=record`, use `recorder.parse_mode`. It accepts `"record"`, `"playback"` and `"passthrough"`, and gives an `Error` that names any other text.

## Step 3: Record once against the real database

`run_recorded` runs the code under test with a recorder in a mode, and stops the recorder:

### Run the code under test with a recorder <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam#L20-L31"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn run_recorded(
  mode: recorder.Mode,
  database_url: String,
  directory: String,
) -> Result(User, String) {
  use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
  use db <- result.try(connect(recording, database_url))
  let user = create_and_find(db) |> result.map_error(string.inspect)
  // In record mode, each query was on disk when it returned
  use Nil <- result.try(recorder.stop(recording))
  user
}
```

With the users table in place, record once:

### Recorded against PostgreSQL 16 <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_record.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
run_recorded(recorder.Record, database_url, "test/fixtures/recordings")
  -> Ok(User(1, "Ada", "ada@example.com"))
```

The queries ran on the real database, and `create_and_find` got the live answers. The recorder also wrote `test/fixtures/recordings/create_and_find.json`:

### The recording file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_file.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
{
  "format": "dream_postgres query recording",
  "version": 1,
  "queries": [
    {
      "sql": "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
      "parameters": ["Ada","ada@example.com"],
      "result": {
        "count": 1,
        "rows": [
          {"tuple":[1]}
        ]
      }
    },
    {
      "sql": "SELECT id, name, email FROM users WHERE id = $1",
      "parameters": [1],
      "result": {
        "count": 1,
        "rows": [
          {"tuple":[1,"Ada","ada@example.com"]}
        ]
      }
    }
  ]
}
```

Each query has its SQL, its parameters and its result: the row count and the rows, or the error. Each parameter list and each row is on one line, and the keys always come in the same order. So a diff of two recordings shows only what changed. A row is `{"tuple":[...]}`, because the driver gives each row as a tuple. [The `recording` module](https://hexdocs.pm/dream_postgres/dream_postgres/recording.html) documents the format, with version 1, for every kind of value.

A recorded query returns only when its recording is on disk. You can read the file, or start a playback recorder on it, right after the query. `recorder.start` in record mode writes a file with no queries at once, so a file never keeps the queries of an earlier run.

## Step 4: Play it back with no database

Now the same function in `Playback` mode, with a URL where nothing listens:

### Played back with no database <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_playback.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
run_recorded(recorder.Playback, "postgresql://app:secret@127.0.0.1:1/app", "test/fixtures/recordings")
  -> Ok(User(1, "Ada", "ada@example.com"))

create_and_find(a pool with no database)
  -> Error(ConnectionUnavailable)
```

With the recorder, `create_and_find` gets the recorded answers, although nothing listens at the URL. Without it, the same function can't connect. The package's tests run this playback with both test servers stopped, to prove that playback never connects.

A query in `dream_postgres_client.transaction` is recorded and played back the same way. In playback mode, a callback that returns `Error` gives `TransactionRolledBack`, as it did live.

## Step 5: Read a query with no recording

In playback mode, a query with no recording never reaches a database. It fails, and the error names the query and the recordings nearest to it. A `find_user` for id 2, which the recording doesn't have:

### A query with no recording <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_miss.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
find_user(db, 2) |> result.map_error(recorder.error)
  -> Error(Ok(NoRecording("SELECT id, name, email FROM users WHERE id = $1", "[2]", "test/fixtures/recordings/create_and_find.json", [NearestRecording(2, "[1]", "[2]")])))
```

The query error is `dream_postgres_client.InterceptorFailed`. `recorder.error` reads the `recorder.RecorderError` back from it: `NoRecording(sql:, parameters:, path:, nearest:)` names the SQL, the parameters, the file and the nearest recordings. `recorder.describe_error` writes it as text. The `-` line is the parameters of the recording, and the `+` line is the parameters of the query:

### The text of a query with no recording <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_miss_text.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
No recording matches SELECT id, name, email FROM users WHERE id = $1 with [2]
Nearest recording in test/fixtures/recordings/create_and_find.json:
  parameters:
  - [1]
  + [2]
```

How the recorder finds the nearest recordings:

- A candidate is a recording that the key would match if the query had the recording's parameters. With `sql_and_parameters` it has the same SQL. With `normalized_sql_and_parameters` it has the same SQL apart from whitespace.
- The recorder compares the query after the query transformer, so a value that the transformer hides never shows.
- The nearest candidates have the fewest parameters that differ. A value that one list has and the other has not counts too. Candidates with the same count are in file order.
- A recording with the same parameters as a nearer one is left out. The error holds at most 3 candidates. The first shows as `Nearest recording in`, and the others as `Next nearest recording in`.
- `NearestRecording(position:, recorded:, requested:)` gives the place of the recording in the file (1 for the first), its parameters, and the parameters of the query. For any other query error, `recorder.error` gives `Error(Nil)`. When the same query ran more times than the recording has results for it, the error is `PlayedAlready(sql:, parameters:, path:)`, and `describe_error` writes `Each recording of <sql> with <parameters> in <path> was played already`.

That's the error you see when a test runs a query you never recorded, or a query that changed since you recorded it. Record again, or fix the test.

## Step 6: Keep a secret out of the file

A recording file goes into your repository, so it must not hold a secret. Here a `sessions` table holds a token. The query transformer hides the token in the parameters of the `INSERT`, and the result transformer hides it in the rows of the `SELECT`:

### Hide a secret before it reaches the file <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/recorder_scrub.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/recorder
import dream_postgres/recording.{
  type RecordedQuery, type RecordedResult, RecordedQuery, Returned, Text, Tuple,
}
import dream_postgres_client
import gleam/dynamic/decode
import gleam/list
import gleam/result

const insert_session = "INSERT INTO sessions (user_name, token) VALUES ($1, $2)"

const select_tokens = "SELECT token FROM sessions WHERE user_name = $1"

pub fn find_tokens(
  db: dream_postgres_client.Connection,
  user_name: String,
) -> Result(List(String), dream_postgres_client.QueryError) {
  dream_postgres_client.query(select_tokens)
  |> dream_postgres_client.parameter(dream_postgres_client.text(user_name))
  |> dream_postgres_client.returning(decode.at([0], decode.string))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

pub fn scrubbing_builder(
  directory: String,
  name: String,
) -> recorder.RecorderBuilder {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(name)
  |> recorder.query_transformer(hide_token_parameter)
  |> recorder.result_transformer(hide_token_column)
}

// Runs in record and in playback mode, so a played-back INSERT with the
// real token still matches its recording.
fn hide_token_parameter(query: RecordedQuery) -> RecordedQuery {
  case query.sql, query.parameters {
    sql, [user_name, _token] if sql == insert_session ->
      RecordedQuery(..query, parameters: [user_name, Text("[hidden]")])
    _, _ -> query
  }
}

// Runs in record mode only: playback gives the hidden rows.
fn hide_token_column(
  query: RecordedQuery,
  result: RecordedResult,
) -> RecordedResult {
  case query.sql, result {
    sql, Returned(count:, rows:) if sql == select_tokens ->
      Returned(
        count:,
        rows: list.map(rows, fn(_row) { Tuple([Text("[hidden]")]) }),
      )
    _, _ -> result
  }
}
```

Recorded with this builder, the file holds `[hidden]` in place of the token:

### The recording file with the token hidden <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_scrubbed.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
{
  "format": "dream_postgres query recording",
  "version": 1,
  "queries": [
    {
      "sql": "CREATE TABLE sessions (user_name text, token text)",
      "parameters": [],
      "result": {
        "count": 0,
        "rows": []
      }
    },
    {
      "sql": "INSERT INTO sessions (user_name, token) VALUES ($1, $2)",
      "parameters": ["ada","[hidden]"],
      "result": {
        "count": 1,
        "rows": []
      }
    },
    {
      "sql": "SELECT token FROM sessions WHERE user_name = $1",
      "parameters": ["ada"],
      "result": {
        "count": 1,
        "rows": [
          {"tuple":["[hidden]"]}
        ]
      }
    }
  ]
}
```

How it works:

- The query transformer runs in record mode and in playback mode, before the recorder computes the key of the query. In playback, the `INSERT` with the real token becomes the `INSERT` with `[hidden]`, so it still matches its recording.
- The result transformer runs in record mode only, before the recorder writes the result. Playback then gives the hidden rows: `find_tokens` returns `Ok(["[hidden]"])`. While it records, the test still gets the real token.
- The values are `recording.RecordedValue`s: a row is a `Tuple` of its columns, and text is `Text`.

## Step 7: Record again after a query changes

Say `find_user` gets a `LIMIT 1`:

### find_user with new SQL <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_changed.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres_client
import gleam/dynamic/decode
import gleam/result
import snippets/guide_recording_users.{type User, User}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(List(User), dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "SELECT id, name, email FROM users WHERE id = $1 LIMIT 1",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning({
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(User(id:, name:, email:))
  })
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}
```

The recording has the old SQL, so playback can't answer the new query:

### A changed query in playback <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_changed.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
find_user(db, 1) |> result.map_error(recorder.error)
  -> Error(Ok(NoRecording("SELECT id, name, email FROM users WHERE id = $1 LIMIT 1", "[1]", "test/fixtures/recordings/create_and_find.json", [])))
```

No recording has the new SQL, so `nearest` is empty, and the text names the file that the recorder searched:

### The text of a changed query <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/outputs/guide_recording_changed_text.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
No recording matches SELECT id, name, email FROM users WHERE id = $1 LIMIT 1 with [1]
No recording in test/fixtures/recordings/create_and_find.json has this SQL
```

Run the test once in `Record` mode against the database, as in Step 3. The recorder writes the file again, with the new SQL. Then switch back to `Playback` and commit the new file. The diff shows exactly the changed SQL.

## How a query finds its recording

In playback mode, each query gets the first recording that it was not given yet whose key is the same as its own. So:

- The same query run two times gets its two results in recorded order. A count before an `INSERT` and a count after it give the two counts.
- Different queries can run in another order than when they were recorded, for example from two processes at the same time. Each gets its own recording. The match decides, and the order only decides between recordings with the same key.

The key is the text two queries must share to match. Pick it with `recorder.key`:

| Key | Matches when | Use it when |
|:---|:---|:---|
| `recorder.sql_and_parameters` (the default) | The SQL is the same, character for character, and so is each parameter. | Almost always. |
| `recorder.normalized_sql_and_parameters` | The SQL is the same after each run of whitespace outside quotes becomes one space, and each parameter is the same. | You format your SQL and don't want a new line break to need a new recording. |
| `recorder.sql_only` | The SQL is the same, whatever the parameters. | A parameter changes on each run, such as a time, and it doesn't change the answer. |
| your own `fn(RecordedQuery) -> String` | Your function gives the same text. | You want to ignore one parameter but keep the others. |

The key also decides the nearest recordings of a miss: a recording is a candidate when the key would match it if the query had the recording's parameters. With `sql_only`, a query with recorded SQL always matches, so a miss of it has no candidate.

## Test your code

The usual setup: commit the recordings to your repository, and play them back in your tests. This package has `test/fixtures/recordings/create_and_find.json` from Step 3. Here's a test of `create_and_find` that plays it back:

### Test create_and_find with a committed recording <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_testing.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/guide_recording_round_trip.{run_recorded}
import snippets/guide_recording_users.{User}

const recordings = "test/fixtures/recordings"

const no_database = "postgresql://app:secret@127.0.0.1:1/app"

pub fn tests() -> TestSuite {
  describe("create_and_find", [
    it("creates Ada and finds her", fn() {
      // Act
      let user = run_recorded(recorder.Playback, no_database, recordings)

      // Assert
      user
      |> should
      |> be_equal(Ok(User(id: 1, name: "Ada", email: "ada@example.com")))
      |> or_fail_with("Expected Ada from the recording")
    }),
  ])
}
```

The test passes with no database on the machine. The URL points at port 1 of `127.0.0.1`, where nothing listens, and playback never uses it.

## Common pitfalls

**A query that changed since the recording.** *Symptom:* playback fails, and `recorder.error` gives `Ok(NoRecording(sql:, parameters:, path:, nearest:))`. *Fix:* `recorder.describe_error` shows the SQL and the parameters the test sent, and the nearest recordings with their parameters. When no recording has the SQL, the SQL changed. Record again, as Step 7 shows.

**A test that runs a query more often than when it recorded.** *Symptom:* `recorder.error` gives `Ok(PlayedAlready(...))`. *Fix:* each recording answers one query. Record again, so the file has a result for each run of the query.

**A secret in a committed recording.** *Symptom:* a token or a password shows up in a recording file. *Fix:* record with a query transformer and a result transformer that hide it, as Step 6 shows. Then delete the old file from the repository history.

**A file that can't be written.** *Symptom:* `recorder.start` in record mode returns `Error("<directory>/<name>.json: permission denied")`, or a query fails and `recorder.error` gives `Ok(WriteFailed(path:, reason: "permission denied"))`. *Fix:* the query ran on the database, but the recorder could not write its recording, so the query fails. Make sure the directory can be written.

**A value that changes on each run.** *Symptom:* a new recording differs from the old one in a timestamp or a generated id. *Fix:* that's real: the database gave another value. Hide it with a result transformer if the test doesn't need it, or set it in the test data.

## Where to go next

- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md): turn the results that playback gives into responses.
- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#test-your-code): set up dream_test.
- [API reference on HexDocs](https://hexdocs.pm/dream_postgres/dream_postgres/recorder.html): `recorder` and `recording`.
