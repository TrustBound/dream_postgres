//// Tests for the functions of `dream_postgres/client` that code from
//// dream_model calls: `violated_constraint`, `promised_not_null`,
//// `schema_fingerprint`, `check_schema` and `format_schema_check_error`,
//// and for their snippets. The queries run on the real PostgreSQL server
//// of docker-compose.yml, or on the server of `DREAM_POSTGRES_TEST_URL`.
//// No test depends on the major version of PostgreSQL.

import dream_postgres/client as postgres
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/test_database
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import snippets/client_broken_promise
import snippets/client_check_schema
import snippets/client_date_type
import snippets/client_promised_not_null
import snippets/client_schema_fingerprint
import snippets/client_schema_fingerprint_sql
import snippets/client_time_of_day_type
import snippets/client_timestamp_type
import snippets/client_violated_constraint

pub fn tests() -> TestSuite {
  describe("dream_postgres/client model helpers", [
    violated_constraint_tests(),
    promised_not_null_tests(),
    broken_promise_tests(),
    time_alias_tests(),
    fingerprint_value_tests(),
    fingerprint_stable_tests(),
    fingerprint_change_tests(),
    check_schema_tests(),
  ])
}

const users_table =
  "CREATE TABLE users (
  id int PRIMARY KEY,
  email text UNIQUE,
  team_id int REFERENCES teams (id),
  age int CHECK (age > 0),
  nick text,
  code text NOT NULL DEFAULT 'x'
)"

const nick_index = "CREATE UNIQUE INDEX users_nick_index ON users (nick)"

const teams_table = "CREATE TABLE teams (id int PRIMARY KEY)"

const items_table =
  "CREATE TABLE items (
  id int PRIMARY KEY,
  name text NOT NULL,
  price int CONSTRAINT items_price_check CHECK (price > 0)
)"

const touch_function =
  "CREATE FUNCTION touch() RETURNS trigger
  LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$"

const null_message =
  "the SQL file count.sql promised the column total is never NULL, and PostgreSQL returned NULL"

const empty_text_hash =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

fn violated_constraint_tests() {
  group("violated_constraint", [
    it("gives the unique constraint of a duplicate email", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, email) VALUES (2, 'a@b')")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Ok("users_email_key"))
      |> or_fail_with("Expected users_email_key")
    }),
    it("gives the primary key of a duplicate id", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id) VALUES (1)")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Ok("users_pkey"))
      |> or_fail_with("Expected users_pkey")
    }),
    it("gives the unique index of a duplicate nick", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, nick) VALUES (2, 'ace')")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Ok("users_nick_index"))
      |> or_fail_with("Expected users_nick_index")
    }),
    it("gives the foreign key of a missing team", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, team_id) VALUES (2, 99)")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Ok("users_team_id_fkey"))
      |> or_fail_with("Expected users_team_id_fkey")
    }),
    it("gives the check constraint of a bad age", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, age) VALUES (2, 0)")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Ok("users_age_check"))
      |> or_fail_with("Expected users_age_check")
    }),
    it("gives Error(Nil) for a NOT NULL violation", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, code) VALUES (2, NULL)")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a NOT NULL violation")
    }),
    it("gives Error(Nil) for an error that is not a constraint error", fn() {
      // Arrange
      let error = users_error("SELECT 1 / 0")

      // Act
      let result = postgres.violated_constraint(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for division by zero")
    }),
    it("client_violated_constraint names the taken email", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, email) VALUES (2, 'a@b')")

      // Act
      let message = client_violated_constraint.sign_up_error_message(error)

      // Assert
      message
      |> should
      |> be_equal("Email already taken")
      |> or_fail_with("Expected the email message")
    }),
    it("client_violated_constraint names another constraint", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, age) VALUES (2, 0)")

      // Act
      let message = client_violated_constraint.sign_up_error_message(error)

      // Assert
      message
      |> should
      |> be_equal("The sign-up broke the constraint users_age_check")
      |> or_fail_with("Expected the users_age_check message")
    }),
    it("client_violated_constraint gives the general message otherwise", fn() {
      // Arrange
      let error = dream_postgres_client.QueryTimeout

      // Act
      let message = client_violated_constraint.sign_up_error_message(error)

      // Assert
      message
      |> should
      |> be_equal("The sign-up failed")
      |> or_fail_with("Expected the general message")
    }),
  ])
}

