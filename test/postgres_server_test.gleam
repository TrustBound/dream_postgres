//// Tests for what the guides say a real PostgreSQL server does: the
//// errors for a wrong login, a bad query and a slow query, the pool size,
//// the application name and the SSL modes on a server with SSL off. Each
//// test runs against the server of `fixtures/test_database`. The tests for
//// a server with SSL on are in `postgres_ssl_test`.

import dream_postgres/client as postgres
import dream_test/matchers.{be_between, be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/clock
import fixtures/database_url
import fixtures/test_database
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import pog
import snippets/guide_getting_started_startup.{describe as describe_error, start}

pub fn tests() -> TestSuite {
  describe("a real PostgreSQL 16 server", [
    startup_check_tests(),
    check_tests(),
    query_error_tests(),
    pool_tests(),
    connection_setting_tests(),
  ])
}

fn startup_check_tests() {
  group("the startup check of the getting started guide", [
    it("start answers Ok when SELECT 1 comes back", fn() {
      // Act
      let started = {
        use <- test_database.with_own_pools()
        start(test_database.url())
        |> result.replace(Nil)
        |> result.map_error(describe_error)
      }

      // Assert
      started
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the startup check to pass")
    }),
    it("start gives ConnectionUnavailable for a wrong password", fn() {
      // Arrange
      let config = test_database.config()
      let url =
        test_database.url_for(
          user: config.user,
          password: "wrong-password",
          database: config.database,
        )

      // Act
      let started = start_and_describe(url)

      // Assert
      started
      |> should
      |> be_equal(Error("The database did not answer: ConnectionUnavailable"))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong password")
    }),
    it("start gives ConnectionUnavailable for a user that does not exist", fn() {
      // Arrange
      let config = test_database.config()
      let url =
        test_database.url_for(
          user: "no_such_user",
          password: "dream",
          database: config.database,
        )

      // Act
      let started = start_and_describe(url)

      // Assert
      started
      |> should
      |> be_equal(Error("The database did not answer: ConnectionUnavailable"))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong user")
    }),
    it(
      "start gives ConnectionUnavailable for a database that does not exist",
      fn() {
        // Arrange
        let config = test_database.config()
        let url =
          test_database.url_for(
            user: config.user,
            password: "dream",
            database: "no_such_database",
          )

        // Act
        let started = start_and_describe(url)

        // Assert
        started
        |> should
        |> be_equal(Error("The database did not answer: ConnectionUnavailable"))
        |> or_fail_with("Expected ConnectionUnavailable for a wrong database")
      },
    ),
    it("start gives the wrong-password error after about 2 seconds", fn() {
      // Arrange
      let config = test_database.config()
      let url =
        test_database.url_for(
          user: config.user,
          password: "wrong-password",
          database: config.database,
        )
      let started_at = clock.now_in_milliseconds()

      // Act
      let _started = start_and_describe(url)
      let elapsed = clock.now_in_milliseconds() - started_at

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
  ])
}

fn check_tests() {
  group("check", [
    it("gives Ok(Nil) when the server answers", fn() {
      // Act
      let checked = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url())
        |> result.map(postgres.check)
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Ok(Nil)))
      |> or_fail_with("Expected Ok(Nil) from check")
    }),
    it("gives ConnectionUnavailable for a wrong password", fn() {
      // Act
      let checked = check_url(wrong_password_url()).result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong password")
    }),
    it("gives the wrong-password error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(wrong_password_url()).elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for a database that does not exist", fn() {
      // Act
      let checked = check_url(missing_database_url()).result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong database")
    }),
    it("gives the missing-database error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(missing_database_url()).elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for a port with no listener", fn() {
      // Act
      let checked = check_url(database_url.unused_database_url()).result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with(
        "Expected ConnectionUnavailable for a port with no listener",
      )
    }),
    it("gives the no-listener error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(database_url.unused_database_url()).elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for pool_size(0)", fn() {
      // Act
      let checked = check_empty_pool().result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for pool_size(0)")
    }),
    it("gives the pool_size(0) error after about 2 seconds", fn() {
      // Act
      let elapsed = check_empty_pool().elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
  ])
}

fn query_error_tests() {
  group("query errors", [
    it("a syntax error gives PostgresqlError with code 42601", fn() {
      // Act
      let answer =
        test_database.with_schema(fn(db) {
          test_database.execute(db, "SELEC 1")
        })

      // Assert
      answer
      |> should
      |> be_equal(
        Error(pog.PostgresqlError(
          code: "42601",
          name: "syntax_error",
          message: "syntax error at or near \"SELEC\"",
        )),
      )
      |> or_fail_with("Expected the syntax error")
    }),
    it("a query that runs past pog.timeout gives QueryTimeout", fn() {
      // Act
      let answer =
        test_database.with_schema(fn(db) {
          pog.query("SELECT pg_sleep(1)")
          |> pog.timeout(200)
          |> pog.execute(db)
        })

      // Assert
      answer
      |> should
      |> be_equal(Error(pog.QueryTimeout))
      |> or_fail_with("Expected QueryTimeout")
    }),
    it("QueryTimeout comes back when the pog.timeout runs out", fn() {
      // Arrange
      let started_at = clock.now_in_milliseconds()

      // Act
      let _answer =
        test_database.with_schema(fn(db) {
          pog.query("SELECT pg_sleep(1)")
          |> pog.timeout(200)
          |> pog.execute(db)
        })
      let elapsed = clock.now_in_milliseconds() - started_at

      // Assert
      elapsed
      |> should
      |> be_between(200, 1000)
      |> or_fail_with("Expected the timeout before the 1 second sleep ends")
    }),
  ])
}

fn pool_tests() {
  group("the pool", [
    it("a pool of 1 runs two queries at the same time on one connection", fn() {
      // Act
      let answers = run_two_slow_queries_on_a_pool_of_one()

      // Assert
      ran_on_one_connection(answers)
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected both queries on the same connection")
    }),
    it("a pool of 1 makes the second query wait for the first", fn() {
      // Act
      let answers = run_two_slow_queries_on_a_pool_of_one()

      // Assert
      list.map(answers, fn(answer) { answer.elapsed })
      |> list.fold(0, int.max)
      |> should
      |> be_between(1000, 2000)
      |> or_fail_with("Expected the second 0.5 s query to end after 1 s")
    }),
    it("the server allows 100 connections, the PostgreSQL default", fn() {
      // Act
      let setting =
        test_database.with_schema(fn(db) {
          test_database.texts(db, "SHOW max_connections")
        })

      // Assert
      setting
      |> should
      |> be_equal(Ok(["100"]))
      |> or_fail_with("Expected max_connections 100")
    }),
    it("pool_size(0) starts a pool whose queries never get a connection", fn() {
      // Act
      let answer = {
        use <- test_database.with_own_pools()
        test_database.config()
        |> postgres.pool_size(0)
        |> postgres.connect()
        |> result.map(test_database.texts(_, "SELECT 'answered'"))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok from connect and ConnectionUnavailable")
    }),
    it("connect returns Ok for a wrong password, and the query fails", fn() {
      // Act
      let answer = {
        use <- test_database.with_own_pools()
        test_database.config()
        |> postgres.password("wrong-password")
        |> postgres.pool_size(1)
        |> postgres.connect()
        |> result.map(test_database.texts(_, "SELECT 'answered'"))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok from connect and ConnectionUnavailable")
    }),
  ])
}

fn connection_setting_tests() {
  group("connection settings", [
    it("application_name from the URL does not reach the server", fn() {
      // Act
      let name = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url() <> "?application_name=billing")
        |> result.map(test_database.texts(
          _,
          "SELECT current_setting('application_name')",
        ))
      }

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["nonode@nohost"])))
      |> or_fail_with("Expected the Erlang node name, which pgo sends last")
    }),
    it("sslmode=disable connects without TLS", fn() {
      // Act
      let ssl = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url() <> "?sslmode=disable")
        |> result.map(test_database.texts(
          _,
          "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
        ))
      }

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["false"])))
      |> or_fail_with("Expected a connection without TLS")
    }),
    it(
      "sslmode=require gives ConnectionUnavailable on a server without SSL",
      fn() {
        // Act
        let answer = {
          use <- test_database.with_own_pools()
          postgres.from_url(test_database.url() <> "?sslmode=require")
          |> result.map(test_database.texts(_, "SELECT 'answered'"))
        }

        // Assert
        answer
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
    it(
      "sslmode=verify-full gives ConnectionUnavailable on a server without SSL",
      fn() {
        // Act
        let answer = {
          use <- test_database.with_own_pools()
          postgres.from_url(test_database.url() <> "?sslmode=verify-full")
          |> result.map(test_database.texts(_, "SELECT 'answered'"))
        }

        // Assert
        answer
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
    it(
      "sslmode=verify-ca gives ConnectionUnavailable on a server without SSL",
      fn() {
        // Act
        let answer = {
          use <- test_database.with_own_pools()
          postgres.from_url(test_database.url() <> "?sslmode=verify-ca")
          |> result.map(test_database.texts(_, "SELECT 'answered'"))
        }

        // Assert
        answer
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
  ])
}

fn start_and_describe(url: String) -> Result(Nil, String) {
  use <- test_database.with_own_pools()
  start(url)
  |> result.replace(Nil)
  |> result.map_error(describe_error)
}

type TimedCheck(start_error) {
  TimedCheck(
    result: Result(Result(Nil, pog.QueryError), start_error),
    elapsed: Int,
  )
}

// Starts a pool from `url`, runs `postgres.check` on it and stops the pool.
// Gives the answer and the time in milliseconds from the start of the pool
// until the answer came.
fn check_url(url: String) -> TimedCheck(postgres.FromUrlError) {
  use <- test_database.with_own_pools()
  let started_at = clock.now_in_milliseconds()
  let checked =
    postgres.from_url(url)
    |> result.map(postgres.check)
  TimedCheck(result: checked, elapsed: clock.now_in_milliseconds() - started_at)
}

// Starts a pool of size 0 on the test server, runs `postgres.check` on it
// and stops the pool.
fn check_empty_pool() -> TimedCheck(actor.StartError) {
  use <- test_database.with_own_pools()
  let started_at = clock.now_in_milliseconds()
  let checked =
    test_database.config()
    |> postgres.pool_size(0)
    |> postgres.connect()
    |> result.map(postgres.check)
  TimedCheck(result: checked, elapsed: clock.now_in_milliseconds() - started_at)
}

fn wrong_password_url() -> String {
  let config = test_database.config()
  test_database.url_for(
    user: config.user,
    password: "wrong-password",
    database: config.database,
  )
}

fn missing_database_url() -> String {
  let config = test_database.config()
  test_database.url_for(
    user: config.user,
    password: "dream",
    database: "no_such_database",
  )
}

type SlowAnswer {
  SlowAnswer(backend: Result(List(Int), pog.QueryError), elapsed: Int)
}

// Starts a pool of 1 connection and runs two queries of 0.5 seconds at the
// same time. Each answer holds the process id of the server backend that
// ran the query, and the time from the start until the answer came.
fn run_two_slow_queries_on_a_pool_of_one() -> List(SlowAnswer) {
  use <- test_database.with_own_pools()
  let assert Ok(db) =
    test_database.config()
    |> postgres.pool_size(1)
    |> postgres.connect()
  let answers = process.new_subject()
  let started_at = clock.now_in_milliseconds()
  let run_slow_query = fn() {
    let backend =
      pog.query("SELECT pg_backend_pid(), pg_sleep(0.5)::text")
      |> pog.returning(decode.at([0], decode.int))
      |> pog.execute(db)
      |> result.map(fn(returned) { returned.rows })
    process.send(
      answers,
      SlowAnswer(backend:, elapsed: clock.now_in_milliseconds() - started_at),
    )
  }
  let _first = process.spawn(run_slow_query)
  let _second = process.spawn(run_slow_query)
  [process.receive_forever(answers), process.receive_forever(answers)]
}

// True when both queries succeeded on the same server backend.
fn ran_on_one_connection(answers: List(SlowAnswer)) -> Bool {
  case answers {
    [
      SlowAnswer(backend: Ok([first]), ..),
      SlowAnswer(backend: Ok([second]), ..),
    ] -> first == second
    _ -> False
  }
}
