//// Tests for `dream_postgres/driver/catalog`, the type catalog, on the
//// driver servers of PostgreSQL 16 to 19.
////
//// The tests make their types in a transaction of the connection that
//// loads the catalog, and roll it back, so no type stays on the server and
//// other test runs never see them. A load that must stay open waits behind
//// an advisory lock of the range 82900 to 82999, which only these tests
//// use. A second connection holds the lock, so no test sleeps.

import dream_postgres/driver/catalog.{
  type Catalog, type CatalogError, type CatalogEvent, CatalogProcessDown,
  LoadFailed, LoadStarted, UnknownType,
}
import dream_postgres/driver/connection.{
  type Connection, type ConnectionConfig, type DriverError, type Outcome,
  Backoff, CacheStatements, ConnectionConfig, ServerRefused,
}
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/transport.{NoTls, TransportConfig}
import dream_postgres/internal/cell.{
  type TypeDescription, Array, Base, Composite, Domain, Enum, Multirange, Pseudo,
  Range, Text, TypeDescription,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int.{to_string}
import gleam/list.{map, try_map}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result.{try}

/// Why a test could not get to its assertion.
type TestFailure {
  ConfigRefused
  ConnectionRefused
  CatalogRefused
  DriverFailed(error: DriverError)
  CatalogFailed(error: CatalogError)
  NoOid(type_name: String)
  NoAnswer
}

/// A type OID that no server of the tests has.
const unknown_type_id = 4_294_967_000

/// The tests of the type catalog.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/catalog", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group("loads", load_tests()),
    group("the process", process_tests()),
  ])
}

// Settings --------------------------------------------------------------------

fn config(port: Int) -> Result(ConnectionConfig, TestFailure) {
  use address <- try(
    transport.address("localhost", port) |> result.replace_error(ConfigRefused),
  )
  use login_config <- try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password(servers.password),
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.replace_error(ConfigRefused),
  )
  Ok(ConnectionConfig(
    transport: TransportConfig(address, NoTls, 5000, 500),
    login: login_config,
    setup_timeout_milliseconds: 5000,
    cancel_timeout_milliseconds: 2000,
    reconnect: Backoff(10, 60_000),
    events: None,
    notifications: None,
    statements: CacheStatements(512),
  ))
}

/// Starts a connection, gives it to `body`, and stops it.
fn with_connection(
  port: Int,
  body: fn(Connection) -> Result(value, TestFailure),
) -> Result(value, TestFailure) {
  use settings <- try(config(port))
  use connection <- try(
    connection.start(settings) |> result.replace_error(ConnectionRefused),
  )
  let value = body(connection)
  connection.stop(connection)
  value
}

/// Starts a catalog with a subscriber, gives both to `body`, and stops the
/// catalog.
fn with_catalog(
  body: fn(Catalog, Subject(CatalogEvent)) -> Result(value, TestFailure),
) -> Result(value, TestFailure) {
  let events = process.new_subject()
  use started <- try(
    catalog.start(Some(events)) |> result.replace_error(CatalogRefused),
  )
  let value = body(started, events)
  catalog.stop(started)
  value
}

fn script(
  connection: Connection,
  sql: String,
) -> Result(List(Outcome), TestFailure) {
  connection.run_script(connection, sql, 5000)
  |> result.map_error(DriverFailed)
}

fn describe_type(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
) -> Result(TypeDescription, CatalogError) {
  catalog.describe(catalog, connection, type_id, 5000)
}

fn describe_underlying_type(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
) -> Result(TypeDescription, CatalogError) {
  catalog.describe_underlying(catalog, connection, type_id, 5000)
}

/// The OID of each type, by its name, as the connection sees them.
fn oids(
  connection: Connection,
  type_names: List(String),
) -> Result(List(Int), TestFailure) {
  try_map(type_names, oid(connection, _))
}