fn promised_not_null_tests() {
  group("promised_not_null", [
    it("decodes a value that is not NULL", fn() {
      // Act
      let result = test_database.with_schema(second_column(_, "SELECT 1, 5"))

      // Assert
      result
      |> should
      |> be_equal(Ok([5]))
      |> or_fail_with("Expected [5]")
    }),
    it("fails a NULL with the file, the column and the column path", fn() {
      // Act
      let result =
        test_database.with_schema(second_column(_, "SELECT 1, NULL::int"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          dream_postgres_client.UnexpectedResultType([
            decode.DecodeError(expected: null_message, found: "NULL", path: [
              "1",
            ]),
          ]),
        ),
      )
      |> or_fail_with("Expected the NULL promise error at path 1")
    }),
    it("keeps the error of the decoder for a value of the wrong type", fn() {
      // Act
      let result =
        test_database.with_schema(second_column(_, "SELECT 1, 'x'::text"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          dream_postgres_client.UnexpectedResultType([
            decode.DecodeError(expected: "Int", found: "String", path: ["1"]),
          ]),
        ),
      )
      |> or_fail_with("Expected the Int error at path 1")
    }),
    it("fails a NULL when the decoder accepts NULL", fn() {
      // Act
      let result = test_database.with_schema(optional_second_column)

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          dream_postgres_client.UnexpectedResultType([
            decode.DecodeError(expected: null_message, found: "NULL", path: [
              "1",
            ]),
          ]),
        ),
      )
      |> or_fail_with("Expected the NULL promise error at path 1")
    }),
    it("client_promised_not_null gives the sum of the orders", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          run_all(db, [
            "CREATE TABLE orders (amount int)",
            "INSERT INTO orders VALUES (3), (4)",
          ])
          client_promised_not_null.order_total(db)
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(dream_postgres_client.Returned(count: 1, rows: [7])))
      |> or_fail_with("Expected one row with 7")
    }),
    it("client_promised_not_null fails when there are no orders", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          run_all(db, ["CREATE TABLE orders (amount int)"])
          client_promised_not_null.order_total(db)
        })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          dream_postgres_client.UnexpectedResultType([
            decode.DecodeError(
              expected: "the SQL file order_total.sql promised the column total is never NULL, and PostgreSQL returned NULL",
              found: "NULL",
              path: ["0"],
            ),
          ]),
        ),
      )
      |> or_fail_with("Expected the NULL promise error of total")
    }),
  ])
}

fn broken_promise_tests() {
  group("broken_promise", [
    it("gives the message of a broken promise", fn() {
      // Arrange
      let assert Error(error) =
        test_database.with_schema(second_column(_, "SELECT 1, NULL::int"))

      // Act
      let result = postgres.broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Ok(null_message))
      |> or_fail_with("Expected the message of the promise")
    }),
    it("gives Error(Nil) for a decode error of another kind", fn() {
      // Arrange
      let assert Error(error) =
        test_database.with_schema(second_column(_, "SELECT 1, 'x'::text"))

      // Act
      let result = postgres.broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for the Int error")
    }),
    it("gives Error(Nil) for a NULL error of another decoder", fn() {
      // Arrange
      let error =
        dream_postgres_client.UnexpectedResultType([
          decode.DecodeError(expected: "Int", found: "NULL", path: ["0"]),
        ])

      // Act
      let result = postgres.broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a NULL without a promise")
    }),
    it("gives Error(Nil) for an error that is not a decode error", fn() {
      // Arrange
      let error = dream_postgres_client.QueryTimeout

      // Act
      let result = postgres.broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a timeout")
    }),
    it("client_broken_promise shows the message of the promise", fn() {
      // Arrange
      let assert Error(error) =
        test_database.with_schema(second_column(_, "SELECT 1, NULL::int"))

      // Act
      let message = client_broken_promise.error_message(error)

      // Assert
      message
      |> should
      |> be_equal(null_message)
      |> or_fail_with("Expected the message of the promise")
    }),
    it("client_broken_promise gives the general message otherwise", fn() {
      // Act
      let message =
        client_broken_promise.error_message(dream_postgres_client.QueryTimeout)

      // Assert
      message
      |> should
      |> be_equal("The query failed")
      |> or_fail_with("Expected the general message")
    }),
  ])
}

