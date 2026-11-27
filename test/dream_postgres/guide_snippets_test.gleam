//// Tests for the code of the README and of the guides on getting started,
//// connecting, pool tuning, queries, transactions and codecs: each file of
//// `test/snippets` that they show runs against the PostgreSQL 16 driver
//// server.

import dream_errors.{Failed, Invalid, NotFound, Retry, Timeout, Unavailable}
import dream_postgres.{ReconnectStep, one, parameter, query, script, single}
import dream_postgres/codec
import dream_postgres/error
import dream_postgres/sql_state.{UniqueViolation}
import dream_test/context
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit_context.{before_all, describe, group, it}
import driver/servers.{first_driver_server}
import fixtures/driver_tls
import fixtures/server_pools
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import matchers/extract_driver_times.{extract_driver_times}
import matchers/have_kind_and_sql_state.{have_kind_and_sql_state}
import matchers/run_and_stop_pool.{run_and_stop_pool}
import matchers/run_and_stop_supervisor.{run_and_stop_supervisor}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_on_pool_with_subject.{run_on_pool_with_subject}
import matchers/run_on_started_pool.{run_on_started_pool}
import matchers/run_with_example_tables.{run_with_example_tables}
import snippets/address_codec.{Address, address_codec}
import snippets/balance_report.{balance_report}
import snippets/balances.{balances}
import snippets/behind_pgbouncer.{behind_pgbouncer}
import snippets/busy_service.{busy_service}
import snippets/category_path_codec.{CategoryPath, category_path_codec}
import snippets/connect.{connect}
import snippets/count_users.{count_users}
import snippets/create_user.{create_user}
import snippets/database_url.{connect_with_url}
import snippets/distant_server.{distant_server}
import snippets/dropped_error.{create_user_and_drop_error}
import snippets/email_taken.{is_email_taken}
import snippets/find_user.{find_user}
import snippets/find_users.{find_users}
import snippets/import_users.{import_users}
import snippets/list_users.{list_users}
import snippets/mood_codec.{Sad, mood_codec}
import snippets/move_balance.{move_balance}
import snippets/move_money.{NotEnoughFunds, move_money}
import snippets/password_check.{password_matches}
import snippets/pool_events.{event_line, start_with_pool_events}
import snippets/reconnect_settings.{slow_reconnects, without_jitter}
import snippets/rename_user.{rename_user}
import snippets/server_notices.{notice_line, start_with_notices}
import snippets/sign_up.{sign_up}
import snippets/signup_answer.{signup_answer}
import snippets/supervised_pool.{current_database, start_supervisor}
import snippets/theme_json.{Theme, theme_document, theme_from_document}
import snippets/user_names.{user_names}
import snippets/user_row.{User}
import snippets/verified_tls.{verified_tls}

pub fn tests() -> TestSuite {
  describe(
    "the code of the guides on PostgreSQL 16",
    context.setup(server_pools.start, teardown: server_pools.stop),
    [
      group("connecting", [
        before_all(server_pools.choose_version(first_driver_server.version)),
        ..connecting_tests()
      ]),
      group("queries", [
        before_all(server_pools.choose_version(first_driver_server.version)),
        ..query_tests()
      ]),
      group("errors", [
        before_all(server_pools.choose_version(first_driver_server.version)),
        ..error_tests()
      ]),
      group("transactions", [
        before_all(server_pools.choose_version(first_driver_server.version)),
        ..transaction_tests()
      ]),
      group("codecs", [
        before_all(server_pools.choose_version(first_driver_server.version)),
        ..codec_tests()
      ]),
    ],
  )
}