fn oid(connection: Connection, type_name: String) -> Result(Int, TestFailure) {
  use outcomes <- try(script(
    connection,
    "SELECT '" <> type_name <> "'::regtype::oid::text",
  ))
  case map(outcomes, rows_of) {
    [[[Text(bytes)]]] -> number_of(bytes, type_name)
    _other -> Error(NoOid(type_name))
  }
}

fn rows_of(outcome: Outcome) {
  outcome.result.rows
}

fn number_of(bytes: BitArray, type_name: String) -> Result(Int, TestFailure) {
  bit_array.to_string(bytes)
  |> result.try(int.parse)
  |> result.replace_error(NoOid(type_name))
}

/// Runs `setup` in a transaction of the connection, gives the OIDs of the
/// named types to `body`, and rolls the transaction back.
fn with_new_types(
  connection: Connection,
  setup: String,
  type_names: List(String),
  body: fn(List(Int)) -> Result(value, TestFailure),
) -> Result(value, TestFailure) {
  use _began <- try(script(connection, "BEGIN; " <> setup))
  let value = oids(connection, type_names) |> result.try(body)
  use _rolled_back <- try(script(connection, "ROLLBACK"))
  value
}

const hidden_schema = "CREATE SCHEMA svc829_hidden; "

fn int4() -> TypeDescription {
  TypeDescription(23, "pg_catalog", "int4", Base)
}

fn int4range() -> TypeDescription {
  TypeDescription(3904, "pg_catalog", "int4range", Range(23))
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group("PostgreSQL " <> to_string(server.version), [
    it(
      "describes a base type, an array, a range, a multirange and a pseudo-type",
      fn() { check_built_in_types(server) },
    ),
    it("describes the extension types hstore, ltree and vector", fn() {
      check_extension_types(server)
    }),
    it(
      "describes an enum outside the search_path with its labels in order",
      fn() { check_hidden_enum(server) },
    ),
    it("describes a composite with its fields, without a dropped one", fn() {
      check_composite(server)
    }),
    it("follows a domain over a domain over a range to the range", fn() {
      check_domain_chain(server)
    }),
    it("follows a domain over a composite to the composite", fn() {
      check_domain_over_composite(server)
    }),
  ])
}

fn check_built_in_types(server: Server) {
  // Act
  let descriptions = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    [23, 1007, 3904, 4451, 2278]
    |> map(describe_type(catalog, connection, _))
    |> Ok
  }

  // Assert
  descriptions
  |> should
  |> be_equal(
    Ok([
      Ok(int4()),
      Ok(TypeDescription(1007, "pg_catalog", "_int4", Array(23))),
      Ok(int4range()),
      Ok(TypeDescription(4451, "pg_catalog", "int4multirange", Multirange(3904))),
      Ok(TypeDescription(2278, "pg_catalog", "void", Pseudo)),
    ]),
  )
  |> or_fail_with("Expected the descriptions of the built-in types")
}

fn check_extension_types(server: Server) {
  // Act
  let descriptions = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    use type_ids <- try(oids(connection, ["hstore", "ltree", "vector"]))
    Ok(#(type_ids, map(type_ids, describe_type(catalog, connection, _))))
  }

  // Assert
  descriptions
  |> result.map(expected_extension_types)
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected hstore, ltree and vector as base types of public")
}

fn expected_extension_types(
  found: #(List(Int), List(Result(TypeDescription, CatalogError))),
) -> Bool {
  let #(type_ids, descriptions) = found
  case type_ids {
    [hstore, ltree, vector] ->
      descriptions
      == [
        Ok(TypeDescription(hstore, "public", "hstore", Base)),
        Ok(TypeDescription(ltree, "public", "ltree", Base)),
        Ok(TypeDescription(vector, "public", "vector", Base)),
      ]
    _other -> False
  }
}