fn time_alias_tests() {
  group("Timestamp, Date and TimeOfDay", [
    it("client_timestamp_type reads a timestamp", fn() {
      // Act
      let result =
        test_database.with_schema(client_timestamp_type.created_at)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(
        Ok([
          timestamp.from_calendar(
            calendar.Date(2024, calendar.January, 2),
            calendar.TimeOfDay(3, 4, 5, 0),
            calendar.utc_offset,
          ),
        ]),
      )
      |> or_fail_with("Expected 2024-01-02 03:04:05")
    }),
    it("client_date_type reads a date", fn() {
      // Act
      let result =
        test_database.with_schema(client_date_type.birthday)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(Ok([calendar.Date(2024, calendar.January, 2)]))
      |> or_fail_with("Expected 2024-01-02")
    }),
    it("client_time_of_day_type reads a time of day", fn() {
      // Act
      let result =
        test_database.with_schema(client_time_of_day_type.opening_time)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(Ok([calendar.TimeOfDay(3, 4, 5, 0)]))
      |> or_fail_with("Expected 03:04:05")
    }),
  ])
}

fn fingerprint_value_tests() {
  group("schema_fingerprint values", [
    it("is the SHA-256 of the empty text for no tables", fn() {
      // Act
      let result = test_database.with_schema(postgres.schema_fingerprint(_, []))

      // Assert
      result
      |> should
      |> be_equal(Ok(empty_text_hash))
      |> or_fail_with("Expected the SHA-256 of the empty text")
    }),
    it(
      "client_schema_fingerprint_sql gives a missing line for a missing table",
      fn() {
        // Act
        let result =
          test_database.with_schema(fn(db) {
            let schema = schema_name(db)
            client_schema_fingerprint_sql.fingerprint_text(db, [
              schema <> ".ghost",
            ])
            |> result.map(fn(returned) {
              returned.rows == [schema <> ".ghost missing"]
            })
          })

        // Assert
        result
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("Expected the one line <schema>.ghost missing")
      },
    ),
    it("client_schema_fingerprint changes when the users table is made", fn() {
      // Act
      let changed =
        test_database.with_schema(fn(db) {
          let schema = schema_name(db)
          let assert Ok(missing) =
            client_schema_fingerprint.users_fingerprint(db, schema)
          run_all(db, [teams_table, users_table])
          let assert Ok(present) =
            client_schema_fingerprint.users_fingerprint(db, schema)
          missing != present
        })

      // Assert
      changed
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected a missing table to give another fingerprint")
    }),
  ])
}

