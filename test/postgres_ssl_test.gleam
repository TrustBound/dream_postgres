//// Tests for what the guides say about the SSL modes, against a real
//// PostgreSQL 16 server with SSL on (`fixtures/ssl_database`).
////
//// Some tests change the CA list of the whole BEAM with
//// `public_key:cacerts_load`, so this suite runs one test at a time.

import dream_postgres/client as postgres
import dream_test/matchers.{be_between, be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/clock
import fixtures/ssl_database.{matching_host, other_address, url}
import fixtures/test_database
import gleam/list
import gleam/result
import gleam/string
import pog
import snippets/guide_connecting_private_ca.{connect_with_private_ca}

const ssl_sql = "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

pub fn tests() -> TestSuite {
  describe("a real PostgreSQL 16 server with SSL on", [
    disable_tests(),
    require_tests(),
    untrusted_ca_tests(),
    trusted_ca_tests(),
  ])
}

fn disable_tests() {
  group("sslmode=disable", [
    it("connects without TLS", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "disable"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["false"])))
      |> or_fail_with("Expected a connection without TLS")
    }),
  ])
}

fn require_tests() {
  group("sslmode=require", [
    it("connects with TLS", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "require"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a connection with TLS")
    }),
    it("check gives Ok(Nil)", fn() {
      // Act
      let checked = {
        use <- test_database.with_own_pools()
        postgres.from_url(url(host: matching_host, sslmode: "require"))
        |> result.map(postgres.check)
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Ok(Nil)))
      |> or_fail_with("Expected Ok(Nil) from check over TLS")
    }),
    it("connects with TLS 1.3", fn() {
      // Act
      let version =
        ssl_database.query_texts(
          url(host: matching_host, sslmode: "require"),
          "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
        )

      // Assert
      version
      |> should
      |> be_equal(Ok(Ok(["TLSv1.3"])))
      |> or_fail_with("Expected TLSv1.3")
    }),
    it("application_name from the URL reaches the server over TLS", fn() {
      // Act
      let name =
        ssl_database.query_texts(
          url(host: matching_host, sslmode: "require")
            <> "&application_name=billing",
          "SELECT current_setting('application_name')",
        )

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["billing"])))
      |> or_fail_with("Expected the application name from the URL")
    }),
    it(
      "connects to an address the certificate does not name, from an unknown CA",
      fn() {
        // Act
        let ssl =
          ssl_database.ssl_in_use(url(host: other_address, sslmode: "require"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Ok(["true"])))
        |> or_fail_with("Expected a connection with TLS and no check")
      },
    ),
  ])
}

fn untrusted_ca_tests() {
  group("the verify modes when the client does not trust the CA", [
    it("verify-full gives ConnectionUnavailable", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-full"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
    it("verify-ca gives ConnectionUnavailable", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-ca"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
    it("verify-full logs the reason as a notice", fn() {
      // Act
      let alerts =
        ssl_database.tls_alerts(fn() {
          ssl_database.ssl_in_use(url(
            host: matching_host,
            sslmode: "verify-full",
          ))
        })

      // Assert
      list.first(alerts)
      |> result.map(level_and_alert)
      |> should
      |> be_equal(Ok(#("notice", "Fatal - Unknown CA")))
      |> or_fail_with("Expected an Unknown CA notice")
    }),
    it("verify-full gives the error after about 2 seconds", fn() {
      // Arrange
      let started_at = clock.now_in_milliseconds()

      // Act
      let _ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-full"))
      let elapsed = clock.now_in_milliseconds() - started_at

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
  ])
}

fn trusted_ca_tests() {
  group("the verify modes when the client trusts the CA", [
    it("verify-full connects with TLS to the name of the certificate", fn() {
      // Act
      let ssl =
        ssl_with_test_ca(url(host: matching_host, sslmode: "verify-full"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a verified connection with TLS")
    }),
    it(
      "verify-full gives ConnectionUnavailable for an address the certificate does not name",
      fn() {
        // Act
        let ssl =
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-full"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
    it("verify-full logs a host name that does not match as a notice", fn() {
      // Act
      let alerts =
        ssl_database.tls_alerts(fn() {
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-full"))
        })

      // Assert
      list.first(alerts)
      |> result.map(level_and_alert)
      |> should
      |> be_equal(
        Ok(#(
          "notice",
          "Fatal - Bad Certificate, - {bad_cert,{hostname_check_failed,{requested,\"127.0.0.1\"},{received,[{dNSName,\"localhost\"}]}}}",
        )),
      )
      |> or_fail_with("Expected a Bad Certificate notice")
    }),
    it(
      "verify-ca gives ConnectionUnavailable for an address the certificate does not name",
      fn() {
        // Act
        let ssl =
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-ca"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable, as for verify-full")
      },
    ),
    it("verify-ca connects with TLS to the name of the certificate", fn() {
      // Act
      let ssl = ssl_with_test_ca(url(host: matching_host, sslmode: "verify-ca"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a verified connection with TLS")
    }),
    it("the pool keeps the CA list it read when it started", fn() {
      // Act
      let ssl = {
        use <- test_database.with_own_pools()
        let connected = {
          use <- ssl_database.with_os_ca_list_restored()
          connect_with_private_ca(
            url(host: matching_host, sslmode: "verify-full"),
            ssl_database.ca_file,
          )
        }
        // The system's CA list is back, and the pool still trusts the test CA
        result.map(connected, test_database.texts(_, ssl_sql))
      }

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a verified connection with TLS")
    }),
    it("loading the CA file replaces the CA list of the system", fn() {
      // Act
      let count = {
        use <- ssl_database.with_os_ca_list_restored()
        use <- test_database.with_own_pools()
        let _connected =
          connect_with_private_ca(
            url(host: matching_host, sslmode: "verify-full"),
            ssl_database.ca_file,
          )
        ssl_database.ca_count()
      }

      // Assert
      count
      |> should
      |> be_equal(1)
      |> or_fail_with("Expected only the test CA in the list")
    }),
    it("gives an error for a CA file that does not exist", fn() {
      // Act
      let connected = {
        use <- ssl_database.with_os_ca_list_restored()
        use <- test_database.with_own_pools()
        connect_with_private_ca(
          url(host: matching_host, sslmode: "verify-full"),
          "test/fixtures/ssl/missing.crt",
        )
        |> result.replace(Nil)
      }

      // Assert
      connected
      |> should
      |> be_equal(Error(
        "Can't read the CA certificates in test/fixtures/ssl/missing.crt",
      ))
      |> or_fail_with("Expected the CA file error")
    }),
  ])
}

// Trusts the test CA with the snippet of the connecting guide, starts a
// pool from `url` and asks the server whether the connection uses TLS.
// Then it stops the pool and trusts the system's CA list again.
fn ssl_with_test_ca(
  url: String,
) -> Result(Result(List(String), pog.QueryError), String) {
  use <- ssl_database.with_os_ca_list_restored()
  use <- test_database.with_own_pools()
  connect_with_private_ca(url, ssl_database.ca_file)
  |> result.map(test_database.texts(_, ssl_sql))
}

// Keeps the level of a TLS alert report and the text after
// "CLIENT ALERT: ". The text before it names a line of OTP's source, which
// changes from one OTP release to the next.
fn level_and_alert(alert: #(String, String)) -> #(String, String) {
  let #(level, text) = alert
  case string.split_once(text, "CLIENT ALERT: ") {
    Ok(#(_before, reason)) -> #(level, reason)
    Error(Nil) -> #(level, text)
  }
}
