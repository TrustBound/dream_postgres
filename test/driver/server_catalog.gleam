//// Test fixtures for the type catalog tests on the driver servers: a
//// started catalog, the events it sent, types made in a transaction, the
//// OID of a type by its name, and a connection that waits behind an
//// advisory lock of a control connection. A test stops each catalog and
//// each connection that it starts.

import dream_postgres/driver/catalog.{type Catalog, type CatalogEvent, start}
import dream_postgres/driver/connection.{
  type Connection, type DriverError, type Outcome, run_script,
}
import driver/server_connection.{
  type Caller, caller_answer, query_text, start_caller, wait_for_lock_waiter,
}
import gleam/erlang/process.{type Subject}
import gleam/int.{parse, to_string}
import gleam/option.{type Option, None, Some}
import gleam/string.{inspect}

// Catalogs --------------------------------------------------------------------

/// Starts a catalog with no subscriber. It panics with the start error
/// when the catalog does not start: that is a setup failure, not an
/// assertion.
pub fn start_catalog() -> Catalog {
  start_catalog_with(None)
}

/// Starts a catalog that sends its events to `events`. It panics with the
/// start error when the catalog does not start.
pub fn start_watched_catalog(events: Subject(CatalogEvent)) -> Catalog {
  start_catalog_with(Some(events))
}

fn start_catalog_with(events: Option(Subject(CatalogEvent))) -> Catalog {
  case start(events) {
    Ok(type_catalog) -> type_catalog
    Error(error) -> panic as { "could not start a catalog: " <> inspect(error) }
  }
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

// Types -----------------------------------------------------------------------

/// Begins a transaction on the connection and runs `setup` in it. It
/// panics when the setup fails: that is a setup failure.
pub fn begin_with(connection: Connection, setup: String) -> Nil {
  case run_script(connection, "BEGIN; " <> setup, 5000) {
    Ok(_outcomes) -> Nil
    Error(error) -> panic as { "could not run the setup: " <> inspect(error) }
  }
}

/// Rolls back the transaction of the connection, so no type that the test
/// made stays on the server.
pub fn roll_back(connection: Connection) -> Nil {
  let _rolled_back = run_script(connection, "ROLLBACK", 5000)
  Nil
}

/// The OID of the type `type_name`, as the connection sees it. It panics
/// when the server does not know the type: that is a setup failure.
pub fn type_oid(connection: Connection, type_name: String) -> Int {
  let text =
    query_text(connection, "SELECT '" <> type_name <> "'::regtype::oid::text")
  case parse(text) {
    Ok(type_id) -> type_id
    Error(Nil) -> panic as { "expected an OID: " <> text }
  }
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
) -> BlockedConnection {
  let lock = "SELECT pg_advisory_lock(" <> to_string(key) <> ")"
  let _locked = run_script(control, lock, 5000)
  let blocker = start_caller(fn() { run_script(blocked, lock, 10_000) })
  let _waited = wait_for_lock_waiter(control, key)
  BlockedConnection(control:, blocked:, key:, blocker:)
}

/// Lets the blocked connection go on, waits until it took the lock, and
/// lets the lock go on it too.
pub fn unblock_connection(blocked: BlockedConnection) -> Nil {
  let unlock = "SELECT pg_advisory_unlock(" <> to_string(blocked.key) <> ")"
  let _unlocked = run_script(blocked.control, unlock, 5000)
  let _answer = caller_answer(blocked.blocker)
  let _released = run_script(blocked.blocked, unlock, 5000)
  Nil
}
