//// Tests for `dream_postgres/driver/catalog`, the type catalog, on the
//// driver servers of PostgreSQL 16 to 19.
////
//// Setup hooks start each catalog with its connection and stop both after
//// the test. The tests make their types in a transaction, in a schema
//// whose name no other test uses, and the teardown rolls it back, so no
//// type stays on the server and other tests never see them. A load that
//// must stay open waits behind an advisory lock of a control connection,
//// with a key that no other test uses, so no test sleeps. The tests of a
//// lock wait share one act, so the wait happens once.

import dream_postgres/driver/catalog.{
  type CatalogError, type CatalogEvent, CatalogProcessDown, LoadStarted,
  UnknownType, supervised,
}
import dream_postgres/driver/connection.{run}
import dream_postgres/internal/cell.{
  type TypeDescription, Array, Base, Composite, Domain, Enum, Multirange, Pseudo,
  Range, TypeDescription,
}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{after_each, before_each, describe, group, it}
import driver/server_catalog.{
  type CatalogSession, type LoadRace, type RaceOutcome, begin_in_schema,
  begin_with_types, block_connection, catalog_session_setup,
  describe_in_new_catalog, find_part_type, find_type, load_found_type, load_type,
  load_unknown_type, next_catalog_event, on_session_connection, race_act_setup,
  received_catalog_events, start_test_catalog, start_test_watched_catalog,
  stop_catalog_session, type_oid, unblock_connection,
}
import driver/server_connection.{
  caller_answer, run_failing_statement, run_setup_script, start_caller,
  start_in_ended_owner,
}
import driver/servers.{type Server, driver_servers, first_driver_server}
import gleam/int.{to_string}
import gleam/list.{flatten, map}
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/result.{map_error, try}
import gleam/string.{inspect}
import matchers/extract_load_failure.{extract_load_failure}
import matchers/extract_run_refusal_code.{extract_run_refusal_code}
import matchers/extract_type_kind.{extract_type_kind}

/// A type OID that no server of the tests has.
const unknown_type_id = 4_294_967_000

const int4 = TypeDescription(23, "pg_catalog", "int4", Base)

const int4range = TypeDescription(3904, "pg_catalog", "int4range", Range(23))

/// The tests of the type catalog. The describes run one after the other;
/// the tests of one group run at the same time.
pub fn tests() -> TestSuite {
  suite.group("dream_postgres/driver/catalog", [
    session_tests(),
    lookup_during_load_tests(),
    known_type_during_load_tests(),
    supervisor_tests(),
  ])
}

// With a catalog of its own ---------------------------------------------------

fn session_tests() -> TestSuite {
  describe(
    "with a catalog of its own",
    catalog_session_setup(first_driver_server),
    [
      after_each(stop_catalog_session),
      group("on each driver server", map(driver_servers(), server_tests)),
      group("loads", load_tests()),
      group("the loads it tells of", watched_load_tests()),
      group("failed loads", failed_load_tests()),
      group("the process", process_tests()),
    ],
  )
}

