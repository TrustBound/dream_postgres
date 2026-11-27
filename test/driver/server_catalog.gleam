//// Test fixtures for the type catalog tests on the driver servers: a
//// catalog session (a connection, a catalog and its events), setup hooks
//// that make types in a transaction and find their OIDs, and a load race
//// (a catalog with three connections, one of them blocked behind an
//// advisory lock of a control connection) for a shared act.
////
//// Each fixture that can fail gives a `Result` with a text error, so a
//// setup of dream_test reports the failure as a failed setup. Each
//// teardown rolls back the transaction, and stops the catalog and each
//// connection that the setup started.

import dream_postgres/driver/catalog.{
  type Catalog, type CatalogError, type CatalogEvent, UnknownType,
}
import dream_postgres/driver/connection.{
  type Connection, type DriverError, type Outcome, run_script, stop,
}
import dream_postgres/internal/cell.{type TypeDescription}
import dream_test/context.{type Context}
import driver/server_connection.{
  type Caller, advisory_lock_sql, caller_answer, query_text, run_control_script,
  start_caller, start_connection, wait_for_lock_waiter,
}
import driver/servers.{type Server}
import gleam/erlang/process.{type Subject}
import gleam/int.{parse, to_string}
import gleam/list.{each}
import gleam/option.{type Option, None, Some}
import gleam/result.{map_error, replace, try}
import gleam/string.{inspect, replace as replace_text}

// Catalogs --------------------------------------------------------------------

/// Starts a catalog that sends its events to `events`, or to no one.
pub fn start_catalog(
  events: Option(Subject(CatalogEvent)),
) -> Result(Catalog, String) {
  catalog.start(events)
  |> map_error(fn(error) { "could not start a catalog: " <> inspect(error) })
}

/// The next event, or `Error(Nil)` after 5 seconds.
pub fn next_catalog_event(
  events: Subject(CatalogEvent),
) -> Result(CatalogEvent, Nil) {
  process.receive(events, 5000)
}

/// The events that came, in order, until none is there.
pub fn received_catalog_events(
  events: Subject(CatalogEvent),
) -> List(CatalogEvent) {
  case process.receive(events, 0) {
    Ok(event) -> [event, ..received_catalog_events(events)]
    Error(Nil) -> []
  }
}

/// Starts a connection to `server` and a new catalog, describes `type_id`
/// with them, and stops both: the answer of a catalog that no other lookup
/// used.
pub fn describe_in_new_catalog(
  server: Server,
  type_id: Int,
) -> Result(Result(TypeDescription, CatalogError), String) {
  use connection <- try(start_connection(server.port))
  use type_catalog <- try(
    start_catalog(None) |> map_error(stop_after_error([connection], _)),
  )
  let description = catalog.describe(type_catalog, connection, type_id, 5000)
  catalog.stop(type_catalog)
  stop(connection)
  Ok(description)
}

fn stop_after_error(connections: List(Connection), error: String) -> String {
  each(connections, stop)
  error
}

/// The number of `driver_connection_test_ffi`, which no other caller gets.
@external(erlang, "driver_connection_test_ffi", "unique_lock_key")
fn unique_number() -> Int

/// A schema name that no other test uses.
fn unique_schema() -> String {
  "svc829_hidden_" <> to_string(unique_number())
}

// Types -----------------------------------------------------------------------

/// The OID of the type `type_name`, as the connection sees it.
pub fn type_oid(
  connection: Connection,
  type_name: String,
) -> Result(Int, String) {
  use text <- try(query_text(
    connection,
    "SELECT '" <> type_name <> "'::regtype::oid::text",
  ))
  parse(text) |> map_error(fn(_nil) { "expected an OID: " <> text })
}

/// Begins a transaction on the connection, makes the schema `schema` and
/// runs `statements` in it. Each `{schema}` in `statements` is the schema.
pub fn begin_in_schema(
  connection: Connection,
  schema: String,
  statements: String,
) -> Result(Nil, String) {
  run_control_script(
    connection,
    "BEGIN; CREATE SCHEMA "
      <> schema
      <> "; "
      <> replace_text(statements, "{schema}", schema),
  )
}

/// Rolls back the transaction of the connection, so no type that the test
/// made stays on the server.
pub fn roll_back(connection: Connection) -> Result(Nil, String) {
  run_control_script(connection, "ROLLBACK")
}

// Catalog sessions ------------------------------------------------------------

/// A connection, a catalog and the subject of its events, a schema name
/// that no other test uses, and the OIDs that the setup found: `type_id`
/// and `part_type_id` are 0 until a hook finds them.
pub type CatalogSession {
  CatalogSession(
    connection: Connection,
    catalog: Catalog,
    events: Subject(CatalogEvent),
    schema: String,
    type_id: Int,
    part_type_id: Int,
  )
}

/// Starts a connection to `server` and a catalog with no subscriber.
pub fn start_catalog_session(server: Server) -> Result(CatalogSession, String) {
  session_with(server, process.new_subject(), None)
}

