//// The scenarios of the recorder tests: each one is code under test that
//// takes a connection, as an app's code does. `record_all` records each
//// one against PostgreSQL 16 into a directory under `build`, and the
//// tests play them back with no database. `remove` deletes the directory.

import dream_errors.{type Error}
import dream_postgres/codecs
import dream_postgres/codecs/array
import dream_postgres/config.{type Config}
import dream_postgres/copy.{copy_from, copy_to, table}
import dream_postgres/error.{type PostgresError}
import dream_postgres/interceptor.{type Request, SqlAnswer}
import dream_postgres/pool.{type Connection, type PoolName, with_connection}
import dream_postgres/query.{
  affected, all, maybe_one, named, one, parameter, query, run_sql,
}
import dream_postgres/recorder.{type Recorder, type RecorderBuilder}
import dream_postgres/recorder/match
import dream_postgres/recorder/normalize
import dream_postgres/row.{single}
import dream_postgres/transaction.{commit, keep_both, run, step, transaction}
import dream_uuid
import fixtures/copy_users
import fixtures/interceptors
import fixtures/recording_paths
import fixtures/server_pools
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import simplifile
import snippets/app_config
import snippets/create_api_key.{create_api_key}
import snippets/password_check.{password_matches}

/// What a scenario gives: its value as text, or its error.
pub type ScenarioResult =
  Result(String, Error(PostgresError))

/// A scenario: the name of its recording, its code, the settings of its
/// recorder, and the settings of its app config.
pub type Scenario {
  Scenario(
    name: String,
    run: fn(Connection) -> ScenarioResult,
    recorder_settings: fn(RecorderBuilder) -> RecorderBuilder,
    app_settings: fn(Config) -> Config,
  )
}

/// The directory of the recordings, after `record_all`.
pub type RecordedRuns {
  RecordedRuns(directory: String)
}

/// The directory that `record_all` writes and `remove` deletes.
pub const directory = "build/recorder_test_recordings"

/// The port of the PostgreSQL 16 test server.
pub const server_port = 5441

/// A port where no server listens: a playback connection with it proves
/// that playback never connects.
pub const closed_port = 1

/// Records each scenario into `<directory>/first`, and the scenarios
/// `identical` and `api_key` a second time into `<directory>/second`.
///
/// ## Example
///
/// ```gleam
/// context.setup(recorded_scenarios.record_all, teardown: recorded_scenarios.remove)
/// ```
pub fn record_all() -> Result(RecordedRuns, String) {
  use Nil <- result.try(on_server(
    "DROP TABLE IF EXISTS api_keys; CREATE TABLE api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner int4 NOT NULL,
  token text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
)",
  ))
  let recorded = {
    use Nil <- result.try(
      list.try_each(scenarios(), record(_, directory <> "/first")),
    )
    list.try_each([identical(), api_key()], record(_, directory <> "/second"))
  }
  use Nil <- result.try(on_server("DROP TABLE api_keys"))
  recorded |> result.replace(RecordedRuns(directory:))
}

// Runs a `run_sql` call on the test server, on a pool of its own.
fn on_server(sql: String) -> Result(Nil, String) {
  use connection <- result.try(
    server_pools.config(server_port)
    |> pool.start
    |> result.map_error(string.inspect),
  )
  let ran = run_sql(sql, connection) |> result.map_error(string.inspect)
  pool.stop(connection)
  ran
}

/// Deletes the directory of the recordings.
///
/// ## Example
///
/// ```gleam
/// context.setup(recorded_scenarios.record_all, teardown: recorded_scenarios.remove)
/// ```
pub fn remove(runs: RecordedRuns) -> Result(Nil, String) {
  simplifile.delete(runs.directory) |> result.map_error(string.inspect)
}

/// The path of the recording of a scenario in the first run.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.first_path(runs, "all")
/// // -> "build/recorder_test_recordings/first/all.json"
/// ```
pub fn first_path(runs: RecordedRuns, recording: String) -> String {
  runs.directory <> "/first/" <> recording <> ".json"
}

