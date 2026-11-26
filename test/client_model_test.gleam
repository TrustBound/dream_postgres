//// Tests for the types and functions of `dream_postgres/client` that code
//// from dream_model uses: `to_error`, `more_than_one_row`,
//// `violated_constraint`, `promised_not_null`,
//// `finite_timestamp`, `finite_date`, `infinite_value`,
//// `schema_fingerprint`, `check_schema` and `format_schema_check_error`,
//// and for their snippets. The queries run on the real PostgreSQL server
//// of docker-compose.yml, or on the server of `DREAM_POSTGRES_TEST_URL`.
//// No test depends on the major version of PostgreSQL.

import dream_errors.{Conflict, Failed, NotFound, Timeout, Unavailable}
import dream_postgres/client.{
  type Connection, type QueryError, SchemaChanged, SchemaFingerprint,
  SchemaMismatch, SchemaUnreadable, broken_promise, check_schema, connect,
  finite_timestamp, format_schema_check_error, infinite_value, more_than_one_row,
  pool_size, promised_elements_not_null, promised_not_null, query, returning,
  schema_fingerprint, timestamp_with_time_zone_decoder, to_error,
  violated_constraint,
} as postgres
import dream_postgres_client.{
  ConnectionUnavailable, InterceptorFailed, PostgresqlError, QueryTimeout,
  Returned, TransactionRolledBack, UnexpectedArgumentCount,
  UnexpectedArgumentType, UnexpectedResultType, connection_parameter,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{type UnitNode, describe, group, it}
import fixtures/test_database.{config, texts, with_schema}
import gleam/dynamic
import gleam/dynamic/decode.{DecodeError, at, int, optional}
import gleam/list.{each, map}
import gleam/option.{type Option, None, to_result}
import gleam/result
import gleam/string.{replace}
import gleam/time/calendar.{Date, February, January, TimeOfDay, utc_offset}
import gleam/time/timestamp.{from_calendar, from_unix_seconds}
import snippets/client_broken_promise
import snippets/client_check_schema.{check_models}
import snippets/client_date_type.{birthday}
import snippets/client_finite_date.{valid_until}
import snippets/client_finite_timestamp.{ends_at}
import snippets/client_infinite_value
import snippets/client_more_than_one_row.{one_email}
import snippets/client_promised_elements_not_null.{tags}
import snippets/client_promised_not_null.{order_total}
import snippets/client_schema_fingerprint.{users_fingerprint}
import snippets/client_schema_fingerprint_sql.{fingerprint_text}
import snippets/client_time_of_day_type.{opening_time}
import snippets/client_timestamp_type.{created_at}
import snippets/client_timestamp_with_time_zone_decoder.{signed_up_at}
import snippets/client_to_error.{status}
import snippets/client_violated_constraint.{sign_up_error_message}

pub fn tests() -> TestSuite {
  describe("dream_postgres/client model helpers", [
    to_error_tests(),
    more_than_one_row_tests(),
    violated_constraint_tests(),
    promised_not_null_tests(),
    promised_elements_not_null_tests(),
    broken_promise_tests(),
    finite_timestamp_tests(),
    finite_date_tests(),
    infinite_value_tests(),
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

const elements_message =
  "the SQL file list.sql promised the elements of numbers are never NULL, and PostgreSQL returned NULL"

const exact_ddl = [
  "CREATE TYPE mood AS ENUM ('sad', 'happy')",
  "CREATE DOMAIN short_text AS text CHECK (length(VALUE) < 20)",
  "CREATE TYPE pair AS (left_side int, right_side text)",
  "CREATE TYPE span AS RANGE (subtype = float8)",
  "CREATE TABLE parents (id int)",
  "CREATE TABLE items (label short_text UNIQUE, mood mood, pair pair, span span, total int GENERATED ALWAYS AS (id * 2) STORED, at timestamptz CHECK (at > '1999-12-31 23:59:59.123456+00'), price money CHECK (price > '1.5')) INHERITS (parents)",
  "CREATE INDEX items_mood_index ON items (mood) WHERE id > 0",
  "ALTER TABLE items ENABLE ROW LEVEL SECURITY",
  "CREATE POLICY readers ON items FOR SELECT TO pg_monitor USING (id > 1)",
  "CREATE RULE no_delete AS ON DELETE TO items DO INSTEAD NOTHING",
  "CREATE FUNCTION touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
  "CREATE TRIGGER touch BEFORE INSERT ON items FOR EACH ROW EXECUTE FUNCTION touch()",
  "CREATE VIEW item_labels AS SELECT label FROM items",
  "CREATE TABLE events (at timestamptz) PARTITION BY RANGE (at)",
  "CREATE TABLE events_old PARTITION OF events FOR VALUES FROM ('1999-12-31 23:59:59.123456+00') TO ('2026-01-01 00:00:00+00')",
]

const exact_text =
  "fp.events column at position=1 type=timestamp with time zone not_null=false has_default=false identity= generated= generation=
fp.events relation kind=p row_security=false force_row_security=false before_row_triggers=false instead_row_triggers=false check_option= partition_key=RANGE (at) partition_bound=
fp.events_old column at position=1 type=timestamp with time zone not_null=false has_default=false identity= generated= generation=
fp.events_old inherits fp.events
fp.events_old relation kind=r row_security=false force_row_security=false before_row_triggers=false instead_row_triggers=false check_option= partition_key= partition_bound=FOR VALUES FROM ('1999-12-31 23:59:59.123456+00') TO ('2026-01-01 00:00:00+00')
fp.item_labels column label position=1 type=fp.short_text not_null=false has_default=false identity= generated= generation=
fp.item_labels relation kind=v row_security=false force_row_security=false before_row_triggers=false instead_row_triggers=false check_option= partition_key= partition_bound=
fp.item_labels view definition= SELECT label
   FROM fp.items;
fp.items column at position=7 type=timestamp with time zone not_null=false has_default=false identity= generated= generation=
fp.items column id position=1 type=integer not_null=false has_default=false identity= generated= generation=
fp.items column label position=2 type=fp.short_text not_null=false has_default=false identity= generated= generation=
fp.items column mood position=3 type=fp.mood not_null=false has_default=false identity= generated= generation=
fp.items column pair position=4 type=fp.pair not_null=false has_default=false identity= generated= generation=
fp.items column price position=8 type=money not_null=false has_default=false identity= generated= generation=
fp.items column span position=5 type=fp.span not_null=false has_default=false identity= generated= generation=
fp.items column total position=6 type=integer not_null=false has_default=true identity= generated=s generation=(id * 2)
fp.items constraint items_at_check type=c validated=true definition=CHECK ((at > '1999-12-31 23:59:59.123456+00'::timestamp with time zone))
fp.items constraint items_label_key type=u validated=true definition=UNIQUE (label)
fp.items constraint items_price_check type=c validated=true definition=CHECK ((price > '$1.50'::money))
fp.items index items_label_key unique=true valid=true definition=CREATE UNIQUE INDEX items_label_key ON fp.items USING btree (label)
fp.items index items_mood_index unique=false valid=true definition=CREATE INDEX items_mood_index ON fp.items USING btree (mood) WHERE (id > 0)
fp.items inherits fp.parents
fp.items policy readers command=r permissive=true roles=pg_monitor using=(id > 1) with_check=
fp.items relation kind=r row_security=true force_row_security=false before_row_triggers=true instead_row_triggers=false check_option= partition_key= partition_bound=
fp.items rule no_delete enabled=O definition=CREATE RULE no_delete AS
    ON DELETE TO fp.items DO INSTEAD NOTHING;
fp.mood enum labels='sad','happy'
fp.pair field left_side position=1 type=integer
fp.pair field right_side position=2 type=text
fp.short_text domain base=text not_null=false
fp.short_text domain_constraint short_text_check type=c validated=true definition=CHECK ((length(VALUE) < 20))
fp.span range subtype=double precision"

// DDL with a constant of each kind whose text depends on a setting.
const settings_ddl = [
  "CREATE TABLE items (
    at timestamptz CHECK (at > '1999-12-31 23:59:59.123456+00'),
    day date CHECK (day > '2001-02-03'),
    span interval CHECK (span > '1 day 02:00'),
    ratio float8 CHECK (ratio > 0.3333333333333333),
    bytes bytea CHECK (bytes <> '\\x01'),
    price money CHECK (price > '1.5'),
    path text CHECK (path <> 'a\\b')
  )",
  "CREATE TABLE events (at timestamptz) PARTITION BY RANGE (at)",
  "CREATE TABLE events_old PARTITION OF events
    FOR VALUES FROM ('1999-12-31 23:59:59.123456+00')
    TO ('2026-01-01 00:00:00+00')",
]

const promise_marker = "[dream_postgres promised_not_null] "

const empty_text_hash =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

fn to_error_tests() {
  group("to_error", [
    it(
      "gives Conflict for a duplicate email, with the error as the cause",
      fn() {
        // Arrange
        let error =
          users_error("INSERT INTO users (id, email) VALUES (2, 'a@b')")

        // Act
        let shared = to_error(error)

        // Assert
        #(
          shared,
          shared
            |> dream_errors.cause
            |> to_result(Nil)
            |> result.try(violated_constraint),
        )
        |> should
        |> be_equal(#(
          Conflict("the query violated the constraint users_email_key", error),
          Ok("users_email_key"),
        ))
        |> or_fail_with("Expected Conflict with the constraint in the cause")
      },
    ),
    it("gives Timeout for QueryTimeout", fn() {
      // Act
      let shared = to_error(QueryTimeout)

      // Assert
      shared
      |> should
      |> be_equal(Timeout(
        "the database did not answer the query in time",
        QueryTimeout,
      ))
      |> or_fail_with("Expected Timeout")
    }),
    it("gives Unavailable for ConnectionUnavailable", fn() {
      // Act
      let shared = to_error(ConnectionUnavailable)

      // Assert
      shared
      |> should
      |> be_equal(Unavailable(
        "no database connection was available",
        ConnectionUnavailable,
      ))
      |> or_fail_with("Expected Unavailable")
    }),
    it("gives Failed with the name and the code of a PostgreSQL error", fn() {
      // Arrange
      let error =
        PostgresqlError(
          code: "42P01",
          name: "undefined_table",
          message: "relation \"nope\" does not exist",
        )

      // Act
      let shared = to_error(error)

      // Assert
      shared
      |> should
      |> be_equal(Failed(
        "the database failed the query with undefined_table (42P01): relation \"nope\" does not exist",
        error,
      ))
      |> or_fail_with("Expected Failed with the PostgreSQL error")
    }),
    it("gives Failed for a wrong number of arguments", fn() {
      // Arrange
      let error = UnexpectedArgumentCount(expected: 2, got: 1)

      // Act
      let shared = to_error(error)

      // Assert
      shared
      |> should
      |> be_equal(Failed("the query expected 2 arguments and got 1", error))
      |> or_fail_with("Expected Failed with the counts")
    }),
    it("gives Failed for an argument of the wrong type", fn() {
      // Arrange
      let error = UnexpectedArgumentType(expected: "int4", got: "text")

      // Act
      let shared = to_error(error)

      // Assert
      shared
      |> should
      |> be_equal(Failed(
        "the query expected an argument of type int4 and got text",
        error,
      ))
      |> or_fail_with("Expected Failed with the types")
    }),
    it("gives Failed with each decode error of a row", fn() {
      // Arrange
      let error =
        UnexpectedResultType([
          DecodeError(expected: "Int", found: "String", path: ["0"]),
          DecodeError(expected: "String", found: "Nil", path: [
            "1",
            "name",
          ]),
        ])

      // Act
      let shared = to_error(error)

      // Assert
      shared
      |> should
      |> be_equal(Failed(
        "a row did not decode: expected Int, found String at 0, expected String, found Nil at 1.name",
        error,
      ))
      |> or_fail_with("Expected Failed with both decode errors")
    }),
    it("gives Failed for an interceptor", fn() {
      // Arrange
      let error = InterceptorFailed(dynamic.string("no queries"))

      // Act
      let shared = to_error(error)

      // Assert
      shared
      |> should
      |> be_equal(Failed("an interceptor failed the query", error))
      |> or_fail_with("Expected Failed for the interceptor")
    }),
    it("client_to_error gives each kind its status", fn() {
      // Act
      let statuses = [
        status(users_error("INSERT INTO users (id, email) VALUES (2, 'a@b')")),
        status(ConnectionUnavailable),
        status(QueryTimeout),
        status(more_than_one_row(2)),
      ]

      // Assert
      statuses
      |> should
      |> be_equal([409, 503, 504, 500])
      |> or_fail_with("Expected 409, 503, 504 and 500")
    }),
  ])
}

fn more_than_one_row_tests() {
  group("more_than_one_row", [
    it("tells the number of rows", fn() {
      // Act
      let error = more_than_one_row(3)

      // Assert
      error
      |> should
      |> be_equal(
        UnexpectedResultType([
          DecodeError(expected: "at most one row", found: "3 rows", path: []),
        ]),
      )
      |> or_fail_with("Expected an UnexpectedResultType with 3 rows")
    }),
    it("is not a broken promise or an infinite value", fn() {
      // Arrange
      let error = more_than_one_row(2)

      // Act
      let found = #(broken_promise(error), infinite_value(error))

      // Assert
      found
      |> should
      |> be_equal(#(Error(Nil), Error(Nil)))
      |> or_fail_with("Expected no promise and no infinite value")
    }),
    it("client_more_than_one_row gives the one email", fn() {
      // Act
      let found = one_email(["a@b"])

      // Assert
      found
      |> should
      |> be_equal(Ok("a@b"))
      |> or_fail_with("Expected the email")
    }),
    it("client_more_than_one_row gives NotFound for no email", fn() {
      // Act
      let found = one_email([])

      // Assert
      found
      |> should
      |> be_equal(Error(NotFound("user.email found no row")))
      |> or_fail_with("Expected NotFound")
    }),
    it("client_more_than_one_row fails two emails", fn() {
      // Act
      let found = one_email(["a@b", "c@d"])

      // Assert
      found
      |> should
      |> be_equal(
        Error(Failed(
          message: "user.email returned more than one row",
          cause: more_than_one_row(2),
        )),
      )
      |> or_fail_with("Expected Failed")
    }),
  ])
}

fn violated_constraint_tests() {
  group("violated_constraint", [
    it("gives the unique constraint of a duplicate email", fn() {
      // Arrange
      let error = users_error("INSERT INTO users (id, email) VALUES (2, 'a@b')")

      // Act
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let result = violated_constraint(error)

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
      let message = sign_up_error_message(error)

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
      let message = sign_up_error_message(error)

      // Assert
      message
      |> should
      |> be_equal("The sign-up broke the constraint users_age_check")
      |> or_fail_with("Expected the users_age_check message")
    }),
    it("client_violated_constraint gives the general message otherwise", fn() {
      // Arrange
      let error = QueryTimeout

      // Act
      let message = sign_up_error_message(error)

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
      let result = with_schema(second_column(_, "SELECT 1, 5"))

      // Assert
      result
      |> should
      |> be_equal(Ok([5]))
      |> or_fail_with("Expected [5]")
    }),
    it("fails a NULL with the file, the column and the column path", fn() {
      // Act
      let result = with_schema(second_column(_, "SELECT 1, NULL::int"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(
              expected: promise_marker <> null_message,
              found: "NULL",
              path: [
                "1",
              ],
            ),
          ]),
        ),
      )
      |> or_fail_with("Expected the NULL promise error at path 1")
    }),
    it("keeps the error of the decoder for a value of the wrong type", fn() {
      // Act
      let result = with_schema(second_column(_, "SELECT 1, 'x'::text"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(expected: "Int", found: "String", path: ["1"]),
          ]),
        ),
      )
      |> or_fail_with("Expected the Int error at path 1")
    }),
    it("fails a NULL when the decoder accepts NULL", fn() {
      // Act
      let result = with_schema(optional_second_column)

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(
              expected: promise_marker <> null_message,
              found: "NULL",
              path: [
                "1",
              ],
            ),
          ]),
        ),
      )
      |> or_fail_with("Expected the NULL promise error at path 1")
    }),
    it("client_promised_not_null gives the sum of the orders", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          run_all(db, [
            "CREATE TABLE orders (amount int)",
            "INSERT INTO orders VALUES (3), (4)",
          ])
          order_total(db)
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [7])))
      |> or_fail_with("Expected one row with 7")
    }),
    it("client_promised_not_null fails when there are no orders", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          run_all(db, ["CREATE TABLE orders (amount int)"])
          order_total(db)
        })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(
              expected: promise_marker
                <> "the SQL file order_total.sql promised the column total is never NULL, and PostgreSQL returned NULL",
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

fn promised_elements_not_null_tests() {
  group("promised_elements_not_null", [
    it("decodes an array with no NULL element", fn() {
      // Act
      let result = with_schema(second_array(_, "SELECT 1, ARRAY[4, 5]"))

      // Assert
      result
      |> should
      |> be_equal(Ok([[4, 5]]))
      |> or_fail_with("Expected [[4, 5]]")
    }),
    it("decodes an empty array", fn() {
      // Act
      let result = with_schema(second_array(_, "SELECT 1, '{}'::int[]"))

      // Assert
      result
      |> should
      |> be_equal(Ok([[]]))
      |> or_fail_with("Expected [[]]")
    }),
    it(
      "fails a NULL element with the file, the column and the column path",
      fn() {
        // Act
        let result = with_schema(second_array(_, "SELECT 1, ARRAY[4, NULL]"))

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            UnexpectedResultType([
              DecodeError(
                expected: promise_marker <> elements_message,
                found: "NULL",
                path: ["1"],
              ),
            ]),
          ),
        )
        |> or_fail_with("Expected the element promise error at path 1")
      },
    ),
    it("keeps the error of the decoder for an element of the wrong type", fn() {
      // Act
      let result = with_schema(second_array(_, "SELECT 1, ARRAY['x']"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(expected: "Int", found: "String", path: ["1", "0"]),
          ]),
        ),
      )
      |> or_fail_with("Expected the Int error of element 0 at path 1")
    }),
    it("lets decode.optional take a NULL array", fn() {
      // Act
      let result = with_schema(optional_second_array)

      // Assert
      result
      |> should
      |> be_equal(Ok([None]))
      |> or_fail_with("Expected [None]")
    }),
    it("gives broken_promise the message of a NULL element", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(second_array(_, "SELECT 1, ARRAY[NULL::int]"))

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Ok(elements_message))
      |> or_fail_with("Expected the message of the element promise")
    }),
    it("client_promised_elements_not_null gives the tags of the posts", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          run_all(db, [
            "CREATE TABLE posts (tags text[])",
            "INSERT INTO posts VALUES (ARRAY['gleam', 'sql'])",
          ])
          tags(db)
        })

      // Assert
      result
      |> should
      |> be_equal(Ok(Returned(count: 1, rows: [["gleam", "sql"]])))
      |> or_fail_with("Expected one row with gleam and sql")
    }),
    it("client_promised_elements_not_null fails a NULL tag", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          run_all(db, [
            "CREATE TABLE posts (tags text[])",
            "INSERT INTO posts VALUES (ARRAY['gleam', NULL])",
          ])
          tags(db)
        })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(
              expected: promise_marker
                <> "the SQL file find.sql promised the elements of tags are never NULL, and PostgreSQL returned NULL",
              found: "NULL",
              path: ["0"],
            ),
          ]),
        ),
      )
      |> or_fail_with("Expected the element promise error of tags")
    }),
  ])
}

