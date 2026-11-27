//// Tests for `dream_postgres/driver/catalog`, the type catalog, on the
//// driver servers of PostgreSQL 16 to 19.
////
//// The tests make their types in a transaction of the connection that
//// loads the catalog, and roll it back, so no type stays on the server and
//// other test runs never see them. A load that must stay open waits behind
//// an advisory lock of the range 82900 to 82999, which only these tests
//// use. A second connection holds the lock, so no test sleeps.

import dream_postgres/driver/catalog.{
  CatalogProcessDown, LoadStarted, UnknownType, supervised,
}
import dream_postgres/driver/connection.{run, run_script, stop}
import dream_postgres/internal/cell.{
  type TypeDescription, Array, Base, Composite, Domain, Enum, Multirange, Pseudo,
  Range, TypeDescription,
}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/server_catalog.{
  begin_with, block_connection, next_catalog_event, received_catalog_events,
  roll_back, start_catalog, start_watched_catalog, type_oid, unblock_connection,
}
import driver/server_connection.{
  caller_answer, start_caller, start_connection, start_in_ended_owner,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import gleam/erlang/process
import gleam/int.{to_string}
import gleam/list.{each, flatten, map}
import gleam/option.{None}
import gleam/otp/static_supervisor
import matchers/extract_driver_error_code.{extract_driver_error_code}
import matchers/extract_load_failure.{extract_load_failure}
import matchers/extract_type_kind.{extract_type_kind}

/// A type OID that no server of the tests has.
const unknown_type_id = 4_294_967_000

/// The statement that makes the schema `svc829_hidden`, which is not on
/// the search_path.
const hidden_schema = "CREATE SCHEMA svc829_hidden; "

const int4 = TypeDescription(23, "pg_catalog", "int4", Base)

const int4range = TypeDescription(3904, "pg_catalog", "int4range", Range(23))

/// The tests of the type catalog.
pub fn tests() -> TestSuite {
  describe("dream_postgres/driver/catalog", [
    group("on each driver server", map(driver_servers(), server_tests)),
    group(
      "loads",
      flatten([
        load_tests(),
        lookup_during_load_tests(),
        known_type_during_load_tests(),
      ]),
    ),
    group("the process", process_tests()),
  ])
}

// On each server --------------------------------------------------------------

fn server_tests(server: Server) {
  group(
    "PostgreSQL " <> to_string(server.version),
    flatten([
      map(built_in_type_cases(), built_in_type_test(server, _)),
      map(extension_type_cases(), extension_type_test(server, _)),
      new_type_tests(server),
    ]),
  )
}

/// A built-in type and its description.
type BuiltInTypeCase {
  BuiltInTypeCase(name: String, type_id: Int, expected: TypeDescription)
}

fn built_in_type_cases() -> List(BuiltInTypeCase) {
  [
    BuiltInTypeCase(
      "describes a base type, an array, a range, a multirange and a pseudo-type",
      23,
      int4,
    ),
    BuiltInTypeCase(
      "describes an array",
      1007,
      TypeDescription(1007, "pg_catalog", "_int4", Array(23)),
    ),
    BuiltInTypeCase("describes a range", 3904, int4range),
    BuiltInTypeCase(
      "describes a multirange",
      4451,
      TypeDescription(4451, "pg_catalog", "int4multirange", Multirange(3904)),
    ),
    BuiltInTypeCase(
      "describes a pseudo-type",
      2278,
      TypeDescription(2278, "pg_catalog", "void", Pseudo),
    ),
  ]
}

fn built_in_type_test(server: Server, test_case: BuiltInTypeCase) {
  it(test_case.name, fn() {
    // Arrange
    let connection = start_connection(server.port)
    let type_catalog = start_catalog()

    // Act
    let description =
      catalog.describe(type_catalog, connection, test_case.type_id, 5000)
    catalog.stop(type_catalog)
    stop(connection)

    // Assert
    description
    |> should
    |> be_ok
    |> be_equal(test_case.expected)
    |> or_fail_with("Expected the description of the built-in type")
  })
}

/// An extension type of the schema `public`, by its name.
type ExtensionTypeCase {
  ExtensionTypeCase(name: String, type_name: String)
}

fn extension_type_cases() -> List(ExtensionTypeCase) {
  [
    ExtensionTypeCase(
      "describes the extension types hstore, ltree and vector",
      "hstore",
    ),
    ExtensionTypeCase("describes the extension type ltree", "ltree"),
    ExtensionTypeCase("describes the extension type vector", "vector"),
  ]
}

fn extension_type_test(server: Server, test_case: ExtensionTypeCase) {
  it(test_case.name, fn() {
    // Arrange
    let connection = start_connection(server.port)
    let type_catalog = start_catalog()
    let type_id = type_oid(connection, test_case.type_name)

    // Act
    let description = catalog.describe(type_catalog, connection, type_id, 5000)
    catalog.stop(type_catalog)
    stop(connection)

    // Assert
    description
    |> should
    |> be_ok
    |> be_equal(TypeDescription(type_id, "public", test_case.type_name, Base))
    |> or_fail_with(
      "Expected " <> test_case.type_name <> " as a base type of public",
    )
  })
}

fn new_type_tests(server: Server) {
  [
    it(
      "describes an enum outside the search_path with its labels in order",
      fn() {
        // Arrange
        let connection = start_connection(server.port)
        let type_catalog = start_catalog()
        begin_with(
          connection,
          hidden_schema
            <> "CREATE TYPE svc829_hidden.mood AS ENUM ('sad', 'happy'); "
            <> "ALTER TYPE svc829_hidden.mood ADD VALUE 'calm' BEFORE 'happy'",
        )
        let type_id = type_oid(connection, "svc829_hidden.mood")

        // Act
        let description =
          catalog.describe(type_catalog, connection, type_id, 5000)
        roll_back(connection)
        catalog.stop(type_catalog)
        stop(connection)

        // Assert
        description
        |> should
        |> be_ok
        |> be_equal(TypeDescription(
          type_id,
          "svc829_hidden",
          "mood",
          Enum(["sad", "calm", "happy"]),
        ))
        |> or_fail_with(
          "Expected the enum of svc829_hidden with sad, calm, happy",
        )
      },
    ),
    it("describes a composite with its fields, without a dropped one", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let type_catalog = start_catalog()
      begin_with(
        connection,
        hidden_schema
          <> "CREATE TYPE svc829_hidden.trio AS (a int4, b text, c bool); "
          <> "ALTER TYPE svc829_hidden.trio DROP ATTRIBUTE b",
      )
      let type_id = type_oid(connection, "svc829_hidden.trio")

      // Act
      let description =
        catalog.describe(type_catalog, connection, type_id, 5000)
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(TypeDescription(
        type_id,
        "svc829_hidden",
        "trio",
        Composite([#("a", 23), #("c", 16)]),
      ))
      |> or_fail_with("Expected the composite with the fields a and c")
    }),
    ..domain_tests(server)
  ]
}

const domain_chain_setup =
  "CREATE DOMAIN svc829_hidden.inner_range AS int4range; "
  <> "CREATE DOMAIN svc829_hidden.outer_range AS svc829_hidden.inner_range"

fn domain_tests(server: Server) {
  [
    it("describes a domain over a domain as a domain over the inner one", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let type_catalog = start_catalog()
      begin_with(connection, hidden_schema <> domain_chain_setup)
      let inner = type_oid(connection, "svc829_hidden.inner_range")
      let outer = type_oid(connection, "svc829_hidden.outer_range")

      // Act
      let description = catalog.describe(type_catalog, connection, outer, 5000)
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(TypeDescription(
        outer,
        "svc829_hidden",
        "outer_range",
        Domain(inner),
      ))
      |> or_fail_with("Expected the outer domain over the inner one")
    }),
    it("follows a domain over a domain over a range to the range", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let type_catalog = start_catalog()
      begin_with(connection, hidden_schema <> domain_chain_setup)
      let outer = type_oid(connection, "svc829_hidden.outer_range")

      // Act
      let description =
        catalog.describe_underlying(type_catalog, connection, outer, 5000)
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(int4range)
      |> or_fail_with("Expected int4range under the outer domain")
    }),
    it("follows a domain over a composite to the composite", fn() {
      // Arrange
      let connection = start_connection(server.port)
      let type_catalog = start_catalog()
      begin_with(
        connection,
        hidden_schema
          <> "CREATE TYPE svc829_hidden.pair AS (left_side int4, right_side text); "
          <> "CREATE DOMAIN svc829_hidden.checked_pair AS svc829_hidden.pair",
      )
      let pair = type_oid(connection, "svc829_hidden.pair")
      let checked_pair = type_oid(connection, "svc829_hidden.checked_pair")

      // Act
      let description =
        catalog.describe_underlying(
          type_catalog,
          connection,
          checked_pair,
          5000,
        )
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(TypeDescription(
        pair,
        "svc829_hidden",
        "pair",
        Composite([#("left_side", 23), #("right_side", 25)]),
      ))
      |> or_fail_with("Expected the composite under the domain")
    }),
  ]
}

// Loads -----------------------------------------------------------------------

fn load_tests() {
  [
    it("loads one time for an unknown type, then gives UnknownType", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let type_catalog = start_catalog()

      // Act
      let _known = catalog.describe(type_catalog, connection, 23, 5000)
      let unknown =
        catalog.describe(type_catalog, connection, unknown_type_id, 5000)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      unknown
      |> should
      |> be_error
      |> be_equal(UnknownType(unknown_type_id))
      |> or_fail_with("Expected UnknownType after the second load")
    }),
    it("describes a known type from the first load", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let type_catalog = start_catalog()

      // Act
      let known = catalog.describe(type_catalog, connection, 23, 5000)
      let _unknown =
        catalog.describe(type_catalog, connection, unknown_type_id, 5000)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      known
      |> should
      |> be_ok
      |> be_equal(int4)
      |> or_fail_with("Expected int4 from the first load")
    }),
    it("starts one load for each lookup that does not find its type", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _known = catalog.describe(type_catalog, connection, 23, 5000)
      let _unknown =
        catalog.describe(type_catalog, connection, unknown_type_id, 5000)
      let loads = received_catalog_events(events)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      loads
      |> should
      |> be_equal([LoadStarted(1), LoadStarted(2)])
      |> or_fail_with("Expected load 1, then load 2 for the unknown type")
    }),
    it("finds a type that was made after the last load", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let type_catalog = start_catalog()
      let _known = catalog.describe(type_catalog, connection, 23, 5000)
      begin_with(
        connection,
        hidden_schema <> "CREATE TYPE svc829_hidden.later AS ENUM ('one')",
      )
      let type_id = type_oid(connection, "svc829_hidden.later")

      // Act
      let description =
        catalog.describe(type_catalog, connection, type_id, 5000)
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      description
      |> should
      |> be_ok
      |> extract_type_kind
      |> be_equal(Enum(["one"]))
      |> or_fail_with("Expected the new enum after a reload")
    }),
    ..failed_load_tests()
  ]
}