/// A copy of the recording of a scenario in the first run, at a path that
/// no other call gives, so tests that run at the same time each play
/// their own file.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.copy_of(runs, "all")
/// // -> Ok("build/recorder_test_recordings/played/all_2F2F...json")
/// ```
pub fn copy_of(
  runs: RecordedRuns,
  recording: String,
) -> Result(String, String) {
  let path =
    recording_paths.unique(in: runs.directory <> "/played", name: recording)
  use Nil <- result.try(
    simplifile.create_directory_all(runs.directory <> "/played")
    |> result.map_error(string.inspect),
  )
  simplifile.copy_file(first_path(runs, recording), path)
  |> result.replace(path)
  |> result.map_error(string.inspect)
}

/// A path for a new recording in the directory of the runs, that no other
/// call gives.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.new_path(runs, "passthrough")
/// // -> "build/recorder_test_recordings/new/passthrough_2F2F...json"
/// ```
pub fn new_path(runs: RecordedRuns, name: String) -> String {
  recording_paths.unique(in: runs.directory <> "/new", name:)
}

/// Starts a supervisor with a pool under `pool_name`, whose config has a
/// recorder in `Playback` mode on a copy of the recording. The port of
/// the config has no server.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.start_supervised_playback(runs, "all", pool_name)
/// ```
pub fn start_supervised_playback(
  runs: RecordedRuns,
  recording: String,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  let settings = scenario_of(recording)
  use path <- result.try(copy_of(runs, recording))
  use test_recorder <- result.try(
    recorder.new(file: path)
    |> settings.recorder_settings
    |> recorder.start
    |> result.map_error(string.inspect),
  )
  use pool_child <- result.try(
    server_pools.config(closed_port)
    |> settings.app_settings
    |> config.record(test_recorder)
    |> pool.supervised(name: pool_name)
    |> result.map_error(string.inspect),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}

/// Starts a recorder on the path in a new process that then ends, and
/// waits for that process to end.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.start_in_ended_process(path)
/// ```
pub fn start_in_ended_process(path: String) -> Nil {
  let owner =
    process.spawn_unlinked(fn() {
      let _started =
        recorder.new(file: path)
        |> recorder.mode(recorder.Passthrough)
        |> recorder.start
      Nil
    })
  let owner_monitor = process.monitor(owner)
  process.new_selector()
  |> process.select_specific_monitor(owner_monitor, fn(_down) { Nil })
  |> process.selector_receive_forever
}

/// Starts a recorder on the path in `Passthrough` mode, and tries again
/// every 10 milliseconds, up to `attempts` times, while another recorder
/// holds the path.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.start_when_free(path, attempts: 100)
/// ```
pub fn start_when_free(
  path: String,
  attempts attempts: Int,
) -> Result(Recorder, Error(PostgresError)) {
  let started =
    recorder.new(file: path)
    |> recorder.mode(recorder.Passthrough)
    |> recorder.start
  case started, attempts > 1 {
    Ok(test_recorder), _ -> Ok(test_recorder)
    Error(failure), False -> Error(failure)
    Error(_held), True -> {
      process.sleep(10)
      start_when_free(path, attempts: attempts - 1)
    }
  }
}

// Records one scenario. Its result is not checked here: the tests check
// what playback gives.
fn record(scenario: Scenario, into: String) -> Result(Nil, String) {
  use test_recorder <- result.try(
    recorder.new(file: into <> "/" <> scenario.name <> ".json")
    |> recorder.mode(recorder.Record)
    |> scenario.recorder_settings
    |> recorder.start
    |> result.map_error(string.inspect),
  )
  use connection <- result.try(
    server_pools.config(server_port)
    |> scenario.app_settings
    |> config.record(test_recorder)
    |> pool.start
    |> result.map_error(string.inspect),
  )
  let _recorded_result = scenario.run(connection)
  pool.stop(connection)
  Ok(Nil)
}

/// The settings of the recorder of most scenarios: the default key, and
/// both normalizers.
///
/// ## Example
///
/// ```gleam
/// recorder.new(file: path) |> recorded_scenarios.normalized
/// ```
pub fn normalized(builder: RecorderBuilder) -> RecorderBuilder {
  builder
  |> recorder.intercept(normalize.generated_uuids(keep: []))
  |> recorder.intercept(normalize.timestamps_near_now(window_days: 400))
}

/// The key of a request by its name, or its SQL when it has no name: an
/// app's own key for `recorder.match_on`.
///
/// ## Example
///
/// ```gleam
/// recorder.new(file: path) |> recorder.match_on(recorded_scenarios.name_key)
/// ```
pub fn name_key(request: Request) -> String {
  option.unwrap(request.name, request.sql)
}

/// The scenario of the recording, or a scenario that records nothing
/// with the default settings.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.scenario_of("all").recorder_settings
/// ```
pub fn scenario_of(recording: String) -> Scenario {
  scenarios()
  |> list.find(fn(scenario) { scenario.name == recording })
  |> result.unwrap(scenario(recording, fn(_connection) { Ok("") }))
}

fn scenario(name: String, run: fn(Connection) -> ScenarioResult) -> Scenario {
  Scenario(
    name:,
    run:,
    recorder_settings: normalized,
    app_settings: function.identity,
  )
}

/// Every scenario, by the name of its recording.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.scenarios()
/// ```
pub fn scenarios() -> List(Scenario) {
  [
    scenario("all", select_series),
    scenario("two_parameters", select_two_series),
    scenario("one", count_array),
    scenario("maybe_one", select_nothing),
    scenario("affected", update_rows),
    scenario("run_sql", run_two_statements),
    scenario("run_sql_failure", run_failing_sql),
    scenario("transaction", count_in_transaction),
    scenario("rolled_back", commit_after_conflict),
    scenario("copy_from", store_users),
    scenario("copy_from_refused", store_into_missing_table),
    scenario("copy_to", read_series),
    scenario("copy_to_failure", read_series_divided_by_zero),
    scenario("copy_to_refused", read_missing_column),
    scenario("copy_to_unexpected_null", read_null),
    scenario("conflict", insert_twice),
    scenario("statement_refused", select_missing_column),
    scenario("parameter_mismatch", count_with_text),
    scenario("secret", check_password),
    Scenario(
      ..scenario("series_sql_only", select_series),
      recorder_settings: recorder.match_on(_, match.sql_only),
    ),
    Scenario(
      ..scenario("named_key", check_password),
      recorder_settings: recorder.match_on(_, name_key),
    ),
    Scenario(
      ..scenario("other_kind", select_series),
      recorder_settings: recorder.intercept(
        _,
        interceptors.answer_with(Ok(SqlAnswer(results: []))),
      ),
    ),
    identical(),
    api_key(),
  ]
}

/// The scenario of the API key snippet, with the secrets of the app
/// config: its UUID goes from the answer of the insert into the parameter
/// of the next query. Its table `api_keys` is a table of `record_all`, so
/// the table ID of each column is the same in both runs.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.api_key()
/// ```
pub fn api_key() -> Scenario {
  Scenario(
    ..scenario("api_key", fn(connection) {
      create_api_key(connection, 7, "s3cret")
      |> result.map(fn(created) {
        dream_uuid.to_string(created.id)
        <> " "
        <> created.token
        <> " "
        <> timestamp.to_rfc3339(created.created_at, duration.seconds(0))
      })
    }),
    app_settings: app_config.app_config,
  )
}

/// A query whose column `token` holds a secret.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.read_token(connection)
/// ```
pub fn read_token(connection: Connection) -> ScenarioResult {
  query("SELECT 'sk_live_abc' AS token")
  |> one(single(codecs.text), connection)
  |> inspected
}

/// The scenario that is recorded two times, to compare the files: it
/// makes no table, so each run gives the same answers.
///
/// ## Example
///
/// ```gleam
/// recorded_scenarios.identical()
/// ```
pub fn identical() -> Scenario {
  scenario("identical", fn(connection) {
    use series <- result.try(select_series(connection))
    use counted <- result.try(count_array(connection))
    use streamed <- result.try(read_series(connection))
    use Nil <- result.try(run_sql("SELECT 1; SELECT 'two'", connection))
    Ok(series <> counted <> streamed)
  })
}

/// `all` of `generate_series(1, 3)`.
///
/// ## Example
///
/// ```gleam
/// select_series(connection)
/// // -> Ok("[1, 2, 3]")
/// ```
pub fn select_series(connection: Connection) -> ScenarioResult {
  series_query(3) |> all(single(codecs.int), connection) |> inspected
}

/// `select_series` two times: one request more than the recording
/// `all` has.
///
/// ## Example
///
/// ```gleam
/// select_series_twice(connection)
/// // -> Error(RequestNotRecorded) in playback of "all"
/// ```
pub fn select_series_twice(connection: Connection) -> ScenarioResult {
  use _first <- result.try(select_series(connection))
  select_series(connection)
}

/// `all` of the same SQL with 3, then 2: the recorded requests of
/// `select_two_series` in the other order.
///
/// ## Example
///
/// ```gleam
/// select_three_then_two(connection)
/// // -> Error(RequestNotMatched) in playback of "two_parameters"
/// ```
pub fn select_three_then_two(connection: Connection) -> ScenarioResult {
  use three <- result.try(
    series_query(3) |> all(single(codecs.int), connection),
  )
  use two <- result.try(series_query(2) |> all(single(codecs.int), connection))
  Ok(string.inspect(#(three, two)))
}

/// `all` of the same SQL with 2, then 3: two recorded answers with the
/// same SQL and other parameters.
///
/// ## Example
///
/// ```gleam
/// select_two_series(connection)
/// // -> Ok("#([1, 2], [1, 2, 3])")
/// ```
pub fn select_two_series(connection: Connection) -> ScenarioResult {
  use two <- result.try(series_query(2) |> all(single(codecs.int), connection))
  use three <- result.try(
    series_query(3) |> all(single(codecs.int), connection),
  )
  Ok(string.inspect(#(two, three)))
}

/// `all` of `generate_series(1, 4)`: SQL that the recording of `all` has,
/// with a parameter it does not have.
///
/// ## Example
///
/// ```gleam
/// select_four(connection)
/// // -> Error(RequestNotRecorded) in playback of "all"
/// ```
pub fn select_four(connection: Connection) -> ScenarioResult {
  series_query(4) |> all(single(codecs.int), connection) |> inspected
}

/// The password whose hash `stored_hash` is.
pub const password = "correct horse"

/// The SHA-256 hash in hex of `password`.
pub const stored_hash =
  "4104d36f8da2c254349f85836793ebe029e0c957063a34c91c2e9203187b5631"

/// `password_matches` of `password` and its hash, with the password as a
/// secret parameter.
///
/// ## Example
///
/// ```gleam
/// check_password(connection)
/// // -> Ok("True")
/// ```
pub fn check_password(connection: Connection) -> ScenarioResult {
  password_matches(connection, password, stored_hash) |> inspected
}

/// `password_matches` of another password and the hash of `password`: a
/// request that differs from the recording of `check_password` only in
/// the value of its secret parameter.
///
/// ## Example
///
/// ```gleam
/// check_other_password(connection)
/// // -> Ok("True") in playback of "secret"
/// ```
pub fn check_other_password(connection: Connection) -> ScenarioResult {
  password_matches(connection, "battery staple", stored_hash) |> inspected
}

/// `password_matches` of `password` and another hash: a request that
/// differs from the recording of `check_password` in a parameter that is
/// not secret.
///
/// ## Example
///
/// ```gleam
/// check_password_against_other_hash(connection)
/// // -> Error(RequestNotRecorded) in playback of "secret"
/// ```
pub fn check_password_against_other_hash(
  connection: Connection,
) -> ScenarioResult {
  password_matches(connection, password, "00") |> inspected
}

/// The SQL of `password_matches` with the password as a parameter that is
/// not secret.
///
/// ## Example
///
/// ```gleam
/// check_password_in_plain(connection)
/// // -> Error(RequestNotRecorded) in playback of "secret"
/// ```
pub fn check_password_in_plain(connection: Connection) -> ScenarioResult {
  "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
  |> query
  |> named("password.matches")
  |> parameter(codecs.text, password)
  |> parameter(codecs.text, stored_hash)
  |> one(single(codecs.bool), connection)
  |> inspected
}

fn series_query(count: Int) -> query.Query {
  query("SELECT x FROM generate_series(1, $1) AS x")
  |> parameter(codecs.int, count)
}

/// `one` of the length of an int4 array parameter.
///
/// ## Example
///
/// ```gleam
/// count_array(connection)
/// // -> Ok("3")
/// ```
pub fn count_array(connection: Connection) -> ScenarioResult {
  query("SELECT cardinality($1::int4[])")
  |> parameter(array.array(codecs.int), [1, 2, 3])
  |> one(single(codecs.int), connection)
  |> inspected
}

/// The SQL of `count_array` with a text parameter, which does not take
/// the int4[] type of the parameter.
///
/// ## Example
///
/// ```gleam
/// count_with_text(connection)
/// // -> Error(ParameterTypeMismatch)
/// ```
pub fn count_with_text(connection: Connection) -> ScenarioResult {
  query("SELECT cardinality($1::int4[])")
  |> parameter(codecs.text, "{1,2,3}")
  |> one(single(codecs.int), connection)
  |> inspected
}

/// `maybe_one` of a query with no row.
///
/// ## Example
///
/// ```gleam
/// select_nothing(connection)
/// // -> Ok("None")
/// ```
pub fn select_nothing(connection: Connection) -> ScenarioResult {
  query("SELECT 1 WHERE false")
  |> maybe_one(single(codecs.int), connection)
  |> inspected
}

/// `affected` of an update of three rows of a temporary table.
///
/// ## Example
///
/// ```gleam
/// update_rows(connection)
/// // -> Ok("3")
/// ```
pub fn update_rows(connection: Connection) -> ScenarioResult {
  with_connection(connection, fn(held) {
    use Nil <- result.try(run_sql(
      "CREATE TEMPORARY TABLE counters (id int4); INSERT INTO counters VALUES (1), (2), (3)",
      held,
    ))
    query("UPDATE counters SET id = id + $1")
    |> parameter(codecs.int, 10)
    |> affected(held)
  })
  |> result.flatten
  |> inspected
}

/// A `run_sql` call of two statements.
///
/// ## Example
///
/// ```gleam
/// run_two_statements(connection)
/// // -> Ok("Nil")
/// ```
pub fn run_two_statements(connection: Connection) -> ScenarioResult {
  run_sql("SELECT 1; SELECT 2", connection) |> inspected
}

/// A `run_sql` call whose second statement divides by zero.
///
/// ## Example
///
/// ```gleam
/// run_failing_sql(connection)
/// // -> Error(SqlStatementFailed)
/// ```
pub fn run_failing_sql(connection: Connection) -> ScenarioResult {
  run_sql("SELECT 1; SELECT 1 / 0", connection) |> inspected
}

/// A transaction that makes a table, stores a row and counts the rows.
///
/// ## Example
///
/// ```gleam
/// count_in_transaction(connection)
/// // -> Ok("1")
/// ```
pub fn count_in_transaction(connection: Connection) -> ScenarioResult {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> step(run_sql(
    "CREATE TEMPORARY TABLE notes (id int4) ON COMMIT DROP; INSERT INTO notes VALUES (1)",
    _,
  ))
  |> step(fn(held) {
    query("SELECT count(*)::int4 FROM notes") |> one(single(codecs.int), held)
  })
  |> commit
  |> inspected
}

/// A transaction whose insert fails with a unique violation that the code
/// ignores: the commit is rolled back with that violation.
///
/// ## Example
///
/// ```gleam
/// commit_after_conflict(connection)
/// // -> Error(CommitRolledBack(Some(unique violation)))
/// ```
pub fn commit_after_conflict(connection: Connection) -> ScenarioResult {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> run(fn(held) {
    use Nil <- result.try(run_sql(
      "CREATE TEMPORARY TABLE tags (name text UNIQUE) ON COMMIT DROP; INSERT INTO tags VALUES ('a')",
      held,
    ))
    query("INSERT INTO tags VALUES ($1)")
    |> parameter(codecs.text, "a")
    |> affected(held)
    |> result.is_error
    |> Ok
  })
  |> inspected
}

/// `copy_from` of three users into a temporary table, then a count.
///
/// ## Example
///
/// ```gleam
/// store_users(connection)
/// // -> Ok("#(3, 3)")
/// ```
pub fn store_users(connection: Connection) -> ScenarioResult {
  with_connection(connection, fn(held) {
    use Nil <- result.try(run_sql(
      "CREATE TEMPORARY TABLE copied_users (id int4, email text)",
      held,
    ))
    use stored <- result.try(copy_from(
      held,
      into: table("copied_users"),
      columns: ["id", "email"],
      rows: copy_users.users(),
      write: copy_users.user_fields,
    ))
    query("SELECT count(*)::int4 FROM copied_users")
    |> one(single(codecs.int), held)
    |> result.map(fn(counted) { #(stored, counted) })
  })
  |> result.flatten
  |> inspected
}

/// `copy_from` into a table that does not exist.
///
/// ## Example
///
/// ```gleam
/// store_into_missing_table(connection)
/// // -> Error(undefined table)
/// ```
pub fn store_into_missing_table(connection: Connection) -> ScenarioResult {
  copy_from(
    connection,
    into: table("no_such_table"),
    columns: ["id", "email"],
    rows: copy_users.users(),
    write: copy_users.user_fields,
  )
  |> inspected
}

/// `copy_to` of `generate_series(1, 3)`.
///
/// ## Example
///
/// ```gleam
/// read_series(connection)
/// // -> Ok("[3, 2, 1]")
/// ```
pub fn read_series(connection: Connection) -> ScenarioResult {
  copy_to(
    connection,
    query("SELECT x FROM generate_series(1, 3) AS x"),
    read: single(codecs.int),
    from: [],
    with: list.prepend,
  )
  |> inspected
}

/// `copy_to` of a query that divides by zero at its third row.
///
/// ## Example
///
/// ```gleam
/// read_series_divided_by_zero(connection)
/// // -> Error(division by zero)
/// ```
pub fn read_series_divided_by_zero(connection: Connection) -> ScenarioResult {
  copy_to(
    connection,
    query("SELECT 1 / (3 - x) FROM generate_series(1, 5) AS x"),
    read: single(codecs.int),
    from: [],
    with: list.prepend,
  )
  |> inspected
}

/// `copy_to` of a column that does not exist.
///
/// ## Example
///
/// ```gleam
/// read_missing_column(connection)
/// // -> Error(undefined column)
/// ```
pub fn read_missing_column(connection: Connection) -> ScenarioResult {
  copy_to(
    connection,
    query("SELECT no_such_column"),
    read: single(codecs.int),
    from: [],
    with: list.prepend,
  )
  |> inspected
}

/// `copy_to` of a NULL with a codec that refuses NULL: the reader fails,
/// not PostgreSQL, so the COPY is not recorded.
///
/// ## Example
///
/// ```gleam
/// read_null(connection)
/// // -> Error(UnexpectedNull)
/// ```
pub fn read_null(connection: Connection) -> ScenarioResult {
  copy_to(
    connection,
    query("SELECT NULL::int4"),
    read: single(codecs.int),
    from: [],
    with: list.prepend,
  )
  |> inspected
}

/// An insert of the same name two times into a table with a unique name:
/// the second insert fails.
///
/// ## Example
///
/// ```gleam
/// insert_twice(connection)
/// // -> Error(Conflict)
/// ```
pub fn insert_twice(connection: Connection) -> ScenarioResult {
  with_connection(connection, fn(held) {
    use Nil <- result.try(run_sql(
      "CREATE TEMPORARY TABLE names (name text UNIQUE)",
      held,
    ))
    let insert =
      query("INSERT INTO names VALUES ($1)") |> parameter(codecs.text, "ada")
    use _first <- result.try(affected(insert, held))
    affected(insert, held)
  })
  |> result.flatten
  |> inspected
}

/// A statement with a parameter whose SQL names a missing column: it
/// fails before its parameter is written.
///
/// ## Example
///
/// ```gleam
/// select_missing_column(connection)
/// // -> Error(undefined column)
/// ```
pub fn select_missing_column(connection: Connection) -> ScenarioResult {
  query("SELECT no_such_column + $1")
  |> parameter(codecs.int, 1)
  |> one(single(codecs.int), connection)
  |> inspected
}

fn inspected(found: Result(a, Error(PostgresError))) -> ScenarioResult {
  result.map(found, string.inspect)
}