fn connecting_tests() {
  [
    it("connect.gleam starts a pool that answers", fn(_pools) {
      // Act and assert
      connect(first_driver_server.port)
      |> should
      |> be_ok()
      |> run_and_stop_pool(fn(connection) {
        query("SELECT 1") |> one(single(codec.int), connection)
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected the pool of connect to answer 1")
    }),
    it("database_url.gleam starts a pool that answers", fn(_pools) {
      // Act and assert
      connect_with_url(
        "postgres://dream:dream@localhost:"
        <> int.to_string(first_driver_server.port)
        <> "/dream_test?sslmode=disable",
      )
      |> should
      |> be_ok()
      |> run_and_stop_pool(fn(connection) {
        query("SELECT 1") |> one(single(codec.int), connection)
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected the pool of the URL to answer 1")
    }),
    it("verified_tls.gleam connects over TLS to the test server", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> verified_tls(driver_tls.certificate_authority)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        |> one(single(codec.bool), connection)
      })
      |> be_ok()
      |> be_equal(True)
      |> or_fail_with("Expected a connection over TLS")
    }),
    it("slow_reconnects in reconnect_settings.gleam starts a pool", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> slow_reconnects
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> one(single(codec.int), connection)
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected the pool to answer 1")
    }),
    it(
      "without_jitter in reconnect_settings.gleam waits the capped delay",
      fn(_pools) {
        // Act and assert
        ReconnectStep(
          attempt: 2,
          capped_delay_milliseconds: 2000,
          previous_wait_milliseconds: 1000,
        )
        |> without_jitter
        |> should
        |> be_equal(2000)
        |> or_fail_with("Expected a wait of 2000 ms")
      },
    ),
    it("behind_pgbouncer.gleam runs a query twice with no cache", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> behind_pgbouncer
      |> should
      |> run_on_started_pool(fn(connection) {
        use _first <- result.try(
          query("SELECT $1::int8")
          |> parameter(codec.int, 1)
          |> one(single(codec.int), connection),
        )
        query("SELECT $1::int8")
        |> parameter(codec.int, 2)
        |> one(single(codec.int), connection)
      })
      |> be_ok()
      |> be_equal(2)
      |> or_fail_with("Expected the second run to answer 2")
    }),
    it("busy_service.gleam starts a pool of 20 connections", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> busy_service
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> one(single(codec.int), connection)
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected the pool to answer 1")
    }),
    it("distant_server.gleam gives the driver each of its times", fn(_pools) {
      // Act and assert
      dream_postgres.default_config()
      |> distant_server
      |> should
      |> extract_driver_times()
      |> be_equal(#(3000, 15_000, 1000, 60_000, 5000))
      |> or_fail_with("Expected 3000, 15_000, 1000, 60_000 and 5000")
    }),
    it("server_notices.gleam sends a notice to the subject", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> start_with_notices
      |> should
      |> be_ok()
      |> run_on_pool_with_subject(fn(connection, notice_subject) {
        let _ran =
          script(
            "DO $$ BEGIN RAISE NOTICE 'the table is empty'; END $$",
            connection,
          )
        process.receive(notice_subject, 2000) |> result.map(notice_line)
      })
      |> be_ok()
      |> be_equal("NOTICE: the table is empty")
      |> or_fail_with("Expected the line of the notice")
    }),
    it("pool_events.gleam sends the first connect to the subject", fn(_pools) {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> dream_postgres.pool_size(1)
      |> start_with_pool_events
      |> should
      |> be_ok()
      |> run_on_pool_with_subject(fn(_connection, event_subject) {
        process.receive(event_subject, 5000) |> result.map(event_line)
      })
      |> be_ok()
      |> be_equal("connection 0 connected")
      |> or_fail_with("Expected the line of the first connect")
    }),
    it("supervised_pool.gleam reaches the pool by its name", fn(_pools) {
      // Arrange
      let pool_name = process.new_name("guide_database")

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> start_supervisor(pool_name)
      |> should
      |> be_ok()
      |> run_and_stop_supervisor(fn() { current_database(pool_name) })
      |> be_ok()
      |> be_equal("dream_test")
      |> or_fail_with("Expected the database dream_test")
    }),
  ]
}

