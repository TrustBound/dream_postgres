//// Tests for what the guides say a real PostgreSQL server does: the errors for
//// a wrong login, a bad query and a slow query, the pool size, the application
//// name, the client encoding and the SSL modes on a server with SSL off. Each
//// test runs against the server of `fixtures/test_database`. The tests for a
//// server with SSL on are in `postgres_ssl_test`.

import dream_postgres/client as postgres
import dream_postgres_client
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
import snippets/guide_connecting_supervised.{start_supervised}
import snippets/guide_getting_started_startup.{describe as describe_error, start}

pub fn tests() -> TestSuite {
  describe("a real PostgreSQL 16 server", [
    startup_check_tests(),
    check_tests(),
    query_error_tests(),
    pool_tests(),
    connection_setting_tests(),
    application_name_tests(),
    url_parameter_tests(),
    parameter_permission_tests(),
    null_byte_tests(),
    protocol_option_tests(),
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
      |> be_between(1500, 4500)
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
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong password")
    }),
    it("gives the wrong-password error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(wrong_password_url()).elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 4500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for a database that does not exist", fn() {
      // Act
      let checked = check_url(missing_database_url()).result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for a wrong database")
    }),
    it("gives the missing-database error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(missing_database_url()).elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 4500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for a port with no listener", fn() {
      // Act
      let checked = check_url(database_url.unused_database_url()).result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
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
      |> be_between(1500, 4500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("gives ConnectionUnavailable for pool_size(0)", fn() {
      // Act
      let checked = check_empty_pool().result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable for pool_size(0)")
    }),
    it("gives the pool_size(0) error after about 2 seconds", fn() {
      // Act
      let elapsed = check_empty_pool().elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 4500)
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
        Error(dream_postgres_client.PostgresqlError(
          code: "42601",
          name: "syntax_error",
          message: "syntax error at or near \"SELEC\"",
        )),
      )
      |> or_fail_with("Expected the syntax error")
    }),
    it(
      "a query that runs past dream_postgres_client.timeout gives QueryTimeout",
      fn() {
        // Act
        let answer =
          test_database.with_schema(fn(db) {
            dream_postgres_client.query("SELECT pg_sleep(1)")
            |> dream_postgres_client.timeout(200)
            |> dream_postgres_client.execute(db)
          })

        // Assert
        answer
        |> should
        |> be_equal(Error(dream_postgres_client.QueryTimeout))
        |> or_fail_with("Expected QueryTimeout")
      },
    ),
    it(
      "QueryTimeout comes back when the dream_postgres_client.timeout runs out",
      fn() {
        // Arrange
        let started_at = clock.now_in_milliseconds()

        // Act
        let _answer =
          test_database.with_schema(fn(db) {
            dream_postgres_client.query("SELECT pg_sleep(1)")
            |> dream_postgres_client.timeout(200)
            |> dream_postgres_client.execute(db)
          })
        let elapsed = clock.now_in_milliseconds() - started_at

        // Assert
        elapsed
        |> should
        |> be_between(200, 1000)
        |> or_fail_with("Expected the timeout before the 1 second sleep ends")
      },
    ),
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
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
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
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok from connect and ConnectionUnavailable")
    }),
  ])
}

fn connection_setting_tests() {
  group("connection settings", [
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
        |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
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
        |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
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
        |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
  ])
}

const application_name_query = "SELECT current_setting('application_name')"

const client_encoding_query =
  "SELECT setting || ' from ' || source FROM pg_settings WHERE name = 'client_encoding'"

