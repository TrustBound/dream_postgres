# Test database code with recorded queries

A recorder records the requests of a test and the answers of PostgreSQL to one JSON file. In a later run, it plays the file back, and the test runs with no database. This guide shows how to record a test, play it back, keep secrets and random values out of the file, and read the file. Each code block is a file that the tests of this package run against PostgreSQL.

## Table of Contents

- [The four modes](#the-four-modes)
- [The config of the app](#the-config-of-the-app)
- [The code under test](#the-code-under-test)
- [Start a recorder](#start-a-recorder)
- [Record, then play back](#record-then-play-back)
- [How a request finds its answer](#how-a-request-finds-its-answer)
- [Values that change in each run](#values-that-change-in-each-run)
- [Secrets](#secrets)
- [Secret parameters](#secret-parameters)
- [A request with no answer](#a-request-with-no-answer)
- [The recording file](#the-recording-file)
- [What a recording does not hold](#what-a-recording-does-not-hold)
- [When a recorder fails](#when-a-recorder-fails)
- [Where to go next](#where-to-go-next)

## The four modes

| Mode | The connection | The file |
|---|---|---|
| `recorder.Record` | a live pool of the config, with the recorder after all other interceptors | written new at the start, then each request and its answer before the answer returns |
| `recorder.Playback` | no pool starts and nothing connects: after the interceptors of the config, the recording answers each request | read at the start. A missing file fails `recorder.start_recorder` with `RecordingNotFound` |
| `recorder.RecordMissing` | `Playback` when the file exists, else `Record` | read, or written |
| `recorder.Passthrough` | a live pool of the config | not read and not written |

The code under test is the same in each mode. The recorded cells go through the same codecs and the same checks as live ones, and a server error in the recording plays back as the same typed error.

## The config of the app

The app and its tests share one config. It holds the interceptors of the app and its secrets:

### Declare the secrets of the app <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/app_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codec.{text}
import dream_postgres/config.{type Config, intercept, set_secrets}
import dream_postgres/secrets.{secrets}
import snippets/request_tagging.{tag_with_app_name}

/// The config of the app, shared by the app and its tests. `server` holds
/// the settings of the server of each run.
pub fn app_config(server: Config) -> Config {
  server
  |> intercept(tag_with_app_name)
  |> set_secrets(
    secrets()
    |> secrets.text("sk_live_", with: "sk_test_")
    |> secrets.column("token", text, with: "token-redacted"),
  )
}
```

## The code under test

This function creates an API key, then reads it back by the id that the database made:

### Create an API key and read it back <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/create_api_key.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int, text, timestamp_with_time_zone, uuid}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query, secret_parameter}
import dream_postgres/row.{type Row, column, row}
import dream_uuid.{type Uuid}
import gleam/result
import gleam/time/timestamp.{type Timestamp}

pub type ApiKey {
  ApiKey(id: Uuid, owner: Int, token: String, created_at: Timestamp)
}

fn api_key_row() -> Row(ApiKey) {
  use id <- column(uuid)
  use owner <- column(int)
  use token <- column(text)
  use created_at <- column(timestamp_with_time_zone)
  row(ApiKey(id:, owner:, token:, created_at:))
}

/// The code under test: it creates an API key for the owner, then reads
/// it back by the id that the database made.
pub fn create_api_key(
  connection: Connection,
  owner: Int,
  password: String,
) -> Result(ApiKey, Error(PostgresError)) {
  use created <- result.try(
    "INSERT INTO api_keys (owner, token, password_hash)
VALUES ($1, 'sk_live_' || md5(random()::text), md5($2))
RETURNING id, owner, token, created_at"
    |> query
    |> named("api_key.create")
    |> parameter(int, owner)
    |> secret_parameter(text, password)
    |> one(api_key_row(), connection),
  )
  "SELECT id, owner, token, created_at FROM api_keys WHERE id = $1"
  |> query
  |> named("api_key.find")
  |> parameter(uuid, created.id)
  |> one(api_key_row(), connection)
}
```

The database makes the id with `gen_random_uuid()` and the time with `now()`, so both change in each run. The id of the answer goes into the parameter of the next query.

## Start a recorder

`recorder.recorder` takes the path of the recording file. There is no default path. The test gives the mode, which it reads from its own config:

### Start the recorder of one test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/normalize.{generated_uuids, timestamps_near_now}
import dream_postgres/recorder.{
  type Mode, type Recorder, intercept, match_on, mode, recorder,
  sql_and_parameters, start_recorder,
}

/// Starts the recorder of the test that creates an API key. The test
/// gives the mode, which it reads from its own config.
pub fn start_api_key_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  recorder(file: "test/recordings/api_key_create.json")
  |> mode(recorder_mode)
  |> match_on(sql_and_parameters)
  |> intercept(generated_uuids(keep: []))
  |> intercept(timestamps_near_now(window_days: 400))
  |> start_recorder
}
```

`recorder.start_recorder` fails with `Error(PostgresError)`, the same type as `pool.start_pool`. The recorder stops when its connection stops, or when the process that started it ends.

## Record, then play back

`config.record` attaches the recorder to the config. Then `pool.start_pool` makes the connection of the mode:

### Run the test in either mode <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/run_create_api_key.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{type Config, record}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{start_pool, stop_pool}
import dream_postgres/recorder.{type Recorder}
import gleam/result
import snippets/app_config.{app_config}
import snippets/create_api_key.{type ApiKey, create_api_key}
import snippets/with_api_keys_table.{with_api_keys_table}

/// One run of the test: in `Record` mode on the database of the app
/// config, in `Playback` mode on the recording alone.
pub fn run_create_api_key(
  server: Config,
  test_recorder: Recorder,
  owner: Int,
) -> Result(ApiKey, Error(PostgresError)) {
  use connection <- result.try(
    app_config(server)
    |> record(test_recorder)
    |> start_pool,
  )
  let created =
    with_api_keys_table(connection, create_api_key(_, owner, "s3cret"))
  stop_pool(connection)
  created
}
```

`with_api_keys_table` holds one connection with a temporary table, so the test leaves no table on the server:

### Hold one connection with a temporary table <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/with_api_keys_table.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, with_connection}
import dream_postgres/query.{run_sql}
import gleam/result

/// Runs the work on one connection that has a temporary table `api_keys`,
/// so the test leaves no table on the server.
pub fn with_api_keys_table(
  connection: Connection,
  work: fn(Connection) -> Result(a, Error(PostgresError)),
) -> Result(a, Error(PostgresError)) {
  {
    use held <- with_connection(connection)
    use Nil <- result.try(run_sql(
      "CREATE TEMPORARY TABLE api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner int4 NOT NULL,
  token text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
)",
      held,
    ))
    work(held)
  }
  |> result.flatten
}
```

The test of this guide plays back `test/recordings/api_key_create.json` with the port of the config set to 1, where no server listens. It gets the key with the id `deadbeef-dead-4eef-8ead-beef00000001`.

To play back in CI, commit the recording file with the test. To record again, for example after a query changed, run the test one time in `Record` mode against a database.

`pool.supervised` takes a recorder in each mode. In `Playback` mode the pool under the name has no database: it starts no connection and dials nothing, and `named_connection` answers from the recording. After the supervisor starts the pool again, the same name answers the next recorded request:

### Play back under a supervisor <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_app_supervisor.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/config.{type Config, record}
import dream_postgres/error.{describe_error}
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
    |> result.map_error(describe_error),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}
```

## How a request finds its answer

Playback follows the recorded order. At each request, the recorder makes the key of the request with the function of `recorder.match_on`, and compares it with the key of the next recorded request. The keys are:

| Key | What counts |
|---|---|
| `match.sql_and_parameters`, the default | the kind, the SQL, and each written parameter, or each written row of `copy_from` |
| `match.sql_only` | the kind and the SQL |
| a function of the app, `fn(Request) -> String` | what the function reads, for example the name of the query |

### Match on the SQL only <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_sql_only_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/recorder.{
  type Mode, type Recorder, match_on, mode, recorder, sql_only, start_recorder,
}

/// A recorder that takes any parameters of the recorded SQL, for a test
/// whose parameters change in each run.
pub fn start_sql_only_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  recorder(file: "test/recordings/api_key_list.json")
  |> mode(recorder_mode)
  |> match_on(sql_only)
  |> start_recorder
}
```

A request with another key fails with `RequestNotMatched`, which names the SQL of the next recorded request and the SQL of the request. The recording does not move on, so the same query in another order fails too.

The recorder saves the key with each request. Record and play back with the same `match_on`.

## Values that change in each run

`recorder.intercept` adds an interceptor that runs only on the copy that the recorder keeps. In `Record` mode it changes what the recorder saves: the request and the answer. In `Playback` mode it changes the request before its key is made, and the app gets the saved answer. The database and the app never see these changes in `Record` mode.

`dream_postgres/recorder/normalize` has two of them:

| Interceptor | What it changes |
|---|---|
| `normalize.generated_uuids(keep:)` | each UUID to a placeholder: `deadbeef-dead-4eef-8ead-beef00000001` for the first UUID it sees, then `...00000002`. The same UUID gets the same placeholder as 16 bytes of a `uuid` cell and as text in a text cell, in JSON or in SQL. The UUIDs of `keep` do not change |
| `normalize.timestamps_near_now(window_days:)` | each `timestamp` and `timestamptz` within the window of now, to 2024-01-01 00:00:00 UTC |

Each recording starts with no UUID known. A placeholder does not change, so the placeholder that playback gives the app can go back in a parameter. Two record runs of the API key test write the same bytes.

## Secrets

`config.set_secrets` declares the secrets of the config one time. They apply to each copy of a request that leaves the process:

| Secret | The recording | `PostgresError.sql` | The text of the trace span |
|---|---|---|---|
| `secrets.text(secret, with:)` | the SQL of each request | yes | yes |
| `secrets.column(name, codec, with:)` | the value of the column in each saved row. A NULL stays NULL | no | no |

The database and the app always get the real values. The recorder reads the secrets of the config that it is attached to, and applies them before its own interceptors. When no pool runs under the name of a `named_connection`, the secrets of that pool are not known, so its error holds no SQL.

## Secret parameters

A parameter of `secret_parameter` goes to the database in record mode as any other parameter, but the recorder does not save its value. The file holds `{"secret":{"codec":"text"}}` in place of the hex of the cell: the name of the codec and no bytes.

In playback, a secret parameter matches any value with the same codec at the same position. The other parameters of the request must still be the same. So a test can record with one password and play back with another, and the answer is the recorded one. A parameter of `parameter` does not match a recorded secret parameter, so a query that changes to `secret_parameter` needs a new recording.

### A query with a secret password <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/password_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{bool, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query, secret_parameter}
import dream_postgres/row.{single}

/// Checks a password against its stored SHA-256 hash in hex. The password
/// is a secret parameter, so a recording of this query never holds it.
pub fn password_matches(
  connection: Connection,
  password: String,
  stored_hash: String,
) -> Result(Bool, Error(PostgresError)) {
  "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
  |> query
  |> named("password.matches")
  |> secret_parameter(text, password)
  |> parameter(text, stored_hash)
  |> one(single(bool), connection)
}
```

## A request with no answer

A request after the last recorded request fails with `RequestNotRecorded`, of the kind `Failed`. Its message names the SQL, for example `the recording has no answer to the request: SELECT 1`. The request never reaches a database.

A request after the connection stopped fails with `RecorderStopped`, of the kind `Unavailable`.

`verify_queries` on a playback connection fails with `NoDatabaseToVerify`, because a recording has no schema to check. The [boot check guide](boot-check.md) shows `verify_queries`.

## The recording file

A recording is a JSON file. Its text is the same for the same requests and answers:

- The keys of each object are in alphabetical order.
- It holds no time.
- Each request is on its own line with its key, in the order that the answers came.
- Each cell is hex: exactly the bytes that went over the wire.
- With each request are the types that its codecs need, so playback checks the codecs as a live run does.

This recording holds one `BEGIN`:

### A recording of one BEGIN <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/begin_recording.json"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```json
{
  "dream_postgres_recording": 1,
  "entries": [
    {"key":"sql\nBEGIN","sql":{"outcome":{"answer":{"results":[{"count":0,"rows":[],"tag":"BEGIN"}]}},"sql":"BEGIN"}}
  ]
}
```

The number `dream_postgres_recording` is the format of the file. A file of another format does not load. `dream_postgres/recording` has the types of the file, and `recording.parse_recording` and `recording.format_recording` read and write it.

## What a recording does not hold

- A recording holds only what PostgreSQL answered. A request that failed in the client before the database answered is not recorded. A failure of the client, such as a codec that does not take the type of its column, comes again in playback from the recorded types.
- The only failures in a recording are server errors: `error.Server`, and `error.SqlStatementFailed` for a `run_sql` call.
- A listener has a connection of its own, outside the recorder. Its notifications are not recorded.
- The file holds the value of each parameter of `parameter`, as hex. Add a secret with `secret_parameter`, and the file holds only its codec.

## When a recorder fails

`recorder.start_recorder` fails with one of these reasons of `dream_postgres/error`:

| Reason | When |
|---|---|
| `RecordingInUse(path)` | another recorder that runs holds the file. Each file has one recorder at a time |
| `RecordingNotFound(path)` | playback mode found no file |
| `RecordingNotRead(path, reason)` | the file could not be read |
| `RecordingNotDecoded(path, reason)` | the file is not a recording of this format |
| `RecordingNotWritten(path, reason)` | record mode could not write the file |
| `RecorderNotStarted(reason)` | the process of the recorder did not start |

During a run, a request fails with `RecordingNotWritten` when record mode cannot write the file, and with `SecretColumnNotReplaced` when the codec of `secrets.column` cannot write the replacement value.

## Where to go next

- [Interceptors](interceptors.md): answer one request in a test with no recording
- [Upgrading to 3.0](upgrading-to-3.md): the recorder of 2.x and the one of 3.0