fn query_tests() {
  [
    it("create_user.gleam gives the stored user", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(create_user(_, "ann@example.com", "Ann"))
      |> be_ok()
      |> be_equal(User(id: 1, email: "ann@example.com", name: "Ann"))
      |> or_fail_with("Expected the user Ann with the id 1")
    }),
    it("password_check.gleam takes the right password", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_on_pool(password_matches(
        _,
        "correct horse",
        "4104d36f8da2c254349f85836793ebe029e0c957063a34c91c2e9203187b5631",
      ))
      |> be_ok()
      |> be_equal(True)
      |> or_fail_with("Expected the password to match its hash")
    }),
    it("password_check.gleam refuses a wrong password", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_on_pool(password_matches(
        _,
        "battery staple",
        "4104d36f8da2c254349f85836793ebe029e0c957063a34c91c2e9203187b5631",
      ))
      |> be_ok()
      |> be_equal(False)
      |> or_fail_with("Expected another password not to match the hash")
    }),
    it("find_user.gleam finds a stored user", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        find_user(connection, "ann@example.com")
      })
      |> be_ok()
      |> be_equal(Some(User(id: 1, email: "ann@example.com", name: "Ann")))
      |> or_fail_with("Expected to find Ann")
    }),
    it("find_user.gleam gives None for an unknown email", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(find_user(_, "nobody@example.com"))
      |> be_ok()
      |> be_equal(None)
      |> or_fail_with("Expected no user")
    }),
    it("list_users.gleam gives every user in order", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        use _bob <- result.try(create_user(connection, "bob@example.com", "Bob"))
        list_users(connection)
      })
      |> be_ok()
      |> be_equal([
        User(id: 1, email: "ann@example.com", name: "Ann"),
        User(id: 2, email: "bob@example.com", name: "Bob"),
      ])
      |> or_fail_with("Expected Ann, then Bob")
    }),
    it("rename_user.gleam changes one row", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        rename_user(connection, ann.id, "Anne")
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected 1 changed row")
    }),
    it("rename_user.gleam changes no row for an unknown id", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(rename_user(_, 99, "Anne"))
      |> be_ok()
      |> be_equal(0)
      |> or_fail_with("Expected no changed row")
    }),
    it("count_users.gleam counts the users", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        count_users(connection)
      })
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected 1 user")
    }),
    it("user_names.gleam reads by position and by name", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        user_names(connection)
      })
      |> be_ok()
      |> be_equal([#(1, "Ann")])
      |> or_fail_with("Expected the id and the name of Ann")
    }),
    it("find_users.gleam finds the users of the ids", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        use _bob <- result.try(create_user(connection, "bob@example.com", "Bob"))
        find_users(connection, [2, 3])
      })
      |> be_ok()
      |> be_equal([User(id: 2, email: "bob@example.com", name: "Bob")])
      |> or_fail_with("Expected only Bob")
    }),
    it("balances.gleam reads a missing account as None", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _account <- result.try(sign_up(connection, "ann@example.com", "Ann"))
        use _bob <- result.try(create_user(connection, "bob@example.com", "Bob"))
        balances(connection)
      })
      |> be_ok()
      |> be_equal([#("ann@example.com", Some(0)), #("bob@example.com", None)])
      |> or_fail_with("Expected a balance for Ann and none for Bob")
    }),
  ]
}