/// Starts a connection to `server` and a catalog that sends its events to
/// the session's `events`.
pub fn start_watched_session(server: Server) -> Result(CatalogSession, String) {
  let events = process.new_subject()
  session_with(server, events, Some(events))
}

fn session_with(
  server: Server,
  events: Subject(CatalogEvent),
  subscriber: Option(Subject(CatalogEvent)),
) -> Result(CatalogSession, String) {
  use connection <- try(start_connection(server.port))
  use type_catalog <- try(
    start_catalog(subscriber) |> map_error(stop_after_error([connection], _)),
  )
  Ok(CatalogSession(
    connection:,
    catalog: type_catalog,
    events:,
    schema: unique_schema(),
    type_id: 0,
    part_type_id: 0,
  ))
}

/// Rolls back the transaction of the session, and stops its catalog and
/// its connection. A teardown for `after_each` and for the context setup.
pub fn stop_catalog_session(session: CatalogSession) -> Result(Nil, String) {
  let rolled_back = roll_back(session.connection)
  catalog.stop(session.catalog)
  stop(session.connection)
  rolled_back
}

/// The context of a describe whose tests each get a catalog session: one
/// session on `server` for the tree, which gives the context its first
/// value. `start_test_catalog` gives each test its own.
///
/// ```gleam
/// describe("catalog", catalog_session_setup(first_driver_server), [
///   after_each(stop_catalog_session),
///   before_each(start_test_catalog(first_driver_server)),
///   it("describes int4", fn(session: CatalogSession) {
///     catalog.describe(session.catalog, session.connection, 23, 5000)
///     |> should
///     |> be_ok
///     |> or_fail_with("Expected int4")
///   }),
/// ])
/// ```
pub fn catalog_session_setup(server: Server) -> Context(CatalogSession) {
  context.setup(
    setup: fn() { start_catalog_session(server) },
    teardown: stop_catalog_session,
  )
}

/// A `before_each` hook that starts a catalog session on `server` for the
/// test, with a catalog that has no subscriber.
pub fn start_test_catalog(
  server: Server,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(_tree_session) { start_catalog_session(server) }
}

/// A `before_each` hook that starts a catalog session on `server` for the
/// test, with a catalog that sends its events to the session's `events`.
pub fn start_test_watched_catalog(
  server: Server,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(_tree_session) { start_watched_session(server) }
}

/// A hook that begins a transaction on the session's connection, makes the
/// session's schema and runs `statements` in it. Each `{schema}` in
/// `statements` is the session's schema.
pub fn begin_with_types(
  statements: String,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) {
    begin_in_schema(session.connection, session.schema, statements)
    |> replace(session)
  }
}

/// A hook that keeps the OID of the type `type_name` as `type_id`. Each
/// `{schema}` in `type_name` is the session's schema.
pub fn find_type(
  type_name: String,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) {
    use type_id <- try(session_type_oid(session, type_name))
    Ok(CatalogSession(..session, type_id:))
  }
}

/// A hook that keeps the OID of the type `type_name` as `part_type_id`.
/// Each `{schema}` in `type_name` is the session's schema.
pub fn find_part_type(
  type_name: String,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) {
    use part_type_id <- try(session_type_oid(session, type_name))
    Ok(CatalogSession(..session, part_type_id:))
  }
}

fn session_type_oid(
  session: CatalogSession,
  type_name: String,
) -> Result(Int, String) {
  type_oid(
    session.connection,
    replace_text(type_name, "{schema}", session.schema),
  )
}

/// A hook that describes `type_id` with the session's catalog, which must
/// work.
pub fn load_type(
  type_id: Int,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) { describe_in_session(session, type_id) }
}

/// A hook that describes the session's `type_id` with its catalog, which
/// must work.
pub fn load_found_type(
  session: CatalogSession,
) -> Result(CatalogSession, String) {
  describe_in_session(session, session.type_id)
}

fn describe_in_session(
  session: CatalogSession,
  type_id: Int,
) -> Result(CatalogSession, String) {
  catalog.describe(session.catalog, session.connection, type_id, 5000)
  |> replace(session)
  |> map_error(fn(error) {
    "could not describe " <> to_string(type_id) <> ": " <> inspect(error)
  })
}

/// A hook that describes `type_id` with the session's catalog, which must
/// give `UnknownType`.
pub fn load_unknown_type(
  type_id: Int,
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) {
    catalog.describe(session.catalog, session.connection, type_id, 5000)
    |> require_unknown(session, type_id)
  }
}

fn require_unknown(
  answer: Result(TypeDescription, CatalogError),
  session: CatalogSession,
  type_id: Int,
) -> Result(CatalogSession, String) {
  case answer {
    Error(UnknownType(_type_id)) -> Ok(session)
    other ->
      Error(
        "expected UnknownType for "
        <> to_string(type_id)
        <> ", it gave "
        <> inspect(other),
      )
  }
}