fn failed_load_tests() {
  [
    it(
      "starts each catalog empty, so a new one never has the types of an earlier one",
      fn() {
        // Arrange
        let connection = start_connection(first_driver_server.port)
        let other_connection = start_connection(first_driver_server.port)
        let earlier = start_catalog()
        begin_with(
          connection,
          hidden_schema <> "CREATE TYPE svc829_hidden.private AS ENUM ('one')",
        )
        let type_id = type_oid(connection, "svc829_hidden.private")
        let _described = catalog.describe(earlier, connection, type_id, 5000)
        let newer = start_catalog()

        // Act
        let answer = catalog.describe(newer, other_connection, type_id, 5000)
        roll_back(connection)
        catalog.stop(newer)
        catalog.stop(earlier)
        each([connection, other_connection], stop)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(UnknownType(type_id))
        |> or_fail_with("Expected UnknownType from the newer catalog")
      },
    ),
    it(
      "gives the server's error when the load fails in a failed transaction",
      fn() {
        // Arrange
        let connection = start_connection(first_driver_server.port)
        let type_catalog = start_catalog()
        let _began = run_script(connection, "BEGIN", 5000)
        let _division = run(connection, "SELECT 1/0", [], [], 5000)

        // Act
        let described = catalog.describe(type_catalog, connection, 23, 5000)
        roll_back(connection)
        catalog.stop(type_catalog)
        stop(connection)

        // Assert
        described
        |> should
        |> be_error
        |> extract_load_failure
        |> extract_driver_error_code
        |> be_equal("25P02")
        |> or_fail_with("Expected 25P02 from the load")
      },
    ),
    it("refuses the statement that fails the transaction", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let type_catalog = start_catalog()
      let _began = run_script(connection, "BEGIN", 5000)

      // Act
      let division = run(connection, "SELECT 1/0", [], [], 5000)
      let _described = catalog.describe(type_catalog, connection, 23, 5000)
      roll_back(connection)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      division
      |> should
      |> be_error
      |> extract_driver_error_code
      |> be_equal("22012")
      |> or_fail_with("Expected 22012 from the division by zero")
    }),
  ]
}