fn error_tests() {
  [
    it("a taken email is a conflict on users_email_key", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use _ann <- result.try(create_user(connection, "ann@example.com", "Ann"))
        create_user(connection, "ann@example.com", "Ann")
      })
      |> be_error()
      |> have_kind_and_sql_state()
      |> be_equal(#("conflict", Some(UniqueViolation)))
      |> or_fail_with("Expected a conflict with the SQLSTATE unique_violation")
    }),
    it("email_taken.gleam finds the taken email", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = create_user(connection, "ann@example.com", "Ann")
        create_user(connection, "ann@example.com", "Ann")
        |> result.map_error(is_email_taken)
      })
      |> be_error()
      |> be_equal(True)
      |> or_fail_with("Expected the taken email")
    }),
    it("signup_answer.gleam answers 201 for a new user", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        create_user(connection, "ann@example.com", "Ann") |> signup_answer
      })
      |> be_equal(#(201, "Welcome."))
      |> or_fail_with("Expected 201")
    }),
    it("signup_answer.gleam answers 409 for a taken email", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = create_user(connection, "ann@example.com", "Ann")
        create_user(connection, "ann@example.com", "Ann") |> signup_answer
      })
      |> be_equal(#(409, "That email has an account already."))
      |> or_fail_with("Expected 409")
    }),
    ..list.map(
      [
        #(Invalid("null value", no_connection()), 400),
        #(Retry("deadlock detected", no_connection(), None), 503),
        #(Unavailable("refused", no_connection()), 503),
        #(Timeout("canceled", no_connection()), 503),
        #(NotFound("no row"), 500),
        #(Failed("syntax error", no_connection()), 500),
      ],
      fn(example) {
        let #(failure, status) = example
        it(
          "signup_answer.gleam answers " <> string.inspect(failure),
          fn(_pools) {
            // Act and assert
            signup_answer(Error(failure)).0
            |> should
            |> be_equal(status)
            |> or_fail_with("Expected " <> int.to_string(status))
          },
        )
      },
    )
  ]
}

fn no_connection() -> error.PostgresError {
  error.PostgresError(query_name: None, sql: None, reason: error.NoConnection)
}

fn transaction_tests() {
  [
    it("move_money.gleam moves the money", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = sign_up(connection, "ann@example.com", "Ann")
        let _bob = sign_up(connection, "bob@example.com", "Bob")
        let _filled =
          script("UPDATE accounts SET balance = 100 WHERE id = 1", connection)
        let moved = move_money(connection, 1, 2, 40)
        #(moved, balances(connection))
      })
      |> be_equal(#(
        Ok(Nil),
        Ok([#("ann@example.com", Some(60)), #("bob@example.com", Some(40))]),
      ))
      |> or_fail_with("Expected 60 in the first account and 40 in the second")
    }),
    it("move_money.gleam rolls back when the funds are too low", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = sign_up(connection, "ann@example.com", "Ann")
        let _bob = sign_up(connection, "bob@example.com", "Bob")
        let _filled =
          script("UPDATE accounts SET balance = 40 WHERE id = 1", connection)
        let refused = move_money(connection, 1, 2, 1000)
        #(refused, balances(connection))
      })
      |> be_equal(#(
        Error(Invalid(
          "not enough funds",
          NotEnoughFunds(balance: 40, wanted: 1000),
        )),
        Ok([#("ann@example.com", Some(40)), #("bob@example.com", Some(0))]),
      ))
      |> or_fail_with("Expected NotEnoughFunds and no change")
    }),
    it("sign_up.gleam gives the id of the new account", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(sign_up(_, "ann@example.com", "Ann"))
      |> be_ok()
      |> be_equal(1)
      |> or_fail_with("Expected the account 1")
    }),
    it("balance_report.gleam counts users and sums balances", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = sign_up(connection, "ann@example.com", "Ann")
        let _filled = script("UPDATE accounts SET balance = 70", connection)
        balance_report(connection)
      })
      |> be_ok()
      |> be_equal(#(1, 70))
      |> or_fail_with("Expected 1 user and a total of 70")
    }),
    it("move_balance.gleam moves the whole balance", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = sign_up(connection, "ann@example.com", "Ann")
        let _bob = sign_up(connection, "bob@example.com", "Bob")
        let _filled =
          script("UPDATE accounts SET balance = 25 WHERE id = 1", connection)
        let moved = move_balance(connection, from: 1, to: 2)
        #(moved, balances(connection))
      })
      |> be_equal(#(
        Ok(25),
        Ok([#("ann@example.com", Some(0)), #("bob@example.com", Some(25))]),
      ))
      |> or_fail_with("Expected 25 to move from Ann to Bob")
    }),
    it("move_balance.gleam rolls back when an account is missing", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let _ann = sign_up(connection, "ann@example.com", "Ann")
        let _filled = script("UPDATE accounts SET balance = 25", connection)
        let _missing = move_balance(connection, from: 1, to: 9)
        balances(connection)
      })
      |> be_ok()
      |> be_equal([#("ann@example.com", Some(25))])
      |> or_fail_with("Expected the balance of Ann to stay 25")
    }),
    it("import_users.gleam skips a taken email and keeps the others", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        let imported =
          import_users(connection, [
            #("ann@example.com", "Ann"),
            #("ann@example.com", "Ann again"),
            #("bob@example.com", "Bob"),
          ])
        #(imported, count_users(connection))
      })
      |> be_equal(#(Ok(2), Ok(2)))
      |> or_fail_with("Expected 2 users stored")
    }),
    it(
      "dropped_error.gleam fails at commit with the failed statement",
      fn(pools) {
        // Act and assert
        pools
        |> should
        |> run_with_example_tables(fn(connection) {
          let _ann = create_user(connection, "ann@example.com", "Ann")
          create_user_and_drop_error(connection, "ann@example.com", "Ann")
        })
        |> be_error()
        |> have_kind_and_sql_state()
        |> be_equal(#("failed", Some(UniqueViolation)))
        |> or_fail_with(
          "Expected failed, with the unique violation as the cause",
        )
      },
    ),
  ]
}