fn fingerprint_stable_tests() {
  group("schema_fingerprint does not change", [
    it("when the same DDL makes the tables again with new OIDs", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table], [
          "DROP TABLE items",
          "CREATE TABLE unrelated (x int)",
          items_table,
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when the columns are in another order", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table], [
          "DROP TABLE items",
          "CREATE TABLE items (
            price int CONSTRAINT items_price_check CHECK (price > 0),
            name text NOT NULL,
            id int PRIMARY KEY
          )",
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when a dropped column changed the column numbers", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table], [
          "DROP TABLE items",
          "CREATE TABLE items (
            junk int,
            id int PRIMARY KEY,
            name text NOT NULL,
            price int CONSTRAINT items_price_check CHECK (price > 0)
          )",
          "ALTER TABLE items DROP COLUMN junk",
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when rows change", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table], [
          "INSERT INTO items VALUES (1, 'pen', 2)",
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when a table that is not named changes", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table], ["CREATE TABLE other (x int)"])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when an AFTER trigger is added", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table, touch_function], [
          "CREATE TRIGGER audit AFTER INSERT ON items
            FOR EACH ROW EXECUTE FUNCTION touch()",
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when the search_path of the connection is different", fn() {
      // Act
      let same =
        test_database.with_schema(fn(db) {
          run_all(db, [
            "CREATE DOMAIN positive AS int CHECK (VALUE > 0)",
            "CREATE TABLE amounts (amount positive)",
          ])
          let tables = [schema_name(db) <> ".amounts"]
          let assert Ok(in_schema) = postgres.schema_fingerprint(db, tables)
          let assert Ok(other) =
            test_database.config()
            |> postgres.pool_size(1)
            |> postgres.connect()
          let assert Ok(in_public) = postgres.schema_fingerprint(other, tables)
          in_schema == in_public
        })

      // Assert
      same
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the same fingerprint with each search_path")
    }),
    it("leaves the search_path of a transaction as it was", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          let schema = schema_name(db)
          postgres.transaction(db, fn(transaction) {
            let assert Ok(_fingerprint) =
              postgres.schema_fingerprint(transaction, [schema <> ".ghost"])
            test_database.texts(transaction, "SHOW search_path")
            |> result.map(fn(paths) { paths == [schema] })
          })
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(True))
      |> or_fail_with("Expected the search_path of the schema")
    }),
  ])
}

fn fingerprint_change_tests() {
  group("schema_fingerprint changes", [
    change_test("when a NOT NULL is dropped", [items_table], [
      "ALTER TABLE items ALTER COLUMN name DROP NOT NULL",
    ]),
    change_test("when a CHECK is added", [items_table], [
      "ALTER TABLE items ADD CHECK (id > 0)",
    ]),
    change_test("when a constraint is renamed", [items_table], [
      "ALTER TABLE items RENAME CONSTRAINT items_price_check TO price_positive",
    ]),
    change_test(
      "when a constraint is validated",
      [
        items_table,
        "ALTER TABLE items ADD CONSTRAINT short_name CHECK (length(name) < 9) NOT VALID",
      ],
      ["ALTER TABLE items VALIDATE CONSTRAINT short_name"],
    ),
    change_test("when the type of a column changes", [items_table], [
      "ALTER TABLE items ALTER COLUMN price TYPE bigint",
    ]),
    change_test("when a column is added", [items_table], [
      "ALTER TABLE items ADD COLUMN note text",
    ]),
    change_test("when a column gets a default", [items_table], [
      "ALTER TABLE items ALTER COLUMN price SET DEFAULT 1",
    ]),
    change_test(
      "when a BEFORE row trigger is added",
      [
        items_table,
        touch_function,
      ],
      [
        "CREATE TRIGGER touch BEFORE INSERT ON items
        FOR EACH ROW EXECUTE FUNCTION touch()",
      ],
    ),
    change_test("when row level security is turned on", [items_table], [
      "ALTER TABLE items ENABLE ROW LEVEL SECURITY",
    ]),
    change_test(
      "when a policy WITH CHECK changes",
      [
        items_table,
        "ALTER TABLE items ENABLE ROW LEVEL SECURITY",
        "CREATE POLICY cheap ON items FOR INSERT WITH CHECK (price < 100)",
      ],
      [
        "ALTER POLICY cheap ON items WITH CHECK (price < 50)",
      ],
    ),
    change_test(
      "when a partition is added",
      ["CREATE TABLE events (id int, at date) PARTITION BY RANGE (at)"],
      [
        "CREATE TABLE events_2026 PARTITION OF events
          FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
      ],
    ),
    change_test("when a child table is added", [items_table], [
      "CREATE TABLE special_items (note text) INHERITS (items)",
    ]),
    change_test(
      "when a column of a partition changes",
      [
        "CREATE TABLE events (id int, at date) PARTITION BY RANGE (at)",
        "CREATE TABLE events_2026 (id int, at date)",
      ],
      [
        "ALTER TABLE events ATTACH PARTITION events_2026
          FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
        "ALTER TABLE events_2026 ADD CONSTRAINT small_id CHECK (id < 9)",
      ],
    ),
    change_test(
      "when a domain of a column gets a CHECK",
      [
        "CREATE DOMAIN positive AS int",
        "CREATE TABLE items (price positive)",
      ],
      ["ALTER DOMAIN positive ADD CHECK (VALUE > 0)"],
    ),
    change_test(
      "when a constraint of the domain of an array column is renamed",
      [
        "CREATE DOMAIN positive AS int CONSTRAINT above_zero CHECK (VALUE > 0)",
        "CREATE TABLE items (prices positive[])",
      ],
      ["ALTER DOMAIN positive RENAME CONSTRAINT above_zero TO over_zero"],
    ),
    change_test(
      "when an enum of a column gets a label",
      [
        "CREATE TYPE size AS ENUM ('small', 'large')",
        "CREATE TABLE items (size size)",
      ],
      ["ALTER TYPE size ADD VALUE 'medium' BEFORE 'large'"],
    ),
    change_test("when the table is dropped", [items_table], [
      "DROP TABLE items",
    ]),
  ])
}