// A lookup during a load ------------------------------------------------------
//
// Load 1 waits on a blocked connection. A lookup on another connection, of
// a type that its transaction made after load 1 started, loads again at
// once, while load 1 still waits. Load 1 ends after load 2, so its older
// table does not replace the table of load 2. Each test has its own lock
// key.

const during_setup = "CREATE TYPE svc829_hidden.during AS ENUM ('one')"

fn lookup_during_load_tests() {
  [
    it("loads again for a lookup during a load, without waiting for it", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)
      let blocking = block_connection(control, blocked, 82_900)

      // Act
      let first =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, 23, 10_000)
        })
      let _first_event = next_catalog_event(events)
      begin_with(other, hidden_schema <> during_setup)
      let type_id = type_oid(other, "svc829_hidden.during")
      let during = catalog.describe(type_catalog, other, type_id, 5000)
      roll_back(other)
      unblock_connection(blocking)
      let _first_answer = caller_answer(first)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      during
      |> should
      |> be_ok
      |> extract_type_kind
      |> be_equal(Enum(["one"]))
      |> or_fail_with(
        "Expected load 2 to find the new type while load 1 waited",
      )
    }),
    it("starts load 1 for the lookup that waits", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)
      let blocking = block_connection(control, blocked, 82_902)

      // Act
      let first =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, 23, 10_000)
        })
      let first_event = next_catalog_event(events)
      begin_with(other, hidden_schema <> during_setup)
      let type_id = type_oid(other, "svc829_hidden.during")
      let _during = catalog.describe(type_catalog, other, type_id, 5000)
      roll_back(other)
      unblock_connection(blocking)
      let _first_answer = caller_answer(first)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      first_event
      |> should
      |> be_ok
      |> be_equal(LoadStarted(1))
      |> or_fail_with("Expected load 1 for the lookup that waits")
    }),
    it("starts only load 2 for the lookup during load 1", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)
      let blocking = block_connection(control, blocked, 82_903)

      // Act
      let first =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, 23, 10_000)
        })
      let _first_event = next_catalog_event(events)
      begin_with(other, hidden_schema <> during_setup)
      let type_id = type_oid(other, "svc829_hidden.during")
      let _during = catalog.describe(type_catalog, other, type_id, 5000)
      roll_back(other)
      unblock_connection(blocking)
      let _first_answer = caller_answer(first)
      let later_events = received_catalog_events(events)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      later_events
      |> should
      |> be_equal([LoadStarted(2)])
      |> or_fail_with("Expected only load 2 after load 1 started")
    }),
    it("answers the lookup that waited from its own load", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)
      let blocking = block_connection(control, blocked, 82_904)

      // Act
      let first =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, 23, 10_000)
        })
      let _first_event = next_catalog_event(events)
      begin_with(other, hidden_schema <> during_setup)
      let type_id = type_oid(other, "svc829_hidden.during")
      let _during = catalog.describe(type_catalog, other, type_id, 5000)
      roll_back(other)
      unblock_connection(blocking)
      let first_answer = caller_answer(first)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      first_answer
      |> should
      |> be_ok
      |> be_ok
      |> be_equal(int4)
      |> or_fail_with("Expected int4 for the lookup that waited")
    }),
  ]
}