fn broken_promise_tests() {
  group("broken_promise", [
    it("gives the message of a broken promise", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(second_column(_, "SELECT 1, NULL::int"))

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Ok(null_message))
      |> or_fail_with("Expected the message of the promise")
    }),
    it("gives Error(Nil) for a decode error of another kind", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(second_column(_, "SELECT 1, 'x'::text"))

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for the Int error")
    }),
    it("gives Error(Nil) for a NULL error of another decoder", fn() {
      // Arrange
      let error =
        UnexpectedResultType([
          DecodeError(expected: "Int", found: "NULL", path: ["0"]),
        ])

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a NULL without a promise")
    }),
    it("gives Error(Nil) for a lookalike error of another decoder", fn() {
      // Arrange
      let error =
        UnexpectedResultType([
          DecodeError(expected: null_message, found: "NULL", path: [
            "0",
          ]),
        ])

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for an error without the marker")
    }),
    it("gives Error(Nil) for an error that is not a decode error", fn() {
      // Arrange
      let error = QueryTimeout

      // Act
      let result = broken_promise(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a timeout")
    }),
    it("client_broken_promise shows the message of the promise", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(second_column(_, "SELECT 1, NULL::int"))

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
      let message = client_broken_promise.error_message(QueryTimeout)

      // Assert
      message
      |> should
      |> be_equal("The query failed")
      |> or_fail_with("Expected the general message")
    }),
  ])
}