fn application_name_tests() {
  group("application_name", [
    it("application_name from the URL reaches the server", fn() {
      // Act
      let name = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url() <> "?application_name=billing")
        |> result.map(test_database.texts(_, application_name_query))
      }

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["billing"])))
      |> or_fail_with("Expected the application name from the URL")
    }),
    it(
      "application_name from dream_postgres_client.connection_parameter reaches the server",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )

        // Act
        let name = connect_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it(
      "application_name reaches the server with search_path set before it",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "search_path",
            value: "public",
          )
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )

        // Act
        let name = connect_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it(
      "application_name reaches the server with search_path set after it",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )
          |> dream_postgres_client.connection_parameter(
            name: "search_path",
            value: "public",
          )

        // Act
        let name = connect_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it(
      "application_name from the URL reaches the server with timezone set after it",
      fn() {
        // Arrange
        let config =
          url_config("?application_name=billing")
          |> dream_postgres_client.connection_parameter(
            name: "timezone",
            value: "UTC",
          )

        // Act
        let name = connect_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the URL")
      },
    ),
    it(
      "application_name reaches the server with the caller's client_encoding",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "client_encoding",
            value: "UTF8",
          )
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )

        // Act
        let name = connect_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it(
      "the caller's client_encoding reaches the server with an application_name",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )
          |> dream_postgres_client.connection_parameter(
            name: "client_encoding",
            value: "SQL_ASCII",
          )

        // Act
        let encoding = connect_and_select(config, client_encoding_query)

        // Assert
        encoding
        |> should
        |> be_equal(Ok(Ok(["SQL_ASCII from client"])))
        |> or_fail_with("Expected the client_encoding of the caller")
      },
    ),
    // PostgreSQL reads parameter names without case, and so does
    // dream_postgres_driver: it sees `Application_Name` as the caller's name
    // and does not send the Erlang node name too.
    it("Application_Name in mixed case reaches the server", fn() {
      // Arrange
      let config =
        test_database.config()
        |> dream_postgres_client.connection_parameter(
          name: "Application_Name",
          value: "billing",
        )

      // Act
      let name = connect_and_select(config, application_name_query)

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["billing"])))
      |> or_fail_with("Expected the application name in mixed case")
    }),
    it(
      "application_name from the URL reaches the server under dream_postgres_client.supervised",
      fn() {
        // Act
        let name = {
          use <- test_database.with_own_pools()
          start_supervised(test_database.url() <> "?application_name=billing")
          |> result.map(test_database.texts(_, application_name_query))
        }

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the URL")
      },
    ),
    it(
      "dream_postgres_client.start of a builder config shows the application_name",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )

        // Act
        let name = client_start_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it(
      "dream_postgres_client.start of a builder config with client_encoding after application_name shows the name",
      fn() {
        // Arrange
        let config =
          test_database.config()
          |> dream_postgres_client.connection_parameter(
            name: "application_name",
            value: "billing",
          )
          |> dream_postgres_client.connection_parameter(
            name: "client_encoding",
            value: "UTF8",
          )

        // Act
        let name = client_start_and_select(config, application_name_query)

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application name from the config")
      },
    ),
    it("an application_name sends no client_encoding", fn() {
      // Arrange
      let config = url_config("?application_name=billing")

      // Act
      let encoding = connect_and_select(config, client_encoding_query)

      // Assert
      encoding
      |> should
      |> be_equal(Ok(Ok(["UTF8 from default"])))
      |> or_fail_with("Expected the default client_encoding of the server")
    }),
    it("no application_name sends no client_encoding", fn() {
      // Act
      let encoding =
        connect_and_select(test_database.config(), client_encoding_query)

      // Assert
      encoding
      |> should
      |> be_equal(Ok(Ok(["UTF8 from default"])))
      |> or_fail_with("Expected the default client_encoding of the server")
    }),
    it("no application_name shows the Erlang node name", fn() {
      // Act
      let name =
        connect_and_select(test_database.config(), application_name_query)

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["nonode@nohost"])))
      |> or_fail_with(
        "Expected the Erlang node name, which dream_postgres_driver sends",
      )
    }),
    it(
      "non-ASCII text goes to the server and back with an application_name",
      fn() {
        // Arrange
        let config = url_config("?application_name=billing")

        // Act
        let answer = {
          use <- test_database.with_own_pools()
          config
          |> postgres.pool_size(1)
          |> postgres.connect()
          |> result.map(text_and_length(_, "héllo € 日本"))
        }

        // Assert
        answer
        |> should
        |> be_equal(Ok(Ok(["héllo € 日本 10"])))
        |> or_fail_with("Expected the same text and a length of 10 characters")
      },
    ),
  ])
}