// A known type during a load --------------------------------------------------
//
// While load 2 waits on a blocked connection, a lookup of a type of load 1
// is answered from load 1, with no load of its own. Each test has its own
// lock key.

fn known_type_during_load_tests() {
  [
    it("answers a known type during a load with the table it has", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _loaded = catalog.describe(type_catalog, other, 23, 5000)
      let blocking = block_connection(control, blocked, 82_901)
      let waiting =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, unknown_type_id, 10_000)
        })
      let _second_event = next_catalog_event(events)
      let text = catalog.describe(type_catalog, other, 25, 5000)
      unblock_connection(blocking)
      let _waiting_answer = caller_answer(waiting)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      text
      |> should
      |> be_ok
      |> be_equal(TypeDescription(25, "pg_catalog", "text", Base))
      |> or_fail_with("Expected text from load 1 while load 2 waited")
    }),
    it("starts load 1 for the first lookup", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _loaded = catalog.describe(type_catalog, connection, 23, 5000)
      let first_events = received_catalog_events(events)
      catalog.stop(type_catalog)
      stop(connection)

      // Assert
      first_events
      |> should
      |> be_equal([LoadStarted(1)])
      |> or_fail_with("Expected load 1 for the first lookup")
    }),
    it("starts load 2 for a lookup of an unknown type", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _loaded = catalog.describe(type_catalog, other, 23, 5000)
      let _first_events = received_catalog_events(events)
      let blocking = block_connection(control, blocked, 82_905)
      let waiting =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, unknown_type_id, 10_000)
        })
      let second_event = next_catalog_event(events)
      unblock_connection(blocking)
      let _waiting_answer = caller_answer(waiting)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      second_event
      |> should
      |> be_ok
      |> be_equal(LoadStarted(2))
      |> or_fail_with("Expected load 2 for the unknown type")
    }),
    it("starts no load for a known type during a load", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _loaded = catalog.describe(type_catalog, other, 23, 5000)
      let _first_events = received_catalog_events(events)
      let blocking = block_connection(control, blocked, 82_906)
      let waiting =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, unknown_type_id, 10_000)
        })
      let _second_event = next_catalog_event(events)
      let _text = catalog.describe(type_catalog, other, 25, 5000)
      let events_during = received_catalog_events(events)
      unblock_connection(blocking)
      let _waiting_answer = caller_answer(waiting)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      events_during
      |> should
      |> be_equal([])
      |> or_fail_with("Expected no load for text while load 2 waited")
    }),
    it("gives UnknownType to the lookup that waited for load 2", fn() {
      // Arrange
      let control = start_connection(first_driver_server.port)
      let blocked = start_connection(first_driver_server.port)
      let other = start_connection(first_driver_server.port)
      let events = process.new_subject()
      let type_catalog = start_watched_catalog(events)

      // Act
      let _loaded = catalog.describe(type_catalog, other, 23, 5000)
      let blocking = block_connection(control, blocked, 82_907)
      let waiting =
        start_caller(fn() {
          catalog.describe(type_catalog, blocked, unknown_type_id, 10_000)
        })
      let _second_event = next_catalog_event(events)
      let _text = catalog.describe(type_catalog, other, 25, 5000)
      unblock_connection(blocking)
      let waiting_answer = caller_answer(waiting)
      catalog.stop(type_catalog)
      each([control, blocked, other], stop)

      // Assert
      waiting_answer
      |> should
      |> be_ok
      |> be_error
      |> be_equal(UnknownType(unknown_type_id))
      |> or_fail_with("Expected UnknownType after load 2")
    }),
  ]
}

// The process -----------------------------------------------------------------

fn process_tests() {
  [
    it("gives CatalogProcessDown after the catalog stopped", fn() {
      // Arrange
      let connection = start_connection(first_driver_server.port)
      let type_catalog = start_catalog()

      // Act
      catalog.stop(type_catalog)
      catalog.stop(type_catalog)
      let answer = catalog.describe(type_catalog, connection, 23, 5000)
      stop(connection)

      // Assert
      answer
      |> should
      |> be_error
      |> be_equal(CatalogProcessDown)
      |> or_fail_with("Expected CatalogProcessDown")
    }),
    it("starts as a child of a supervisor", fn() {
      // Arrange
      let supervisor =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(supervised(None))

      // Act
      let started =
        start_in_ended_owner(fn() { static_supervisor.start(supervisor) })

      // Assert
      started
      |> should
      |> be_ok
      |> be_ok
      |> or_fail_with("Expected the supervisor to start the catalog")
    }),
  ]
}