fn check_hidden_enum(server: Server) {
  // Arrange
  let setup =
    hidden_schema
    <> "CREATE TYPE svc829_hidden.mood AS ENUM ('sad', 'happy'); "
    <> "ALTER TYPE svc829_hidden.mood ADD VALUE 'calm' BEFORE 'happy'"

  // Act
  let found = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    use type_ids <- with_new_types(connection, setup, ["svc829_hidden.mood"])
    use description <- try(describe_first(catalog, connection, type_ids))
    Ok(#(type_ids, description))
  }

  // Assert
  found
  |> result.map(expected_enum)
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected the enum of svc829_hidden with sad, calm, happy")
}

fn describe_first(
  catalog: Catalog,
  connection: Connection,
  type_ids: List(Int),
) -> Result(TypeDescription, TestFailure) {
  case type_ids {
    [type_id, ..] ->
      describe_type(catalog, connection, type_id)
      |> result.map_error(CatalogFailed)
    [] -> Error(NoAnswer)
  }
}

fn expected_enum(found: #(List(Int), TypeDescription)) -> Bool {
  let #(type_ids, description) = found
  [description.id] == type_ids
  && description
  == TypeDescription(
    description.id,
    "svc829_hidden",
    "mood",
    Enum(["sad", "calm", "happy"]),
  )
}

fn check_composite(server: Server) {
  // Arrange
  let setup =
    hidden_schema
    <> "CREATE TYPE svc829_hidden.trio AS (a int4, b text, c bool); "
    <> "ALTER TYPE svc829_hidden.trio DROP ATTRIBUTE b"

  // Act
  let found = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    use type_ids <- with_new_types(connection, setup, ["svc829_hidden.trio"])
    use description <- try(describe_first(catalog, connection, type_ids))
    Ok(#(type_ids, description))
  }

  // Assert
  found
  |> result.map(expected_composite)
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected the composite with the fields a and c")
}

fn expected_composite(found: #(List(Int), TypeDescription)) -> Bool {
  let #(type_ids, description) = found
  [description.id] == type_ids
  && description
  == TypeDescription(
    description.id,
    "svc829_hidden",
    "trio",
    Composite([#("a", 23), #("c", 16)]),
  )
}

fn check_domain_chain(server: Server) {
  // Arrange
  let setup =
    hidden_schema
    <> "CREATE DOMAIN svc829_hidden.inner_range AS int4range; "
    <> "CREATE DOMAIN svc829_hidden.outer_range AS svc829_hidden.inner_range"
  let names = ["svc829_hidden.inner_range", "svc829_hidden.outer_range"]

  // Act
  let found = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    use type_ids <- with_new_types(connection, setup, names)
    domain_chain_answers(catalog, connection, type_ids)
  }

  // Assert
  found
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with(
    "Expected the outer domain over the inner one, then int4range",
  )
}

fn domain_chain_answers(
  catalog: Catalog,
  connection: Connection,
  type_ids: List(Int),
) -> Result(Bool, TestFailure) {
  case type_ids {
    [inner, outer] ->
      Ok(
        #(
          describe_type(catalog, connection, outer),
          describe_underlying_type(catalog, connection, outer),
        )
        == #(
          Ok(TypeDescription(
            outer,
            "svc829_hidden",
            "outer_range",
            Domain(inner),
          )),
          Ok(int4range()),
        ),
      )
    _other -> Error(NoAnswer)
  }
}

fn check_domain_over_composite(server: Server) {
  // Arrange
  let setup =
    hidden_schema
    <> "CREATE TYPE svc829_hidden.pair AS (left_side int4, right_side text); "
    <> "CREATE DOMAIN svc829_hidden.checked_pair AS svc829_hidden.pair"
  let names = ["svc829_hidden.pair", "svc829_hidden.checked_pair"]

  // Act
  let found = {
    use connection <- with_connection(server.port)
    use catalog, _events <- with_catalog
    use type_ids <- with_new_types(connection, setup, names)
    domain_over_composite_answer(catalog, connection, type_ids)
  }

  // Assert
  found
  |> should
  |> be_equal(Ok(True))
  |> or_fail_with("Expected the composite under the domain")
}