fn finite_timestamp_tests() {
  group("finite_timestamp", [
    it("decodes a finite timestamp", fn() {
      // Act
      let result =
        with_schema(ends_at(_, "SELECT timestamp '1970-01-01 00:00:10'"))

      // Assert
      result
      |> should
      |> be_equal(
        Ok(
          Returned(count: 1, rows: [
            from_unix_seconds(10),
          ]),
        ),
      )
      |> or_fail_with("Expected the timestamp of second 10")
    }),
    it("fails infinity with the column and the path", fn() {
      // Act
      let result = with_schema(ends_at(_, "SELECT timestamp 'infinity'"))

      // Assert
      result
      |> should
      |> be_equal(infinity_error(ends_at_infinity, "infinity"))
      |> or_fail_with("Expected the infinity error of ends_at")
    }),
    it("fails -infinity with the column and the path", fn() {
      // Act
      let result = with_schema(ends_at(_, "SELECT timestamp '-infinity'"))

      // Assert
      result
      |> should
      |> be_equal(infinity_error(
        "the column ends_at holds -infinity, which the Gleam type Timestamp cannot hold",
        "-infinity",
      ))
      |> or_fail_with("Expected the -infinity error of ends_at")
    }),
    it("fails an infinite timestamptz", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          "SELECT timestamptz 'infinity'"
          |> query
          |> returning(at(
            [0],
            finite_timestamp(timestamp_with_time_zone_decoder(), "ends_at"),
          ))
          |> postgres.execute(db)
        })

      // Assert
      result
      |> should
      |> be_equal(infinity_error(ends_at_infinity, "infinity"))
      |> or_fail_with("Expected the infinity error of a timestamptz")
    }),
    it("keeps the error of the decoder for a value of the wrong type", fn() {
      // Act
      let result = with_schema(ends_at(_, "SELECT 'x'::text"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(expected: "Int", found: "String", path: ["0"]),
          ]),
        ),
      )
      |> or_fail_with("Expected the Int error at path 0")
    }),
  ])
}