@external(erlang, "database_ffi", "unique_integer")
fn unique_integer() -> Int

const three_settings_query =
  "SELECT current_setting('search_path') || '|' || current_setting('timezone') || '|' || current_setting('application_name')"

const search_path_query = "SELECT current_setting('search_path')"

fn url_parameter_tests() {
  group("server parameters from the URL", [
    it(
      "search_path, timezone and application_name from the URL reach the server",
      fn() {
        // Act
        let settings =
          from_url_and_select(
            "?search_path=app&timezone=UTC&application_name=billing",
            three_settings_query,
          )

        // Assert
        settings
        |> should
        |> be_equal(Ok(Ok(["app|UTC|billing"])))
        |> or_fail_with("Expected app|UTC|billing")
      },
    ),
    it("options from the URL reaches the server", fn() {
      // Act
      let timeout =
        from_url_and_select(
          "?options=-c%20statement_timeout%3D5s",
          "SELECT current_setting('statement_timeout')",
        )

      // Assert
      timeout
      |> should
      |> be_equal(Ok(Ok(["5s"])))
      |> or_fail_with("Expected a statement_timeout of 5s")
    }),
    it("the last of two search_path values reaches the server", fn() {
      // Act
      let path =
        from_url_and_select("?search_path=a&search_path=b", search_path_query)

      // Assert
      path
      |> should
      |> be_equal(Ok(Ok(["b"])))
      |> or_fail_with("Expected the last search_path")
    }),
    it("the last of two application_name values reaches the server", fn() {
      // Act
      let name =
        from_url_and_select(
          "?application_name=a&application_name=b",
          application_name_query,
        )

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["b"])))
      |> or_fail_with("Expected the last application name")
    }),
    it("Search_Path in mixed case reaches the server", fn() {
      // Act
      let path = from_url_and_select("?Search_Path=app", search_path_query)

      // Assert
      path
      |> should
      |> be_equal(Ok(Ok(["app"])))
      |> or_fail_with("Expected the search_path app")
    }),
    it("a percent-encoded search_path reaches the server decoded", fn() {
      // Act
      let path =
        from_url_and_select(
          "?search_path=%22my%20app%22%2Cpublic",
          search_path_query,
        )

      // Assert
      path
      |> should
      |> be_equal(Ok(Ok(["\"my app\",public"])))
      |> or_fail_with("Expected the decoded search_path")
    }),
    it("an empty search_path reaches the server", fn() {
      // Act
      let path = from_url_and_select("?search_path=", search_path_query)

      // Assert
      path
      |> should
      |> be_equal(Ok(Ok([""])))
      |> or_fail_with("Expected an empty search_path")
    }),
    it("an unknown parameter gives ConnectionUnavailable from check", fn() {
      // Act
      let checked = check_url(test_database.url() <> "?serach_path=app").result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("an unknown parameter gives the error after about 2 seconds", fn() {
      // Act
      let elapsed = check_url(test_database.url() <> "?serach_path=app").elapsed

      // Assert
      elapsed
      |> should
      |> be_between(1500, 4500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
    it("timezone=Mars/Phobos gives ConnectionUnavailable", fn() {
      // Act
      let checked =
        check_url(test_database.url() <> "?timezone=Mars%2FPhobos").result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("statement_timeout=abc gives ConnectionUnavailable", fn() {
      // Act
      let checked =
        check_url(test_database.url() <> "?statement_timeout=abc").result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("an empty timezone gives ConnectionUnavailable", fn() {
      // Act
      let checked = check_url(test_database.url() <> "?timezone=").result

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("no server parameter of the server is one edit from a keyword", fn() {
      // Arrange
      let names =
        from_url_and_select("", "SELECT name FROM pg_settings ORDER BY name")

      // Act
      let near_misses =
        result.map(names, result.map(_, list.filter_map(_, near_miss)))

      // Assert
      near_misses
      |> should
      |> be_equal(Ok(Ok([])))
      |> or_fail_with("Expected no UnknownParameterLooksLike error")
    }),
  ])
}

fn parameter_permission_tests() {
  group("server parameters from the URL and permissions", [
    it("a role without superuser connects with a search_path", fn() {
      // Act
      let path = {
        use url <- with_plain_role()
        use <- test_database.with_own_pools()
        postgres.from_url(url <> "?search_path=app")
        |> result.map(test_database.texts(_, search_path_query))
      }

      // Assert
      path
      |> should
      |> be_equal(Ok(Ok(["app"])))
      |> or_fail_with("Expected the search_path app")
    }),
    it("a role without superuser cannot set session_replication_role", fn() {
      // Act
      let checked = {
        use url <- with_plain_role()
        check_url(url <> "?session_replication_role=replica").result
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("a role without superuser cannot set the role of a superuser", fn() {
      // Act
      let checked = {
        use url <- with_plain_role()
        check_url(url <> "?role=" <> test_database.config().user).result
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it("a role without superuser cannot set session_authorization", fn() {
      // Act
      let checked = {
        use url <- with_plain_role()
        check_url(
          url <> "?session_authorization=" <> test_database.config().user,
        ).result
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
    }),
    it(
      "a role without superuser cannot set session_replication_role in options",
      fn() {
        // Act
        let checked = {
          use url <- with_plain_role()
          check_url(url <> "?options=-c%20session_replication_role%3Dreplica").result
        }

        // Assert
        checked
        |> should
        |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
        |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
      },
    ),
  ])
}

// A decoded null byte ends a string of the startup packet, so the text
// after it would be read as another parameter: `search_path=evil` below.
fn null_byte_tests() {
  group("a null byte never reaches the startup packet", [
    it("%00 in the user of the URL gives InvalidUserEncoding", fn() {
      // Arrange
      let config = test_database.config()
      let url =
        test_database.url_for(
          user: config.user <> "%00search_path%00evil",
          password: "dream",
          database: config.database,
        )

      // Act
      let path = from_full_url_and_select(url, search_path_query)

      // Assert
      path
      |> should
      |> be_equal(Error(postgres.InvalidUrl(postgres.InvalidUserEncoding)))
      |> or_fail_with("Expected InvalidUserEncoding, not search_path evil")
    }),
    it(
      "%00 in the database name of the URL gives InvalidDatabaseEncoding",
      fn() {
        // Arrange
        let config = test_database.config()
        let url =
          test_database.url_for(
            user: config.user,
            password: "dream",
            database: config.database <> "%00search_path%00evil",
          )

        // Act
        let path = from_full_url_and_select(url, search_path_query)

        // Assert
        path
        |> should
        |> be_equal(
          Error(postgres.InvalidUrl(postgres.InvalidDatabaseEncoding)),
        )
        |> or_fail_with(
          "Expected InvalidDatabaseEncoding, not search_path evil",
        )
      },
    ),
    it("%00 in the password of the URL gives InvalidPasswordEncoding", fn() {
      // Arrange
      let config = test_database.config()
      let url =
        test_database.url_for(
          user: config.user,
          password: "dream%00",
          database: config.database,
        )

      // Act
      let checked = check_url(url).result

      // Assert
      checked
      |> should
      |> be_equal(Error(postgres.InvalidUrl(postgres.InvalidPasswordEncoding)))
      |> or_fail_with("Expected InvalidPasswordEncoding")
    }),
    it("connect refuses a user with a null byte", fn() {
      // Arrange
      let config =
        test_database.config()
        |> postgres.user("dream\u{0}search_path\u{0}evil")

      // Act
      let path = connect_and_select(config, search_path_query)

      // Assert
      path
      |> should
      |> be_equal(
        Error(actor.InitFailed(
          "the user holds a null byte, which PostgreSQL cannot take",
        )),
      )
      |> or_fail_with("Expected InitFailed, not search_path evil")
    }),
    it("connect refuses a database name with a null byte", fn() {
      // Arrange
      let config =
        test_database.config()
        |> postgres.database("dream_test\u{0}search_path\u{0}evil")

      // Act
      let path = connect_and_select(config, search_path_query)

      // Assert
      path
      |> should
      |> be_equal(
        Error(actor.InitFailed(
          "the database name holds a null byte, which PostgreSQL cannot take",
        )),
      )
      |> or_fail_with("Expected InitFailed, not search_path evil")
    }),
    it("connect refuses a password with a null byte", fn() {
      // Arrange
      let config =
        test_database.config()
        |> postgres.password("dream\u{0}")

      // Act
      let checked = {
        use <- test_database.with_own_pools()
        config
        |> postgres.pool_size(1)
        |> postgres.connect()
        |> result.map(postgres.check)
      }

      // Assert
      checked
      |> should
      |> be_equal(
        Error(actor.InitFailed(
          "the password holds a null byte, which PostgreSQL cannot take",
        )),
      )
      |> or_fail_with("Expected InitFailed")
    }),
    it("connect refuses a connection parameter with a null byte", fn() {
      // Arrange
      let config =
        test_database.config()
        |> dream_postgres_client.connection_parameter(
          name: "application_name",
          value: "billing\u{0}search_path\u{0}evil",
        )

      // Act
      let path = connect_and_select(config, search_path_query)

      // Assert
      path
      |> should
      |> be_equal(
        Error(actor.InitFailed(
          "a connection parameter holds a null byte, which PostgreSQL cannot take",
        )),
      )
      |> or_fail_with("Expected InitFailed, not search_path evil")
    }),
  ])
}

fn protocol_option_tests() {
  group("protocol options and options", [
    it("a _pq_. name in the URL gives UnsupportedParameter", fn() {
      // Act
      let checked = check_url(test_database.url() <> "?_pq_.dream=1").result

      // Assert
      checked
      |> should
      |> be_equal(
        Error(postgres.InvalidUrl(postgres.UnsupportedParameter("_pq_.dream"))),
      )
      |> or_fail_with("Expected UnsupportedParameter(\"_pq_.dream\")")
    }),
    it("application_name in options alone loses to the Erlang node name", fn() {
      // Act
      let name =
        from_url_and_select(
          "?options=-c%20application_name%3Doptions_name",
          application_name_query,
        )

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["nonode@nohost"])))
      |> or_fail_with("Expected the Erlang node name")
    }),
    it(
      "application_name in the URL wins over application_name in options",
      fn() {
        // Act
        let name =
          from_url_and_select(
            "?options=-c%20application_name%3Doptions_name&application_name=billing",
            application_name_query,
          )

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application_name parameter")
      },
    ),
    it(
      "application_name in the URL wins over application_name in options that come after it",
      fn() {
        // Act
        let name =
          from_url_and_select(
            "?application_name=billing&options=-c%20application_name%3Doptions_name",
            application_name_query,
          )

        // Assert
        name
        |> should
        |> be_equal(Ok(Ok(["billing"])))
        |> or_fail_with("Expected the application_name parameter")
      },
    ),
  ])
}

// Starts a pool from `url`, runs `sql` (a query that returns one text
// column) and stops the pool.
fn from_full_url_and_select(
  url: String,
  sql: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  postgres.FromUrlError,
) {
  use <- test_database.with_own_pools()
  postgres.from_url(url)
  |> result.map(test_database.texts(_, sql))
}

// Starts a pool from the test server URL with the query string `query`,
// runs `sql` (a query that returns one text column) and stops the pool.
fn from_url_and_select(
  query: String,
  sql: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  postgres.FromUrlError,
) {
  use <- test_database.with_own_pools()
  postgres.from_url(test_database.url() <> query)
  |> result.map(test_database.texts(_, sql))
}

// Gives the name and the error when `parse_config` reads the server
// parameter `name` as a near miss of a client keyword.
fn near_miss(name: String) -> Result(#(String, postgres.UrlError), Nil) {
  case
    postgres.parse_config(
      process.new_name("near_miss_test"),
      test_database.url() <> "?" <> name <> "=1",
    )
  {
    Error(postgres.UnknownParameterLooksLike(..) as error) -> Ok(#(name, error))
    _ -> Error(Nil)
  }
}

// Makes a role that can log in and is not a superuser, gives `run` the URL
// of the test database for that role, and drops the role after `run`
// returns.
fn with_plain_role(run: fn(String) -> a) -> a {
  use <- test_database.with_own_pools()
  let config = test_database.config()
  let role = "plain_role_" <> int.to_string(unique_integer())
  let assert Ok(admin) =
    config
    |> postgres.pool_size(1)
    |> postgres.connect()
  let assert Ok(_created) =
    test_database.execute(
      admin,
      "CREATE ROLE " <> role <> " LOGIN PASSWORD 'plain'",
    )
  let value =
    run(test_database.url_for(
      user: role,
      password: "plain",
      database: config.database,
    ))
  let assert Ok(_dropped) = test_database.execute(admin, "DROP ROLE " <> role)
  value
}

// Starts a pool of 1 connection from `config` with `connect`, runs `sql`
// (a query that returns one text column) and stops the pool.
fn connect_and_select(
  config: postgres.Config,
  sql: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  actor.StartError,
) {
  use <- test_database.with_own_pools()
  config
  |> postgres.pool_size(1)
  |> postgres.connect()
  |> result.map(test_database.texts(_, sql))
}

// Starts a pool of 1 connection from `config` with
// `dream_postgres_client.start`, which does not go through `connect`, runs
// `sql` and stops the pool.
fn client_start_and_select(
  config: postgres.Config,
  sql: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  actor.StartError,
) {
  use <- test_database.with_own_pools()
  config
  |> postgres.pool_size(1)
  |> dream_postgres_client.start()
  |> result.map(fn(started) { test_database.texts(started.data, sql) })
}

// Returns the config of `parse_config` for the test server URL with the
// query string `query`, for example `?application_name=billing`.
fn url_config(query: String) -> postgres.Config {
  let assert Ok(config) =
    postgres.parse_config(
      process.new_name("application_name_test"),
      test_database.url() <> query,
    )
  config
}

// Sends `text` as a query parameter, and gives back the text that the
// server returns and its length in characters, as the server counts them.
fn text_and_length(
  db: dream_postgres_client.Connection,
  text: String,
) -> Result(List(String), dream_postgres_client.QueryError) {
  dream_postgres_client.query(
    "SELECT $1::text || ' ' || length($1::text)::text",
  )
  |> dream_postgres_client.parameter(dream_postgres_client.text(text))
  |> dream_postgres_client.returning(decode.at([0], decode.string))
  |> dream_postgres_client.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn start_and_describe(url: String) -> Result(Nil, String) {
  use <- test_database.with_own_pools()
  start(url)
  |> result.replace(Nil)
  |> result.map_error(describe_error)
}

type TimedCheck(start_error) {
  TimedCheck(
    result: Result(Result(Nil, dream_postgres_client.QueryError), start_error),
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
  SlowAnswer(
    backend: Result(List(Int), dream_postgres_client.QueryError),
    elapsed: Int,
  )
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
      dream_postgres_client.query(
        "SELECT pg_backend_pid(), pg_sleep(0.5)::text",
      )
      |> dream_postgres_client.returning(decode.at([0], decode.int))
      |> dream_postgres_client.execute(db)
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