fn domain_over_composite_answer(
  catalog: Catalog,
  connection: Connection,
  type_ids: List(Int),
) -> Result(Bool, TestFailure) {
  case type_ids {
    [pair, checked_pair] ->
      Ok(
        describe_underlying_type(catalog, connection, checked_pair)
        == Ok(TypeDescription(
          pair,
          "svc829_hidden",
          "pair",
          Composite([#("left_side", 23), #("right_side", 25)]),
        )),
      )
    _other -> Error(NoAnswer)
  }
}

// Loads -----------------------------------------------------------------------

fn first_port() -> Int {
  case driver_servers() {
    [first, ..] -> first.port
    [] -> 0
  }
}

/// The events that came, in order, until none is there.
fn received_events(events: Subject(CatalogEvent)) -> List(CatalogEvent) {
  case process.receive(events, 0) {
    Ok(event) -> [event, ..received_events(events)]
    Error(Nil) -> []
  }
}

fn load_tests() {
  [
    it("loads one time for an unknown type, then gives UnknownType", fn() {
      // Act
      let found = {
        use connection <- with_connection(first_port())
        use catalog, events <- with_catalog
        let known = describe_type(catalog, connection, 23)
        let unknown = describe_type(catalog, connection, unknown_type_id)
        Ok(#(known, unknown, received_events(events)))
      }

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          #(Ok(int4()), Error(UnknownType(unknown_type_id)), [
            LoadStarted(1),
            LoadStarted(2),
          ]),
        ),
      )
      |> or_fail_with("Expected int4, then UnknownType after the second load")
    }),
    it("finds a type that was made after the last load", fn() {
      // Act
      let found = {
        use connection <- with_connection(first_port())
        use catalog, _events <- with_catalog
        use _known <- try(
          describe_type(catalog, connection, 23)
          |> result.map_error(CatalogFailed),
        )
        use type_ids <- with_new_types(
          connection,
          hidden_schema <> "CREATE TYPE svc829_hidden.later AS ENUM ('one')",
          ["svc829_hidden.later"],
        )
        use description <- try(describe_first(catalog, connection, type_ids))
        Ok(description.kind)
      }

      // Assert
      found
      |> should
      |> be_equal(Ok(Enum(["one"])))
      |> or_fail_with("Expected the new enum after a reload")
    }),
    it(
      "starts each catalog empty, so a new one never has the types of an earlier one",
      fn() {
        // Act
        let found = {
          use connection <- with_connection(first_port())
          use other_connection <- with_connection(first_port())
          use earlier, _earlier_events <- with_catalog
          use type_ids <- with_new_types(
            connection,
            hidden_schema <> "CREATE TYPE svc829_hidden.private AS ENUM ('one')",
            ["svc829_hidden.private"],
          )
          use _described <- try(describe_first(earlier, connection, type_ids))
          use newer, _newer_events <- with_catalog
          Ok(map(type_ids, describe_type(newer, other_connection, _)))
        }

        // Assert
        found
        |> result.map(is_unknown_type)
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("Expected UnknownType from the newer catalog")
      },
    ),
    it(
      "gives the server's error when the load fails in a failed transaction",
      fn() {
        // Act
        let found = {
          use connection <- with_connection(first_port())
          use catalog, _events <- with_catalog
          use _began <- try(script(connection, "BEGIN"))
          let division = connection.run(connection, "SELECT 1/0", [], [], 5000)
          let described = describe_type(catalog, connection, 23)
          use _rolled_back <- try(script(connection, "ROLLBACK"))
          Ok(#(refused_code(division), error_code(described)))
        }

        // Assert
        found
        |> should
        |> be_equal(Ok(#("22012", "25P02")))
        |> or_fail_with("Expected 25P02 from the load")
      },
    ),
    it("loads again for a lookup during a load, without waiting for it", fn() {
      check_lookup_during_load()
    }),
    it("answers a known type during a load with the table it has", fn() {
      check_known_type_during_load()
    }),
  ]
}

fn is_unknown_type(
  answers: List(Result(TypeDescription, CatalogError)),
) -> Bool {
  case answers {
    [Error(UnknownType(_type_id))] -> True
    _other -> False
  }
}

fn refused_code(refused: Result(Outcome, DriverError)) -> String {
  case refused {
    Error(ServerRefused(report, _status)) -> report.code
    _other -> "not refused"
  }
}

fn error_code(described: Result(TypeDescription, CatalogError)) -> String {
  case described {
    Error(LoadFailed(ServerRefused(report, _status))) -> report.code
    _other -> "not a failed load"
  }
}

// Loads that wait -------------------------------------------------------------

/// A connection whose requests wait behind a statement that waits for an
/// advisory lock of the control connection.
type BlockedConnection {
  BlockedConnection(
    control: Connection,
    blocked: Connection,
    key: Int,
    blocker: Subject(Result(List(Outcome), DriverError)),
  )
}

/// Takes the lock on `control`, and makes `blocked` wait for it.
fn block(
  control: Connection,
  blocked: Connection,
  key: Int,
) -> Result(BlockedConnection, TestFailure) {
  let lock = "SELECT pg_advisory_lock(" <> to_string(key) <> ")"
  use _locked <- try(script(control, lock))
  let blocker = process.new_subject()
  process.spawn_unlinked(fn() { run_blocker(blocked, lock, blocker) })
  use Nil <- try(wait_for_lock_waiter(control, key, 500))
  Ok(BlockedConnection(control:, blocked:, key:, blocker:))
}

fn run_blocker(
  connection: Connection,
  sql: String,
  answers: Subject(Result(List(Outcome), DriverError)),
) -> Nil {
  process.send(answers, connection.run_script(connection, sql, 10_000))
}

/// Lets the blocked connection go on, and waits until it took the lock.
fn unblock(blocked: BlockedConnection) -> Result(Nil, TestFailure) {
  let unlock = "SELECT pg_advisory_unlock(" <> to_string(blocked.key) <> ")"
  use _unlocked <- try(script(blocked.control, unlock))
  use _answer <- try(
    process.receive(blocked.blocker, 10_000)
    |> result.replace_error(NoAnswer),
  )
  use _unlocked <- try(script(blocked.blocked, unlock))
  Ok(Nil)
}

/// Asks the control connection until a session waits for the lock: no
/// sleep.
fn wait_for_lock_waiter(
  control: Connection,
  key: Int,
  attempts: Int,
) -> Result(Nil, TestFailure) {
  use outcomes <- try(script(
    control,
    "SELECT count(*)::text FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid = "
      <> to_string(key),
  ))
  case map(outcomes, rows_of), attempts {
    [[[Text(<<"1">>)]]], _attempts -> Ok(Nil)
    _rows, 0 -> Error(NoAnswer)
    _rows, _attempts -> wait_for_lock_waiter(control, key, attempts - 1)
  }
}

/// Describes a type in a process of its own, which sends the answer.
fn describe_later(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
) -> Subject(Result(TypeDescription, CatalogError)) {
  let answers = process.new_subject()
  process.spawn_unlinked(fn() {
    describe_and_send(catalog, connection, type_id, answers)
  })
  answers
}

fn describe_and_send(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
  answers: Subject(Result(TypeDescription, CatalogError)),
) -> Nil {
  process.send(answers, catalog.describe(catalog, connection, type_id, 10_000))
}

fn wait_for_event(
  events: Subject(CatalogEvent),
) -> Result(CatalogEvent, TestFailure) {
  process.receive(events, 5000) |> result.replace_error(NoAnswer)
}

fn later_answer(
  answers: Subject(Result(TypeDescription, CatalogError)),
) -> Result(Result(TypeDescription, CatalogError), TestFailure) {
  process.receive(answers, 10_000) |> result.replace_error(NoAnswer)
}

/// Load 1 waits on a blocked connection. A lookup on another connection,
/// of a type that its transaction made after load 1 started, loads again
/// at once, while load 1 still waits. Load 1 ends after load 2, so its
/// older table does not replace the table of load 2.
fn check_lookup_during_load() {
  // Act
  let found = {
    use control <- with_connection(first_port())
    use blocked <- with_connection(first_port())
    use other <- with_connection(first_port())
    use catalog, events <- with_catalog
    use blocking <- try(block(control, blocked, 82_900))
    let first = describe_later(catalog, blocked, 23)
    use first_event <- try(wait_for_event(events))
    use during <- try(
      with_new_types(
        other,
        hidden_schema <> "CREATE TYPE svc829_hidden.during AS ENUM ('one')",
        ["svc829_hidden.during"],
        describe_during(catalog, other, _),
      ),
    )
    use Nil <- try(unblock(blocking))
    use first_answer <- try(later_answer(first))
    Ok(#(first_event, during, received_events(events), first_answer))
  }

  // Assert
  found
  |> should
  |> be_equal(
    Ok(#(LoadStarted(1), Enum(["one"]), [LoadStarted(2)], Ok(int4()))),
  )
  |> or_fail_with("Expected load 2 to find the new type while load 1 waited")
}

fn describe_during(
  catalog: Catalog,
  connection: Connection,
  type_ids: List(Int),
) -> Result(cell.TypeKind, TestFailure) {
  use description <- try(describe_first(catalog, connection, type_ids))
  Ok(description.kind)
}

/// While load 2 waits on a blocked connection, a lookup of a type of
/// load 1 is answered from load 1, with no load of its own.
fn check_known_type_during_load() {
  // Act
  let found = {
    use control <- with_connection(first_port())
    use blocked <- with_connection(first_port())
    use other <- with_connection(first_port())
    use catalog, events <- with_catalog
    use _loaded <- try(
      describe_type(catalog, other, 23) |> result.map_error(CatalogFailed),
    )
    let first_events = received_events(events)
    use blocking <- try(block(control, blocked, 82_901))
    let waiting = describe_later(catalog, blocked, unknown_type_id)
    use second_event <- try(wait_for_event(events))
    let text = describe_type(catalog, other, 25)
    let events_during = received_events(events)
    use Nil <- try(unblock(blocking))
    use waiting_answer <- try(later_answer(waiting))
    Ok(#(first_events, second_event, text, events_during, waiting_answer))
  }

  // Assert
  found
  |> should
  |> be_equal(
    Ok(#(
      [LoadStarted(1)],
      LoadStarted(2),
      Ok(TypeDescription(25, "pg_catalog", "text", Base)),
      [],
      Error(UnknownType(unknown_type_id)),
    )),
  )
  |> or_fail_with("Expected text from load 1 while load 2 waited")
}

// The process -----------------------------------------------------------------

fn process_tests() {
  [
    it("gives CatalogProcessDown after the catalog stopped", fn() {
      // Act
      let found = {
        use connection <- with_connection(first_port())
        use started <- try(
          catalog.start(None) |> result.replace_error(CatalogRefused),
        )
        catalog.stop(started)
        catalog.stop(started)
        Ok(describe_type(started, connection, 23))
      }

      // Assert
      found
      |> should
      |> be_equal(Ok(Error(CatalogProcessDown)))
      |> or_fail_with("Expected CatalogProcessDown")
    }),
    it("starts as a child of a supervisor", fn() {
      // Act
      let started =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(catalog.supervised(None))
        |> static_supervisor.start
        |> result.map(stop_supervisor)

      // Assert
      started
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the supervisor to start the catalog")
    }),
  ]
}

fn stop_supervisor(
  started: actor.Started(static_supervisor.Supervisor),
) -> Nil {
  process.unlink(started.pid)
  process.kill(started.pid)
}