fn finite_date_tests() {
  group("finite_date", [
    it("decodes a finite date", fn() {
      // Act
      let result = with_schema(valid_until(_, "SELECT date '2024-02-29'"))

      // Assert
      result
      |> should
      |> be_equal(
        Ok(
          Returned(count: 1, rows: [
            Date(2024, February, 29),
          ]),
        ),
      )
      |> or_fail_with("Expected 2024-02-29")
    }),
    it("fails infinity with the column and the path", fn() {
      // Act
      let result = with_schema(valid_until(_, "SELECT date 'infinity'"))

      // Assert
      result
      |> should
      |> be_equal(infinity_error(
        "the column valid_until holds infinity, which the Gleam type Date cannot hold",
        "infinity",
      ))
      |> or_fail_with("Expected the infinity error of valid_until")
    }),
    it("fails -infinity with the column and the path", fn() {
      // Act
      let result = with_schema(valid_until(_, "SELECT date '-infinity'"))

      // Assert
      result
      |> should
      |> be_equal(infinity_error(
        "the column valid_until holds -infinity, which the Gleam type Date cannot hold",
        "-infinity",
      ))
      |> or_fail_with("Expected the -infinity error of valid_until")
    }),
    it("keeps the error of the decoder for a NULL", fn() {
      // Act
      let result = with_schema(valid_until(_, "SELECT NULL::date"))

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          UnexpectedResultType([
            DecodeError(expected: "Indexable", found: "Nil", path: ["0"]),
            DecodeError(expected: "Indexable", found: "Nil", path: ["0"]),
            DecodeError(expected: "Indexable", found: "Nil", path: ["0"]),
            DecodeError(expected: "Calendar date", found: "Nil", path: [
              "0",
            ]),
          ]),
        ),
      )
      |> or_fail_with("Expected the errors of the date decoder")
    }),
  ])
}