fn codec_tests() {
  [
    it("mood_codec.gleam writes and reads an enum", fn(pools) {
      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use Nil <- result.try(script(
          "CREATE TYPE mood AS ENUM ('happy', 'sad')",
          connection,
        ))
        query("SELECT $1::mood")
        |> parameter(mood_codec(), Sad)
        |> one(single(mood_codec()), connection)
      })
      |> be_ok()
      |> be_equal(Sad)
      |> or_fail_with("Expected Sad")
    }),
    it("address_codec.gleam writes and reads a composite", fn(pools) {
      // Arrange
      let address = Address(street: "1 Main St", city: None)

      // Act and assert
      pools
      |> should
      |> run_with_example_tables(fn(connection) {
        use Nil <- result.try(script(
          "CREATE TYPE address AS (street text, city text)",
          connection,
        ))
        query("SELECT $1::address")
        |> parameter(address_codec(), address)
        |> one(single(address_codec()), connection)
      })
      |> be_ok()
      |> be_equal(address)
      |> or_fail_with("Expected the same address")
    }),
    it("category_path_codec.gleam writes and reads an ltree", fn(pools) {
      // Arrange
      let path = CategoryPath(labels: ["shop", "books", "poetry"])

      // Act and assert
      pools
      |> should
      |> run_on_pool(fn(connection) {
        query("SELECT $1::ltree")
        |> parameter(category_path_codec(), path)
        |> one(single(category_path_codec()), connection)
      })
      |> be_ok()
      |> be_equal(path)
      |> or_fail_with("Expected the same path")
    }),
    it("theme_json.gleam writes and reads a jsonb document", fn(pools) {
      // Arrange
      let theme = Theme(dark: True, font_size: 14)

      // Act and assert
      pools
      |> should
      |> run_on_pool(fn(connection) {
        query("SELECT $1::jsonb")
        |> parameter(codec.jsonb, theme_document(theme))
        |> one(single(codec.jsonb), connection)
        |> result.map(theme_from_document)
      })
      |> be_ok()
      |> be_equal(Ok(theme))
      |> or_fail_with("Expected the same theme")
    }),
  ]
}
