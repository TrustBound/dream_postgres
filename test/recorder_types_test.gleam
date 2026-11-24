//// Each kind of value that a query returns survives a record and playback
//// round trip with the value it had live. Each test records one query
//// against the real PostgreSQL 16 server, plays it back with no database,
//// and compares both results with the exact term of the driver.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_postgres/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/database_url
import fixtures/recordings
import fixtures/test_database
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process

pub fn tests() -> TestSuite {
  describe("recorder round trip of each value type", [
    it("int2", fn() {
      // Act
      let results = round_trip("SELECT 7::int2")

      // Assert
      results
      |> should
      |> be_equal(#(Ok([row([dynamic.int(7)])]), Ok([row([dynamic.int(7)])])))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("int4", fn() {
      // Act
      let results = round_trip("SELECT 2147483647::int4")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.int(2_147_483_647)])]),
        Ok([row([dynamic.int(2_147_483_647)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("int8", fn() {
      // Act
      let results = round_trip("SELECT 9223372036854775807::int8")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.int(9_223_372_036_854_775_807)])]),
        Ok([row([dynamic.int(9_223_372_036_854_775_807)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("float4", fn() {
      // Act
      let results = round_trip("SELECT 1.5::float4")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.float(1.5)])]),
        Ok([row([dynamic.float(1.5)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("float8", fn() {
      // Act
      let results = round_trip("SELECT 0.1::float8")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.float(0.1)])]),
        Ok([row([dynamic.float(0.1)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a float8 of 1e300", fn() {
      // Act
      let results = round_trip("SELECT 1e300::float8")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.float(1.0e300)])]),
        Ok([row([dynamic.float(1.0e300)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a float8 of Infinity", fn() {
      // Act
      let results = round_trip("SELECT 'Infinity'::float8")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([atom_value("infinity")])]),
        Ok([row([atom_value("infinity")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a float8 of NaN", fn() {
      // Act
      let results = round_trip("SELECT 'NaN'::float8")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([atom_value("NaN")])]),
        Ok([row([atom_value("NaN")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("text", fn() {
      // Act
      let results = round_trip("SELECT 'héllo € 日本'::text")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("héllo € 日本")])]),
        Ok([row([dynamic.string("héllo € 日本")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("text with a quote, a backslash and a line break", fn() {
      // Act
      let results = round_trip("SELECT E'a\"b\\\\c\\nd'::text")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("a\"b\\c\nd")])]),
        Ok([row([dynamic.string("a\"b\\c\nd")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("varchar", fn() {
      // Act
      let results = round_trip("SELECT 'x'::varchar")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("x")])]),
        Ok([row([dynamic.string("x")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("bytea that is not UTF-8", fn() {
      // Act
      let results = round_trip("SELECT '\\x00ff'::bytea")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.bit_array(<<0, 255>>)])]),
        Ok([row([dynamic.bit_array(<<0, 255>>)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("bytea that is UTF-8", fn() {
      // Act
      let results = round_trip("SELECT '\\x6869'::bytea")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.bit_array(<<"hi":utf8>>)])]),
        Ok([row([dynamic.bit_array(<<"hi":utf8>>)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("boolean true", fn() {
      // Act
      let results = round_trip("SELECT true")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.bool(True)])]),
        Ok([row([dynamic.bool(True)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("boolean false", fn() {
      // Act
      let results = round_trip("SELECT false")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.bool(False)])]),
        Ok([row([dynamic.bool(False)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("null", fn() {
      // Act
      let results = round_trip("SELECT NULL::int")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([atom_value("null")])]),
        Ok([row([atom_value("null")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("an integer array", fn() {
      // Act
      let results = round_trip("SELECT ARRAY[1, 2, 3]")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([dynamic.list([dynamic.int(1), dynamic.int(2), dynamic.int(3)])]),
        ]),
        Ok([
          row([dynamic.list([dynamic.int(1), dynamic.int(2), dynamic.int(3)])]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a text array with a null", fn() {
      // Act
      let results = round_trip("SELECT ARRAY['a', NULL]")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.list([dynamic.string("a"), atom_value("null")])])]),
        Ok([row([dynamic.list([dynamic.string("a"), atom_value("null")])])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("an empty array", fn() {
      // Act
      let results = round_trip("SELECT ARRAY[]::int[]")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.list([])])]),
        Ok([row([dynamic.list([])])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a timestamp", fn() {
      // Act
      let results = round_trip("SELECT '2026-11-23 10:30:15.123456'::timestamp")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.int(1_795_429_815_123_456)])]),
        Ok([row([dynamic.int(1_795_429_815_123_456)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a timestamptz", fn() {
      // Act
      let results = round_trip("SELECT '2026-11-23 10:30:15+02'::timestamptz")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([
            tuple([
              tuple([dynamic.int(2026), dynamic.int(11), dynamic.int(23)]),
              tuple([dynamic.int(8), dynamic.int(30), dynamic.int(15)]),
            ]),
          ]),
        ]),
        Ok([
          row([
            tuple([
              tuple([dynamic.int(2026), dynamic.int(11), dynamic.int(23)]),
              tuple([dynamic.int(8), dynamic.int(30), dynamic.int(15)]),
            ]),
          ]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a date", fn() {
      // Act
      let results = round_trip("SELECT '2026-11-23'::date")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([tuple([dynamic.int(2026), dynamic.int(11), dynamic.int(23)])])]),
        Ok([row([tuple([dynamic.int(2026), dynamic.int(11), dynamic.int(23)])])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a time with a fraction", fn() {
      // Act
      let results = round_trip("SELECT '10:30:15.5'::time")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([tuple([dynamic.int(10), dynamic.int(30), dynamic.float(15.5)])]),
        ]),
        Ok([
          row([tuple([dynamic.int(10), dynamic.int(30), dynamic.float(15.5)])]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a time with no fraction", fn() {
      // Act
      let results = round_trip("SELECT '10:30:15'::time")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([tuple([dynamic.int(10), dynamic.int(30), dynamic.int(15)])])]),
        Ok([row([tuple([dynamic.int(10), dynamic.int(30), dynamic.int(15)])])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a numeric with a fraction", fn() {
      // Act
      let results = round_trip("SELECT 12.345::numeric")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.float(12.345)])]),
        Ok([row([dynamic.float(12.345)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a numeric with no fraction", fn() {
      // Act
      let results = round_trip("SELECT 12::numeric")

      // Assert
      results
      |> should
      |> be_equal(#(Ok([row([dynamic.int(12)])]), Ok([row([dynamic.int(12)])])))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a numeric of NaN", fn() {
      // Act
      let results = round_trip("SELECT 'NaN'::numeric")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([atom_value("NaN")])]),
        Ok([row([atom_value("NaN")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a UUID as text", fn() {
      // Act
      let results =
        round_trip("SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid::text")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")])]),
        Ok([row([dynamic.string("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a uuid", fn() {
      // Act
      let results =
        round_trip("SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([
            dynamic.bit_array(<<
              0xa0,
              0xee,
              0xbc,
              0x99,
              0x9c,
              0x0b,
              0x4e,
              0xf8,
              0xbb,
              0x6d,
              0x6b,
              0xb9,
              0xbd,
              0x38,
              0x0a,
              0x11,
            >>),
          ]),
        ]),
        Ok([
          row([
            dynamic.bit_array(<<
              0xa0,
              0xee,
              0xbc,
              0x99,
              0x9c,
              0x0b,
              0x4e,
              0xf8,
              0xbb,
              0x6d,
              0x6b,
              0xb9,
              0xbd,
              0x38,
              0x0a,
              0x11,
            >>),
          ]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("json as text", fn() {
      // Act
      let results = round_trip("SELECT '{\"a\": [1, 2]}'::json")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("{\"a\": [1, 2]}")])]),
        Ok([row([dynamic.string("{\"a\": [1, 2]}")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("jsonb as text", fn() {
      // Act
      let results = round_trip("SELECT '{\"a\": [1, 2]}'::jsonb")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.string("{\"a\": [1, 2]}")])]),
        Ok([row([dynamic.string("{\"a\": [1, 2]}")])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("an interval", fn() {
      // Act
      let results = round_trip("SELECT interval '1 day'")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([
            tuple([
              atom_value("interval"),
              tuple([
                tuple([dynamic.int(0), dynamic.int(0), dynamic.int(0)]),
                dynamic.int(1),
                dynamic.int(0),
              ]),
            ]),
          ]),
        ]),
        Ok([
          row([
            tuple([
              atom_value("interval"),
              tuple([
                tuple([dynamic.int(0), dynamic.int(0), dynamic.int(0)]),
                dynamic.int(1),
                dynamic.int(0),
              ]),
            ]),
          ]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a bit string", fn() {
      // Act
      let results = round_trip("SELECT B'101'")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([row([dynamic.bit_array(<<5:size(3)>>)])]),
        Ok([row([dynamic.bit_array(<<5:size(3)>>)])]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a point", fn() {
      // Act
      let results = round_trip("SELECT '(1,2)'::point")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([
            dynamic.properties([
              #(atom_value("x"), dynamic.float(1.0)),
              #(atom_value("y"), dynamic.float(2.0)),
            ]),
          ]),
        ]),
        Ok([
          row([
            dynamic.properties([
              #(atom_value("x"), dynamic.float(1.0)),
              #(atom_value("y"), dynamic.float(2.0)),
            ]),
          ]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a row of several columns", fn() {
      // Act
      let results = round_trip("SELECT 1, 'a', NULL, true")

      // Assert
      results
      |> should
      |> be_equal(#(
        Ok([
          row([
            dynamic.int(1),
            dynamic.string("a"),
            atom_value("null"),
            dynamic.bool(True),
          ]),
        ]),
        Ok([
          row([
            dynamic.int(1),
            dynamic.string("a"),
            atom_value("null"),
            dynamic.bool(True),
          ]),
        ]),
      ))
      |> or_fail_with("Expected the same value live and played back")
    }),
    it("a row of a pool with rows_as_map", fn() {
      // Act
      let results =
        round_trip_with(
          "SELECT 1 AS id, 'Ada' AS name",
          test_database.config() |> pog.rows_as_map(True),
        )

      // Assert
      results
      |> should
      |> be_equal(#(Ok([map_row()]), Ok([map_row()])))
      |> or_fail_with("Expected the same map live and played back")
    }),
    it("no rows", fn() {
      // Act
      let results = round_trip("SELECT 1 WHERE false")

      // Assert
      results
      |> should
      |> be_equal(#(Ok([]), Ok([])))
      |> or_fail_with("Expected no rows live and played back")
    }),
  ])
}

fn map_row() -> Dynamic {
  dynamic.properties([
    #(dynamic.string("id"), dynamic.int(1)),
    #(dynamic.string("name"), dynamic.string("Ada")),
  ])
}

fn row(columns: List(Dynamic)) -> Dynamic {
  dynamic.array(columns)
}

fn tuple(values: List(Dynamic)) -> Dynamic {
  dynamic.array(values)
}

fn atom_value(name: String) -> Dynamic {
  atom.to_dynamic(atom.create(name))
}

// Runs `sql` through a recorder in record mode against the test server,
// then through a recorder in playback mode with no database, and gives both
// results.
fn round_trip(
  sql: String,
) -> #(
  Result(List(Dynamic), pog.QueryError),
  Result(List(Dynamic), pog.QueryError),
) {
  round_trip_with(sql, test_database.config())
}

fn round_trip_with(
  sql: String,
  config: postgres.Config,
) -> #(
  Result(List(Dynamic), pog.QueryError),
  Result(List(Dynamic), pog.QueryError),
) {
  use directory <- recordings.with_directory()
  use <- test_database.with_own_pools()
  let assert Ok(recording) = recordings.start("record", directory, "value")
  let assert Ok(live_db) =
    recorder.connect(recording, config |> postgres.pool_size(1))
  let live = recordings.rows(live_db, sql)
  let assert Ok(Nil) = recorder.stop(recording)
  let assert Ok(playback) = recordings.start("playback", directory, "value")
  let assert Ok(config) =
    postgres.parse_config(
      process.new_name("recorder_types_test"),
      database_url.unused_database_url(),
    )
  let assert Ok(played_db) = recorder.connect(playback, config)
  let played = recordings.rows(played_db, sql)
  let assert Ok(Nil) = recorder.stop(playback)
  #(live, played)
}
