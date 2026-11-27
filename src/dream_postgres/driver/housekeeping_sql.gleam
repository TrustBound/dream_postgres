//// The statements that the driver sends for its own housekeeping, from its
//// own processes: the catalog load, a pool member's health check, and a
//// pool member's ROLLBACK. The set is closed: its only values are the
//// constants of this module, and no function makes one from a `String`.
////
//// So their encoding cannot fail. Each value is a fixed text with no zero
//// byte, far below the 2 GiB limit of a message length, and no value has a
//// parameter. `query_message` and `prepare_and_run_messages` give the
//// bytes with no `Result`. The two tests of
//// `test/driver/housekeeping_sql_test.gleam` check the exact bytes of each
//// value in both protocols. A new value of this module must join the
//// lists of both tests.
////
//// A listener's LISTEN and UNLISTEN are not in the set: each holds the
//// caller's channel, so its encoding stays checked.
////
//// This module is internal to dream_postgres.

import gleam/bit_array.{byte_size}

/// A statement that the driver sends for its own housekeeping.
pub opaque type HousekeepingSql {
  HousekeepingSql(text: String)
}

/// The catalog load. It is one statement, so its rows come from one
/// snapshot, also inside a transaction of the caller. Each row has 11 text
/// columns: the row kind (`type`, `label` or `field`), the type OID, a
/// position that orders the labels of an enum and the fields of a
/// composite, and the facts of the row kind. A range or multirange part
/// that a type does not have is 0. `driver/catalog_table` reads the rows.
pub const catalog_load =
  HousekeepingSql(
    "SELECT 'type', t.oid, NULL::float8, n.nspname::text, t.typname::text, t.typtype::text, t.typcategory::text, t.typelem::text, t.typbasetype::text, COALESCE(r.rngsubtype, 0)::text, COALESCE(m.rngtypid, 0)::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace LEFT JOIN pg_range r ON r.rngtypid = t.oid LEFT JOIN pg_range m ON m.rngmultitypid = t.oid UNION ALL SELECT 'label', e.enumtypid, e.enumsortorder::float8, e.enumlabel::text, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM pg_enum e UNION ALL SELECT 'field', t.oid, a.attnum::float8, a.attname::text, a.atttypid::text, NULL, NULL, NULL, NULL, NULL, NULL FROM pg_type t JOIN pg_attribute a ON a.attrelid = t.typrelid WHERE t.typtype = 'c' AND a.attnum > 0 AND NOT a.attisdropped ORDER BY 1, 2, 3",
  )

/// The health check of an idle pool member.
pub const health_check = HousekeepingSql("SELECT 1")

/// The ROLLBACK of a pool member whose connection comes back inside a
/// transaction.
pub const rollback = HousekeepingSql("ROLLBACK")

/// The Query message of the statement, for the simple query protocol.
///
/// ## Parameters
///
/// - `sql`: the statement
///
/// ## Returns
///
/// The bytes of one Query message.
pub fn query_message(sql: HousekeepingSql) -> BitArray {
  <<"Q", { byte_size(<<sql.text:utf8>>) + 5 }:32, sql.text:utf8, 0>>
}

/// The messages that prepare and run the statement in one round trip with
/// the extended protocol: Parse of the unnamed statement with no parameter
/// type, Bind of the unnamed portal with no parameter and text results,
/// Describe of the portal, Execute with no row limit, and Sync.
///
/// ## Parameters
///
/// - `sql`: the statement
///
/// ## Returns
///
/// The bytes of the five messages.
pub fn prepare_and_run_messages(sql: HousekeepingSql) -> BitArray {
  <<
    "P",
    { byte_size(<<sql.text:utf8>>) + 8 }:32,
    0,
    sql.text:utf8,
    0,
    0:16,
    "B",
    12:32,
    0,
    0,
    0:16,
    0:16,
    0:16,
    "D",
    6:32,
    "P",
    0,
    "E",
    9:32,
    0,
    0:32,
    "S",
    4:32,
  >>
}