fn server_tests(server: Server) {
  group(
    "PostgreSQL " <> to_string(server.version),
    flatten([
      [before_each(start_test_catalog(server))],
      map(built_in_type_cases(), built_in_type_test),
      map(extension_type_cases(), extension_type_test),
      new_type_tests(),
      domain_tests(),
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

fn built_in_type_test(test_case: BuiltInTypeCase) {
  it(test_case.name, fn(session: CatalogSession) {
    // Act
    let description =
      catalog.describe(
        session.catalog,
        session.connection,
        test_case.type_id,
        5000,
      )

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

fn extension_type_test(test_case: ExtensionTypeCase) {
  group("the extension type " <> test_case.type_name, [
    before_each(find_type(test_case.type_name)),
    it(test_case.name, fn(session: CatalogSession) {
      // Act
      let description =
        catalog.describe(
          session.catalog,
          session.connection,
          session.type_id,
          5000,
        )

      // Assert
      description
      |> should
      |> be_ok
      |> be_equal(TypeDescription(
        session.type_id,
        "public",
        test_case.type_name,
        Base,
      ))
      |> or_fail_with(
        "Expected " <> test_case.type_name <> " as a base type of public",
      )
    }),
  ])
}

fn new_type_tests() {
  [
    group("an enum", [
      before_each(begin_with_types(
        "CREATE TYPE {schema}.mood AS ENUM ('sad', 'happy'); "
        <> "ALTER TYPE {schema}.mood ADD VALUE 'calm' BEFORE 'happy'",
      )),
      before_each(find_type("{schema}.mood")),
      it(
        "describes an enum outside the search_path with its labels in order",
        fn(session: CatalogSession) {
          // Act
          let description =
            catalog.describe(
              session.catalog,
              session.connection,
              session.type_id,
              5000,
            )

          // Assert
          description
          |> should
          |> be_ok
          |> be_equal(TypeDescription(
            session.type_id,
            session.schema,
            "mood",
            Enum(["sad", "calm", "happy"]),
          ))
          |> or_fail_with(
            "Expected the enum of its schema with sad, calm, happy",
          )
        },
      ),
    ]),
    group("a composite", [
      before_each(begin_with_types(
        "CREATE TYPE {schema}.trio AS (a int4, b text, c bool); "
        <> "ALTER TYPE {schema}.trio DROP ATTRIBUTE b",
      )),
      before_each(find_type("{schema}.trio")),
      it(
        "describes a composite with its fields, without a dropped one",
        fn(session: CatalogSession) {
          // Act
          let description =
            catalog.describe(
              session.catalog,
              session.connection,
              session.type_id,
              5000,
            )

          // Assert
          description
          |> should
          |> be_ok
          |> be_equal(TypeDescription(
            session.type_id,
            session.schema,
            "trio",
            Composite([#("a", 23), #("c", 16)]),
          ))
          |> or_fail_with("Expected the composite with the fields a and c")
        },
      ),
    ]),
  ]
}

const domain_chain_setup =
  "CREATE DOMAIN {schema}.inner_range AS int4range; "
  <> "CREATE DOMAIN {schema}.outer_range AS {schema}.inner_range"

fn domain_tests() {
  [
    group("a domain over a domain", [
      before_each(begin_with_types(domain_chain_setup)),
      before_each(find_type("{schema}.outer_range")),
      before_each(find_part_type("{schema}.inner_range")),
      it(
        "describes a domain over a domain as a domain over the inner one",
        fn(session: CatalogSession) {
          // Act
          let description =
            catalog.describe(
              session.catalog,
              session.connection,
              session.type_id,
              5000,
            )

          // Assert
          description
          |> should
          |> be_ok
          |> be_equal(TypeDescription(
            session.type_id,
            session.schema,
            "outer_range",
            Domain(session.part_type_id),
          ))
          |> or_fail_with("Expected the outer domain over the inner one")
        },
      ),
      it(
        "follows a domain over a domain over a range to the range",
        fn(session: CatalogSession) {
          // Act
          let description =
            catalog.describe_underlying(
              session.catalog,
              session.connection,
              session.type_id,
              5000,
            )

          // Assert
          description
          |> should
          |> be_ok
          |> be_equal(int4range)
          |> or_fail_with("Expected int4range under the outer domain")
        },
      ),
    ]),
    group("a domain over a composite", [
      before_each(begin_with_types(
        "CREATE TYPE {schema}.pair AS (left_side int4, right_side text); "
        <> "CREATE DOMAIN {schema}.checked_pair AS {schema}.pair",
      )),
      before_each(find_type("{schema}.checked_pair")),
      before_each(find_part_type("{schema}.pair")),
      it(
        "follows a domain over a composite to the composite",
        fn(session: CatalogSession) {
          // Act
          let description =
            catalog.describe_underlying(
              session.catalog,
              session.connection,
              session.type_id,
              5000,
            )

          // Assert
          description
          |> should
          |> be_ok
          |> be_equal(TypeDescription(
            session.part_type_id,
            session.schema,
            "pair",
            Composite([#("left_side", 23), #("right_side", 25)]),
          ))
          |> or_fail_with("Expected the composite under the domain")
        },
      ),
    ]),
  ]
}

// Loads -----------------------------------------------------------------------

fn load_tests() {
  [
    before_each(start_test_catalog(first_driver_server)),
    group("after a load", [
      before_each(load_type(23)),
      it(
        "loads one time for an unknown type, then gives UnknownType",
        fn(session: CatalogSession) {
          // Act
          let unknown =
            catalog.describe(
              session.catalog,
              session.connection,
              unknown_type_id,
              5000,
            )

          // Assert
          unknown
          |> should
          |> be_error
          |> be_equal(UnknownType(unknown_type_id))
          |> or_fail_with("Expected UnknownType after the second load")
        },
      ),
      group("and a new type", [
        before_each(begin_with_types(
          "CREATE TYPE {schema}.later AS ENUM ('one')",
        )),
        before_each(find_type("{schema}.later")),
        it(
          "finds a type that was made after the last load",
          fn(session: CatalogSession) {
            // Act
            let description =
              catalog.describe(
                session.catalog,
                session.connection,
                session.type_id,
                5000,
              )

            // Assert
            description
            |> should
            |> be_ok
            |> extract_type_kind
            |> be_equal(Enum(["one"]))
            |> or_fail_with("Expected the new enum after a reload")
          },
        ),
      ]),
    ]),
    it(
      "describes a known type from the first load",
      fn(session: CatalogSession) {
        // Act
        let known =
          catalog.describe(session.catalog, session.connection, 23, 5000)

        // Assert
        known
        |> should
        |> be_ok
        |> be_equal(int4)
        |> or_fail_with("Expected int4 from the first load")
      },
    ),
    group("after an earlier catalog loaded a type of its transaction", [
      before_each(begin_with_types(
        "CREATE TYPE {schema}.private AS ENUM ('one')",
      )),
      before_each(find_type("{schema}.private")),
      before_each(load_found_type),
      it(
        "starts each catalog empty, so a new one never has the types of an earlier one",
        fn(session: CatalogSession) {
          // Act
          let answer =
            describe_in_new_catalog(first_driver_server, session.type_id)

          // Assert
          answer
          |> should
          |> be_ok
          |> be_error
          |> be_equal(UnknownType(session.type_id))
          |> or_fail_with("Expected UnknownType from the newer catalog")
        },
      ),
    ]),
  ]
}

fn watched_load_tests() {
  [
    before_each(start_test_watched_catalog(first_driver_server)),
    before_each(load_type(23)),
    before_each(load_unknown_type(unknown_type_id)),
    it(
      "starts one load for each lookup that does not find its type",
      fn(session: CatalogSession) {
        // Act
        let loads = received_catalog_events(session.events)

        // Assert
        loads
        |> should
        |> be_equal([LoadStarted(1), LoadStarted(2)])
        |> or_fail_with("Expected load 1, then load 2 for the unknown type")
      },
    ),
  ]
}

fn failed_load_tests() {
  [
    before_each(start_test_catalog(first_driver_server)),
    before_each(on_session_connection(run_setup_script("BEGIN"))),
    group("in a failed transaction", [
      before_each(on_session_connection(run_failing_statement("SELECT 1/0"))),
      it(
        "gives the server's error when the load fails in a failed transaction",
        fn(session: CatalogSession) {
          // Act
          let described =
            catalog.describe(session.catalog, session.connection, 23, 5000)

          // Assert
          described
          |> should
          |> be_error
          |> extract_load_failure
          |> extract_run_refusal_code
          |> be_equal("25P02")
          |> or_fail_with("Expected 25P02 from the load")
        },
      ),
    ]),
    it(
      "refuses the statement that fails the transaction",
      fn(session: CatalogSession) {
        // Act
        let division =
          run(
            session.connection,
            connection.statement("SELECT 1/0"),
            [],
            [],
            5000,
          )

        // Assert
        division
        |> should
        |> be_error
        |> extract_run_refusal_code
        |> be_equal("22012")
        |> or_fail_with("Expected 22012 from the division by zero")
      },
    ),
  ]
}

fn process_tests() {
  [
    before_each(start_test_catalog(first_driver_server)),
    it(
      "gives CatalogProcessDown after the catalog stopped",
      fn(session: CatalogSession) {
        // Act
        catalog.stop(session.catalog)
        catalog.stop(session.catalog)
        let answer =
          catalog.describe(session.catalog, session.connection, 23, 5000)

        // Assert
        answer
        |> should
        |> be_error
        |> be_equal(CatalogProcessDown)
        |> or_fail_with("Expected CatalogProcessDown")
      },
    ),
  ]
}

// A lookup during a load: one act for four tests -------------------------------
//
// Load 1 waits on a blocked connection. A lookup on another connection, of
// a type that its transaction made after load 1 started, loads again at
// once, while load 1 still waits. Load 1 ends after load 2, so its older
// table does not replace the table of load 2.

type DuringLoad {
  DuringLoad(
    first_event: Result(CatalogEvent, Nil),
    during: Result(TypeDescription, CatalogError),
    later_events: List(CatalogEvent),
    first_answer: Result(TypeDescription, CatalogError),
  )
}

fn look_up_during_load(race: LoadRace) -> Result(DuringLoad, String) {
  use blocking <- try(block_connection(
    race.control,
    race.blocked,
    race.lock_key,
  ))
  let first =
    start_caller(fn() {
      catalog.describe(race.catalog, race.blocked, 23, 10_000)
    })
  let first_event = next_catalog_event(race.events)
  use _began <- try(begin_in_schema(
    race.other,
    race.schema,
    "CREATE TYPE {schema}.during AS ENUM ('one')",
  ))
  use type_id <- try(type_oid(race.other, race.schema <> ".during"))
  let during = catalog.describe(race.catalog, race.other, type_id, 5000)
  use _unblocked <- try(unblock_connection(blocking))
  use first_answer <- try(caller_answer(first))
  let later_events = received_catalog_events(race.events)
  Ok(DuringLoad(first_event:, during:, later_events:, first_answer:))
}

fn lookup_during_load_tests() -> TestSuite {
  describe(
    "a lookup during a load",
    race_act_setup(first_driver_server, look_up_during_load),
    [
      it(
        "loads again for a lookup during a load, without waiting for it",
        fn(shared: RaceOutcome(DuringLoad)) {
          shared.outcome.during
          |> should
          |> be_ok
          |> extract_type_kind
          |> be_equal(Enum(["one"]))
          |> or_fail_with(
            "Expected load 2 to find the new type while load 1 waited",
          )
        },
      ),
      it(
        "starts load 1 for the lookup that waits",
        fn(shared: RaceOutcome(DuringLoad)) {
          shared.outcome.first_event
          |> should
          |> be_ok
          |> be_equal(LoadStarted(1))
          |> or_fail_with("Expected load 1 for the lookup that waits")
        },
      ),
      it(
        "starts only load 2 for the lookup during load 1",
        fn(shared: RaceOutcome(DuringLoad)) {
          shared.outcome.later_events
          |> should
          |> be_equal([LoadStarted(2)])
          |> or_fail_with("Expected only load 2 after load 1 started")
        },
      ),
      it(
        "answers the lookup that waited from its own load",
        fn(shared: RaceOutcome(DuringLoad)) {
          shared.outcome.first_answer
          |> should
          |> be_ok
          |> be_equal(int4)
          |> or_fail_with("Expected int4 for the lookup that waited")
        },
      ),
    ],
  )
}

// A known type during a load: one act for five tests ---------------------------
//
// While load 2 waits on a blocked connection, a lookup of a type of load 1
// is answered from load 1, with no load of its own.

type KnownDuringLoad {
  KnownDuringLoad(
    first_events: List(CatalogEvent),
    second_event: Result(CatalogEvent, Nil),
    text: Result(TypeDescription, CatalogError),
    events_during: List(CatalogEvent),
    waiting_answer: Result(TypeDescription, CatalogError),
  )
}

fn look_up_known_during_load(
  race: LoadRace,
) -> Result(KnownDuringLoad, String) {
  use _loaded <- try(
    catalog.describe(race.catalog, race.other, 23, 5000)
    |> map_error(inspect),
  )
  let first_events = received_catalog_events(race.events)
  use blocking <- try(block_connection(
    race.control,
    race.blocked,
    race.lock_key,
  ))
  let waiting =
    start_caller(fn() {
      catalog.describe(race.catalog, race.blocked, unknown_type_id, 10_000)
    })
  let second_event = next_catalog_event(race.events)
  let text = catalog.describe(race.catalog, race.other, 25, 5000)
  let events_during = received_catalog_events(race.events)
  use _unblocked <- try(unblock_connection(blocking))
  use waiting_answer <- try(caller_answer(waiting))
  Ok(KnownDuringLoad(
    first_events:,
    second_event:,
    text:,
    events_during:,
    waiting_answer:,
  ))
}

fn known_type_during_load_tests() -> TestSuite {
  describe(
    "a known type during a load",
    race_act_setup(first_driver_server, look_up_known_during_load),
    [
      it(
        "answers a known type during a load with the table it has",
        fn(shared: RaceOutcome(KnownDuringLoad)) {
          shared.outcome.text
          |> should
          |> be_ok
          |> be_equal(TypeDescription(25, "pg_catalog", "text", Base))
          |> or_fail_with("Expected text from load 1 while load 2 waited")
        },
      ),
      it(
        "starts load 1 for the first lookup",
        fn(shared: RaceOutcome(KnownDuringLoad)) {
          shared.outcome.first_events
          |> should
          |> be_equal([LoadStarted(1)])
          |> or_fail_with("Expected load 1 for the first lookup")
        },
      ),
      it(
        "starts load 2 for a lookup of an unknown type",
        fn(shared: RaceOutcome(KnownDuringLoad)) {
          shared.outcome.second_event
          |> should
          |> be_ok
          |> be_equal(LoadStarted(2))
          |> or_fail_with("Expected load 2 for the unknown type")
        },
      ),
      it(
        "starts no load for a known type during a load",
        fn(shared: RaceOutcome(KnownDuringLoad)) {
          shared.outcome.events_during
          |> should
          |> be_equal([])
          |> or_fail_with("Expected no load for text while load 2 waited")
        },
      ),
      it(
        "gives UnknownType to the lookup that waited for load 2",
        fn(shared: RaceOutcome(KnownDuringLoad)) {
          shared.outcome.waiting_answer
          |> should
          |> be_error
          |> be_equal(UnknownType(unknown_type_id))
          |> or_fail_with("Expected UnknownType after load 2")
        },
      ),
    ],
  )
}

// As a child of a supervisor --------------------------------------------------

fn supervisor_tests() -> TestSuite {
  describe("as a child of a supervisor", context.value(Nil), [
    it("starts as a child of a supervisor", fn(_nothing) {
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
  ])
}