fn change_test(
  name: String,
  setup: List(String),
  change: List(String),
) -> unit.UnitNode {
  it(name, fn() {
    // Act
    let changed = changes_fingerprint(setup, change)

    // Assert
    changed
    |> should
    |> be_equal(True)
    |> or_fail_with("Expected another fingerprint")
  })
}

fn check_schema_tests() {
  group("check_schema and format_schema_check_error", [
    it("gives Ok(Nil) when each module matches", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          run_all(db, [items_table])
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = postgres.schema_fingerprint(db, tables)
          postgres.check_schema(db, [
            postgres.SchemaFingerprint(module: "app/sql/items", tables:, hash:),
          ])
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
    it("gives Ok(Nil) for no modules", fn() {
      // Act
      let result = test_database.with_schema(postgres.check_schema(_, []))

      // Assert
      result
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
    it("names each module whose fingerprint differs", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          run_all(db, [items_table])
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = postgres.schema_fingerprint(db, tables)
          let result =
            postgres.check_schema(db, [
              postgres.SchemaFingerprint(module: "a", tables:, hash: "old"),
              postgres.SchemaFingerprint(module: "b", tables:, hash:),
              postgres.SchemaFingerprint(module: "c", tables:, hash: "older"),
            ])
          result
          == Error(
            postgres.SchemaChanged([
              postgres.SchemaMismatch(
                module: "a",
                tables:,
                expected: "old",
                found: hash,
              ),
              postgres.SchemaMismatch(
                module: "c",
                tables:,
                expected: "older",
                found: hash,
              ),
            ]),
          )
        })

      // Assert
      result
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected mismatches for a and c")
    }),
    it("gives SchemaUnreadable when the fingerprint query fails", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          postgres.transaction(db, fn(transaction) {
            let assert Error(_division_by_zero) =
              test_database.execute(transaction, "SELECT 1 / 0")
            Error(
              postgres.check_schema(transaction, [
                postgres.SchemaFingerprint(
                  module: "app/sql/items",
                  tables: ["public.items"],
                  hash: "old",
                ),
              ]),
            )
          })
        })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          dream_postgres_client.TransactionRolledBack(
            Error(postgres.SchemaUnreadable(
              module: "app/sql/items",
              error: dream_postgres_client.PostgresqlError(
                code: "25P02",
                name: "in_failed_sql_transaction",
                message: "current transaction is aborted, commands ignored until end of transaction block",
              ),
            )),
          ),
        ),
      )
      |> or_fail_with("Expected SchemaUnreadable with the aborted transaction")
    }),
    it("format_schema_check_error lists the changed modules", fn() {
      // Arrange
      let error =
        postgres.SchemaChanged([
          postgres.SchemaMismatch(
            module: "app/sql/users",
            tables: ["public.users", "public.teams"],
            expected: "aa",
            found: "bb",
          ),
          postgres.SchemaMismatch(
            module: "app/sql/items",
            tables: ["public.items"],
            expected: "cc",
            found: "dd",
          ),
        ])

      // Act
      let message = postgres.format_schema_check_error(error)

      // Assert
      message
      |> should
      |> be_equal(
        "The database schema changed after dream_model generated these modules. Regenerate them with dream_model:
- app/sql/users (public.users, public.teams): expected fingerprint aa, found bb
- app/sql/items (public.items): expected fingerprint cc, found dd",
      )
      |> or_fail_with("Expected one line for each module")
    }),
    it("format_schema_check_error names the module of a failed query", fn() {
      // Arrange
      let error =
        postgres.SchemaUnreadable(
          module: "app/sql/items",
          error: dream_postgres_client.QueryTimeout,
        )

      // Act
      let message = postgres.format_schema_check_error(error)

      // Assert
      message
      |> should
      |> be_equal(
        "The schema fingerprint query of app/sql/items failed: QueryTimeout",
      )
      |> or_fail_with("Expected the module and the error")
    }),
    it("client_check_schema gives the message of a changed module", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(missing) = postgres.schema_fingerprint(db, tables)
          run_all(db, [items_table])
          let assert Ok(present) = postgres.schema_fingerprint(db, tables)
          let message =
            client_check_schema.check_models(db, [
              postgres.SchemaFingerprint(
                module: "app/sql/items",
                tables:,
                hash: missing,
              ),
            ])
          message
          == Error(
            "The database schema changed after dream_model generated these modules. Regenerate them with dream_model:\n- app/sql/items ("
            <> schema_name(db)
            <> ".items): expected fingerprint "
            <> missing
            <> ", found "
            <> present,
          )
        })

      // Assert
      result
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the message for app/sql/items")
    }),
    it("client_check_schema gives Ok(Nil) when the module matches", fn() {
      // Act
      let result =
        test_database.with_schema(fn(db) {
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = postgres.schema_fingerprint(db, tables)
          client_check_schema.check_models(db, [
            postgres.SchemaFingerprint(module: "app/sql/items", tables:, hash:),
          ])
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
  ])
}

// Helpers

// Makes the teams and users tables with one user, runs `sql`, and gives
// its error.
fn users_error(sql: String) -> postgres.QueryError {
  use db <- test_database.with_schema
  run_all(db, [
    teams_table,
    users_table,
    nick_index,
    "INSERT INTO users (id, email, nick) VALUES (1, 'a@b', 'ace')",
  ])
  let assert Error(error) = test_database.execute(db, sql)
  error
}

fn second_column(
  db: postgres.Connection,
  sql: String,
) -> Result(List(Int), postgres.QueryError) {
  sql
  |> postgres.query
  |> postgres.returning(decode.at(
    [1],
    postgres.promised_not_null(decode.int, "count.sql", "total"),
  ))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn optional_second_column(
  db: postgres.Connection,
) -> Result(List(Option(Int)), postgres.QueryError) {
  "SELECT 1, NULL::int"
  |> postgres.query
  |> postgres.returning(decode.at(
    [1],
    postgres.promised_not_null(
      decode.optional(decode.int),
      "count.sql",
      "total",
    ),
  ))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn schema_name(db: postgres.Connection) -> String {
  let assert Ok([name]) = test_database.texts(db, "SELECT current_schema()")
  name
}

fn run_all(db: postgres.Connection, statements: List(String)) -> Nil {
  list.each(statements, fn(statement) {
    let assert Ok(_returned) = test_database.execute(db, statement)
    Nil
  })
}

// Runs `setup` in a new schema, then `change`, and tells if the fingerprint
// of the tables items and events changed.
fn changes_fingerprint(setup: List(String), change: List(String)) -> Bool {
  use db <- test_database.with_schema
  let schema = schema_name(db)
  let tables = [schema <> ".items", schema <> ".events"]
  run_all(db, setup)
  let assert Ok(before) = postgres.schema_fingerprint(db, tables)
  run_all(db, change)
  let assert Ok(after) = postgres.schema_fingerprint(db, tables)
  before != after
}