fn infinite_value_tests() {
  group("infinite_value", [
    it("gives the message of an infinite value", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(ends_at(_, "SELECT timestamp 'infinity'"))

      // Act
      let result = infinite_value(error)

      // Assert
      result
      |> should
      |> be_equal(Ok(ends_at_infinity))
      |> or_fail_with("Expected the message of the infinite value")
    }),
    it("gives Error(Nil) for a decode error of another kind", fn() {
      // Arrange
      let error =
        UnexpectedResultType([
          DecodeError(expected: "Int", found: "infinity", path: ["0"]),
        ])

      // Act
      let result = infinite_value(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for an Int error")
    }),
    it("gives Error(Nil) for a lookalike error of another decoder", fn() {
      // Arrange
      let error =
        UnexpectedResultType([
          DecodeError(expected: ends_at_infinity, found: "infinity", path: ["0"]),
        ])

      // Act
      let result = infinite_value(error)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for an error without the marker")
    }),
    it("gives Error(Nil) for an error that is not a decode error", fn() {
      // Act
      let result = infinite_value(QueryTimeout)

      // Assert
      result
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil) for a timeout")
    }),
    it("client_infinite_value shows the message of the infinite value", fn() {
      // Arrange
      let assert Error(error) =
        with_schema(ends_at(_, "SELECT timestamp 'infinity'"))

      // Act
      let message = client_infinite_value.error_message(error)

      // Assert
      message
      |> should
      |> be_equal(ends_at_infinity)
      |> or_fail_with("Expected the message of the infinite value")
    }),
    it("client_infinite_value gives the general message otherwise", fn() {
      // Act
      let message = client_infinite_value.error_message(QueryTimeout)

      // Assert
      message
      |> should
      |> be_equal("The query failed")
      |> or_fail_with("Expected the general message")
    }),
  ])
}

const ends_at_infinity =
  "the column ends_at holds infinity, which the Gleam type Timestamp cannot hold"

fn infinity_error(message: String, found: String) -> Result(a, QueryError) {
  Error(
    UnexpectedResultType([
      DecodeError(
        expected: "[dream_postgres finite] " <> message,
        found:,
        path: ["0"],
      ),
    ]),
  )
}

fn time_alias_tests() {
  group("Timestamp, Date and TimeOfDay", [
    it("client_timestamp_type reads a timestamp", fn() {
      // Act
      let result =
        with_schema(created_at)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(
        Ok([
          from_calendar(
            Date(2024, January, 2),
            TimeOfDay(3, 4, 5, 0),
            utc_offset,
          ),
        ]),
      )
      |> or_fail_with("Expected 2024-01-02 03:04:05")
    }),
    it("client_timestamp_with_time_zone_decoder reads a timestamptz", fn() {
      // Act
      let result =
        with_schema(signed_up_at)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(
        Ok([
          from_calendar(
            Date(2024, January, 2),
            TimeOfDay(3, 4, 5, 250_000_000),
            utc_offset,
          ),
        ]),
      )
      |> or_fail_with("Expected 2024-01-02 03:04:05.25 UTC")
    }),
    it("timestamp_with_time_zone_decoder reads whole seconds", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          "SELECT timestamptz '2024-01-02 03:04:05+02'"
          |> query
          |> returning(at([0], timestamp_with_time_zone_decoder()))
          |> postgres.execute(db)
        })
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(
        Ok([
          from_calendar(
            Date(2024, January, 2),
            TimeOfDay(1, 4, 5, 0),
            utc_offset,
          ),
        ]),
      )
      |> or_fail_with("Expected 2024-01-02 01:04:05 UTC")
    }),
    it("client_date_type reads a date", fn() {
      // Act
      let result =
        with_schema(birthday)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(Ok([Date(2024, January, 2)]))
      |> or_fail_with("Expected 2024-01-02")
    }),
    it("client_time_of_day_type reads a time of day", fn() {
      // Act
      let result =
        with_schema(opening_time)
        |> result.map(fn(returned) { returned.rows })

      // Assert
      result
      |> should
      |> be_equal(Ok([TimeOfDay(3, 4, 5, 0)]))
      |> or_fail_with("Expected 03:04:05")
    }),
  ])
}