/// A hook that runs the connection hook `step` on the session's
/// connection, for example `run_setup_script("BEGIN")`.
pub fn on_session_connection(
  step: fn(Connection) -> Result(Connection, String),
) -> fn(CatalogSession) -> Result(CatalogSession, String) {
  fn(session: CatalogSession) { step(session.connection) |> replace(session) }
}

// Blocked connections ---------------------------------------------------------

/// A connection whose requests wait behind a statement that waits for an
/// advisory lock of the control connection.
pub type BlockedConnection {
  BlockedConnection(
    control: Connection,
    blocked: Connection,
    key: Int,
    blocker: Caller(Result(List(Outcome), DriverError)),
  )
}

/// Takes the advisory lock `key` on `control`, makes `blocked` wait for it,
/// and waits until the server shows the waiting session: no sleep. Tests
/// that run at the same time use different keys.
pub fn block_connection(
  control: Connection,
  blocked: Connection,
  key: Int,
) -> Result(BlockedConnection, String) {
  let lock = advisory_lock_sql(key)
  use _locked <- try(run_control_script(control, lock))
  let blocker =
    start_caller(fn() {
      run_script(blocked, connection.statement(lock), 10_000)
    })
  use _waited <- try(wait_for_lock_waiter(control, key))
  Ok(BlockedConnection(control:, blocked:, key:, blocker:))
}

/// Lets the blocked connection go on, waits until it took the lock, and
/// lets the lock go on it too.
pub fn unblock_connection(blocked: BlockedConnection) -> Result(Nil, String) {
  let unlock = "SELECT pg_advisory_unlock(" <> to_string(blocked.key) <> ")"
  use _unlocked <- try(run_control_script(blocked.control, unlock))
  use answer <- try(caller_answer(blocked.blocker))
  use _outcomes <- try(
    answer
    |> map_error(fn(error) { "the blocked lock failed: " <> inspect(error) }),
  )
  run_control_script(blocked.blocked, unlock)
}

// Load races ------------------------------------------------------------------

/// A catalog that sends its events to `events`, with three connections to
/// one server: `control` holds the advisory lock `lock_key`, `blocked`
/// waits for it, and `other` makes its types in the schema `schema`. The
/// key and the schema are ones that no other test uses.
pub type LoadRace {
  LoadRace(
    control: Connection,
    blocked: Connection,
    other: Connection,
    catalog: Catalog,
    events: Subject(CatalogEvent),
    schema: String,
    lock_key: Int,
  )
}

/// What an act gave, with the load race that it ran on.
pub type RaceOutcome(outcome) {
  RaceOutcome(race: LoadRace, outcome: outcome)
}

/// Starts a load race on `server`.
pub fn start_load_race(server: Server) -> Result(LoadRace, String) {
  use control <- try(start_connection(server.port))
  use blocked <- try(
    start_connection(server.port) |> map_error(stop_after_error([control], _)),
  )
  use other <- try(
    start_connection(server.port)
    |> map_error(stop_after_error([control, blocked], _)),
  )
  let events = process.new_subject()
  use type_catalog <- try(
    start_catalog(Some(events))
    |> map_error(stop_after_error([control, blocked, other], _)),
  )
  Ok(LoadRace(
    control:,
    blocked:,
    other:,
    catalog: type_catalog,
    events:,
    schema: unique_schema(),
    lock_key: unique_number(),
  ))
}

/// Rolls back the transaction of `other`, and stops the catalog and the
/// three connections. The stop of the control connection gives its lock
/// back.
pub fn stop_load_race(race: LoadRace) -> Result(Nil, String) {
  let rolled_back = roll_back(race.other)
  catalog.stop(race.catalog)
  each([race.control, race.blocked, race.other], stop)
  rolled_back
}

/// The context of a describe whose tests each check one value of one
/// shared act: the setup starts a load race on `server` and runs `act` on
/// it once, and the teardown stops the race. The act waits on a lock, so
/// the wait happens once for all the tests.
pub fn race_act_setup(
  server: Server,
  act: fn(LoadRace) -> Result(outcome, String),
) -> Context(RaceOutcome(outcome)) {
  context.setup(
    setup: fn() { start_load_race(server) |> try(run_race_act(_, act)) },
    teardown: fn(shared: RaceOutcome(outcome)) { stop_load_race(shared.race) },
  )
}

fn run_race_act(
  race: LoadRace,
  act: fn(LoadRace) -> Result(outcome, String),
) -> Result(RaceOutcome(outcome), String) {
  act(race)
  |> result.map(RaceOutcome(race, _))
  |> map_error(fn(error) { stop_race_after_error(race, error) })
}

fn stop_race_after_error(race: LoadRace, error: String) -> String {
  case stop_load_race(race) {
    Ok(Nil) -> error
    Error(stop_error) -> error <> ", and then " <> stop_error
  }
}