fn fingerprint_value_tests() {
  group("schema_fingerprint values", [
    it("is the SHA-256 of the empty text for no tables", fn() {
      // Act
      let result = with_schema(schema_fingerprint(_, []))

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
          with_schema(fn(db) {
            let schema = schema_name(db)
            fingerprint_text(db, [
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
    it(
      "gives the exact canonical text of a schema with each kind of fact",
      fn() {
        // Act
        let result =
          with_schema(fn(db) {
            run_all(db, exact_ddl)
            let schema = schema_name(db)
            fingerprint_text(db, [
              schema <> ".items",
              schema <> ".item_labels",
              schema <> ".events",
            ])
            |> result.map(fn(returned) {
              map(returned.rows, replace(_, schema <> ".", "fp."))
            })
          })

        // Assert
        result
        |> should
        |> be_equal(Ok([exact_text]))
        |> or_fail_with("Expected the exact canonical text")
      },
    ),
    it("client_schema_fingerprint changes when the users table is made", fn() {
      // Act
      let changed =
        with_schema(fn(db) {
          let schema = schema_name(db)
          let assert Ok(missing) = users_fingerprint(db, schema)
          run_all(db, [teams_table, users_table])
          let assert Ok(present) = users_fingerprint(db, schema)
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
    it("when a statement-level BEFORE trigger is added", fn() {
      // Act
      let changed =
        changes_fingerprint([items_table, touch_function], [
          "CREATE TRIGGER audit BEFORE INSERT ON items
            FOR EACH STATEMENT EXECUTE FUNCTION touch()",
        ])

      // Assert
      changed
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it(
      "when TimeZone is America/New_York in the transaction, and keeps it",
      fn() {
        // Act
        let result = fingerprint_with_setting("TimeZone", "America/New_York")

        // Assert
        result
        |> should
        |> be_equal(#(True, "America/New_York"))
        |> or_fail_with(
          "Expected the same fingerprint and TimeZone America/New_York",
        )
      },
    ),
    it("when DateStyle is SQL, DMY in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("DateStyle", "SQL, DMY")

      // Assert
      result
      |> should
      |> be_equal(#(True, "SQL, DMY"))
      |> or_fail_with("Expected the same fingerprint and DateStyle SQL, DMY")
    }),
    it("when IntervalStyle is iso_8601 in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("IntervalStyle", "iso_8601")

      // Assert
      result
      |> should
      |> be_equal(#(True, "iso_8601"))
      |> or_fail_with(
        "Expected the same fingerprint and IntervalStyle iso_8601",
      )
    }),
    it("when extra_float_digits is -5 in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("extra_float_digits", "-5")

      // Assert
      result
      |> should
      |> be_equal(#(True, "-5"))
      |> or_fail_with("Expected the same fingerprint and extra_float_digits -5")
    }),
    it(
      "when quote_all_identifiers is on in the transaction, and keeps it",
      fn() {
        // Act
        let result = fingerprint_with_setting("quote_all_identifiers", "on")

        // Assert
        result
        |> should
        |> be_equal(#(True, "on"))
        |> or_fail_with(
          "Expected the same fingerprint and quote_all_identifiers on",
        )
      },
    ),
    it("when bytea_output is escape in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("bytea_output", "escape")

      // Assert
      result
      |> should
      |> be_equal(#(True, "escape"))
      |> or_fail_with("Expected the same fingerprint and bytea_output escape")
    }),
    it("when lc_monetary is C in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("lc_monetary", "C")

      // Assert
      result
      |> should
      |> be_equal(#(True, "C"))
      |> or_fail_with("Expected the same fingerprint and lc_monetary C")
    }),
    it("when search_path is pg_temp in the transaction, and keeps it", fn() {
      // Act
      let result = fingerprint_with_setting("search_path", "pg_temp")

      // Assert
      result
      |> should
      |> be_equal(#(True, "pg_temp"))
      |> or_fail_with("Expected the same fingerprint and search_path pg_temp")
    }),
    it("when standard_conforming_strings is off in the transaction", fn() {
      // Act
      let result = fingerprint_with_old_strings()

      // Assert
      result
      |> should
      |> be_equal(#(True, True))
      |> or_fail_with("Expected the same fingerprint and the setting kept")
    }),
    it("when the session has other time and date settings", fn() {
      // Act
      let same =
        with_schema(fn(db) {
          run_all(db, settings_ddl)
          let tables = settings_tables(db)
          let assert Ok(baseline) = schema_fingerprint(db, tables)
          let assert Ok(other) =
            config()
            |> pool_size(1)
            |> connection_parameter(name: "TimeZone", value: "Asia/Kolkata")
            |> connection_parameter(name: "DateStyle", value: "German, DMY")
            |> connect()
          schema_fingerprint(other, tables) == Ok(baseline)
        })

      // Assert
      same
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the same fingerprint")
    }),
    it("when the search_path of the connection is different", fn() {
      // Act
      let same =
        with_schema(fn(db) {
          run_all(db, [
            "CREATE DOMAIN positive AS int CHECK (VALUE > 0)",
            "CREATE TABLE amounts (amount positive)",
          ])
          let tables = [schema_name(db) <> ".amounts"]
          let assert Ok(in_schema) = schema_fingerprint(db, tables)
          let assert Ok(other) =
            config()
            |> pool_size(1)
            |> connect()
          let assert Ok(in_public) = schema_fingerprint(other, tables)
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
        with_schema(fn(db) {
          let schema = schema_name(db)
          postgres.transaction(db, fn(transaction) {
            let assert Ok(_fingerprint) =
              schema_fingerprint(transaction, [schema <> ".ghost"])
            texts(transaction, "SHOW search_path")
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
    change_test(
      "when an INSTEAD OF row trigger is added",
      [
        items_table,
        "CREATE VIEW item_view AS SELECT id, name FROM items",
        touch_function,
      ],
      [
        "CREATE TRIGGER touch INSTEAD OF INSERT ON item_view
        FOR EACH ROW EXECUTE FUNCTION touch()",
      ],
    ),
    change_test(
      "when a view gets WITH CHECK OPTION",
      [items_table, "CREATE VIEW item_view AS SELECT id, name FROM items"],
      ["ALTER VIEW item_view SET (check_option = local)"],
    ),
    change_test(
      "when the expression of a generated column changes",
      [
        "CREATE TABLE items (id int, total int GENERATED ALWAYS AS (id * 2) STORED)",
      ],
      [
        "ALTER TABLE items DROP COLUMN total",
        "ALTER TABLE items ADD COLUMN total int GENERATED ALWAYS AS (id * 3) STORED",
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
        "ALTER TABLE events ATTACH PARTITION events_2026
          FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
      ],
      ["ALTER TABLE events_2026 ADD CONSTRAINT small_id CHECK (id < 9)"],
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
    change_test("when two columns swap places", [items_table], [
      "DROP TABLE items",
      "CREATE TABLE items (
          id int PRIMARY KEY,
          price int CONSTRAINT items_price_check CHECK (price > 0),
          name text NOT NULL
        )",
    ]),
    change_test(
      "when a unique index becomes a plain index",
      [items_table, "CREATE UNIQUE INDEX items_name_index ON items (name)"],
      [
        "DROP INDEX items_name_index",
        "CREATE INDEX items_name_index ON items (name)",
      ],
    ),
    change_test("when a partial unique index is added", [items_table], [
      "CREATE UNIQUE INDEX items_cheap_index ON items (name) WHERE price < 10",
    ]),
    change_test("when a DO INSTEAD NOTHING rule is added", [items_table], [
      "CREATE RULE ignore_insert AS ON INSERT TO items DO INSTEAD NOTHING",
    ]),
    change_test(
      "when the definition of a named view changes",
      [items_table, "CREATE VIEW item_view AS SELECT id, name FROM items"],
      [
        "CREATE OR REPLACE VIEW item_view AS SELECT id, name FROM items WHERE price > 1",
      ],
    ),
    change_test(
      "when the definition of a materialized view changes",
      [
        items_table,
        "CREATE MATERIALIZED VIEW item_view AS SELECT id FROM items",
      ],
      [
        "DROP MATERIALIZED VIEW item_view",
        "CREATE MATERIALIZED VIEW item_view AS SELECT id FROM items WHERE id > 1",
      ],
    ),
    change_test(
      "when a field of a composite column type is renamed",
      [
        "CREATE TYPE pair AS (left_side int, right_side text)",
        "CREATE TABLE items (pair pair)",
      ],
      ["ALTER TYPE pair RENAME ATTRIBUTE right_side TO other_side"],
    ),
    change_test(
      "when the subtype of a range column type changes",
      [
        "CREATE TYPE span AS RANGE (subtype = int4)",
        "CREATE TABLE items (id int, span span)",
      ],
      [
        "ALTER TABLE items DROP COLUMN span",
        "DROP TYPE span",
        "CREATE TYPE span AS RANGE (subtype = float8)",
        "ALTER TABLE items ADD COLUMN span span",
      ],
    ),
    change_test(
      "when a policy USING changes",
      [
        items_table,
        "ALTER TABLE items ENABLE ROW LEVEL SECURITY",
        "CREATE POLICY readers ON items FOR SELECT USING (price < 100)",
      ],
      ["ALTER POLICY readers ON items USING (price < 50)"],
    ),
    change_test(
      "when the roles of a policy change",
      [
        items_table,
        "ALTER TABLE items ENABLE ROW LEVEL SECURITY",
        "CREATE POLICY readers ON items FOR SELECT USING (price < 100)",
      ],
      ["ALTER POLICY readers ON items TO pg_monitor"],
    ),
    change_test(
      "when row level security is forced",
      [items_table, "ALTER TABLE items ENABLE ROW LEVEL SECURITY"],
      ["ALTER TABLE items FORCE ROW LEVEL SECURITY"],
    ),
    change_test("when a column becomes an identity column", [items_table], [
      "ALTER TABLE items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY",
    ]),
    change_test(
      "when a column becomes a generated column",
      ["CREATE TABLE items (price int, total int)"],
      [
        "ALTER TABLE items DROP COLUMN total",
        "ALTER TABLE items ADD COLUMN total int GENERATED ALWAYS AS (price * 2) STORED",
      ],
    ),
    change_test(
      "when a domain of a column gets NOT NULL",
      ["CREATE DOMAIN positive AS int", "CREATE TABLE items (price positive)"],
      ["ALTER DOMAIN positive SET NOT NULL"],
    ),
    change_test(
      "when the base domain of a domain gets a CHECK",
      [
        "CREATE DOMAIN amount AS int",
        "CREATE DOMAIN price AS amount",
        "CREATE TABLE items (price price)",
      ],
      ["ALTER DOMAIN amount ADD CHECK (VALUE > 0)"],
    ),
    change_test(
      "when the table gets a parent with INHERIT",
      [items_table, "CREATE TABLE base (id int)"],
      ["ALTER TABLE items INHERIT base"],
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
) -> UnitNode {
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
        with_schema(fn(db) {
          run_all(db, [items_table])
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = schema_fingerprint(db, tables)
          check_schema(db, [
            SchemaFingerprint(module: "app/sql/items", tables:, hash:),
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
      let result = with_schema(check_schema(_, []))

      // Assert
      result
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected Ok(Nil)")
    }),
    it("names each module whose fingerprint differs", fn() {
      // Act
      let result =
        with_schema(fn(db) {
          run_all(db, [items_table])
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = schema_fingerprint(db, tables)
          let result =
            check_schema(db, [
              SchemaFingerprint(module: "a", tables:, hash: "old"),
              SchemaFingerprint(module: "b", tables:, hash:),
              SchemaFingerprint(module: "c", tables:, hash: "older"),
            ])
          result
          == Error(
            SchemaChanged([
              SchemaMismatch(module: "a", tables:, expected: "old", found: hash),
              SchemaMismatch(
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
        with_schema(fn(db) {
          postgres.transaction(db, fn(transaction) {
            let assert Error(_division_by_zero) =
              test_database.execute(transaction, "SELECT 1 / 0")
            Error(
              check_schema(transaction, [
                SchemaFingerprint(
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
          TransactionRolledBack(
            Error(SchemaUnreadable(
              module: "app/sql/items",
              error: PostgresqlError(
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
        SchemaChanged([
          SchemaMismatch(
            module: "app/sql/users",
            tables: ["public.users", "public.teams"],
            expected: "aa",
            found: "bb",
          ),
          SchemaMismatch(
            module: "app/sql/items",
            tables: ["public.items"],
            expected: "cc",
            found: "dd",
          ),
        ])

      // Act
      let message = format_schema_check_error(error)

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
      let error = SchemaUnreadable(module: "app/sql/items", error: QueryTimeout)

      // Act
      let message = format_schema_check_error(error)

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
        with_schema(fn(db) {
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(missing) = schema_fingerprint(db, tables)
          run_all(db, [items_table])
          let assert Ok(present) = schema_fingerprint(db, tables)
          let message =
            check_models(db, [
              SchemaFingerprint(module: "app/sql/items", tables:, hash: missing),
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
        with_schema(fn(db) {
          let tables = [schema_name(db) <> ".items"]
          let assert Ok(hash) = schema_fingerprint(db, tables)
          check_models(db, [
            SchemaFingerprint(module: "app/sql/items", tables:, hash:),
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
fn users_error(sql: String) -> QueryError {
  use db <- with_schema
  run_all(db, [
    teams_table,
    users_table,
    nick_index,
    "INSERT INTO users (id, email, nick) VALUES (1, 'a@b', 'ace')",
  ])
  let assert Error(error) = test_database.execute(db, sql)
  error
}

fn second_column(db: Connection, sql: String) -> Result(List(Int), QueryError) {
  sql
  |> query
  |> returning(at([1], promised_not_null(int, "count.sql", "total")))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn optional_second_column(
  db: Connection,
) -> Result(List(Option(Int)), QueryError) {
  "SELECT 1, NULL::int"
  |> query
  |> returning(at([1], promised_not_null(optional(int), "count.sql", "total")))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn schema_name(db: Connection) -> String {
  let assert Ok([name]) = texts(db, "SELECT current_schema()")
  name
}

fn second_array(
  db: Connection,
  sql: String,
) -> Result(List(List(Int)), QueryError) {
  sql
  |> query
  |> returning(at([1], promised_elements_not_null(int, "list.sql", "numbers")))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn optional_second_array(
  db: Connection,
) -> Result(List(Option(List(Int))), QueryError) {
  "SELECT 1, NULL::int[]"
  |> query
  |> returning(at(
    [1],
    optional(promised_elements_not_null(int, "list.sql", "numbers")),
  ))
  |> postgres.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn run_all(db: Connection, statements: List(String)) -> Nil {
  each(statements, fn(statement) {
    let assert Ok(_returned) = test_database.execute(db, statement)
    Nil
  })
}

// Runs `setup` in a new schema, then `change`, and tells if the fingerprint
// of the tables items, events and item_view changed.
fn changes_fingerprint(setup: List(String), change: List(String)) -> Bool {
  use db <- with_schema
  let schema = schema_name(db)
  let tables = [schema <> ".items", schema <> ".events", schema <> ".item_view"]
  run_all(db, setup)
  let assert Ok(before) = schema_fingerprint(db, tables)
  run_all(db, change)
  let assert Ok(after) = schema_fingerprint(db, tables)
  before != after
}

fn settings_tables(db: Connection) -> List(String) {
  let schema = schema_name(db)
  [schema <> ".items", schema <> ".events"]
}

// Makes the tables of `settings_ddl`, then sets `name` to `value` for one
// transaction. Tells if the fingerprint in the transaction is the
// fingerprint outside it, and gives the value of `name` after the query.
fn fingerprint_with_setting(name: String, value: String) -> #(Bool, String) {
  use db <- with_schema
  run_all(db, settings_ddl)
  let tables = settings_tables(db)
  let assert Ok(baseline) = schema_fingerprint(db, tables)
  let assert Ok(result) =
    postgres.transaction(db, fn(transaction) {
      let assert Ok(_set) =
        test_database.execute(
          transaction,
          "SET LOCAL " <> name <> " = '" <> value <> "'",
        )
      let assert Ok(hash) = schema_fingerprint(transaction, tables)
      let assert Ok([shown]) = texts(transaction, "SHOW " <> name)
      Ok(#(hash == baseline, shown))
    })
  result
}

// PostgreSQL 19 refuses standard_conforming_strings = off. So on 19 and
// later the test sets it to on, the only value, and checks that the query
// keeps it.
fn fingerprint_with_old_strings() -> #(Bool, Bool) {
  let assert Ok([version]) =
    with_schema(texts(
      _,
      "SELECT (current_setting('server_version_num')::int >= 190000)::text",
    ))
  let value = case version {
    "true" -> "on"
    _ -> "off"
  }
  let #(same, shown) =
    fingerprint_with_setting("standard_conforming_strings", value)
  #(same, shown == value)
}
