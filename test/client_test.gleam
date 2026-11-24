//// Tests for `dream_postgres/client`.
////
//// The builder functions and `parse_config` are pure, so these tests check
//// exact `Config` values and need no database. The `connect` and `from_url`
//// tests run a query on the test PostgreSQL server, or start a pool on a
//// local port that has no listener.

import dream_pog as pog
import dream_postgres/client as postgres
import dream_test/matchers.{
  be_equal, be_false, be_less_than, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/clock
import fixtures/database
import fixtures/database_url
import fixtures/test_database
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

pub fn tests() -> TestSuite {
  describe("dream_postgres/client", [
    builder_tests(),
    connect_tests(),
    parse_config_value_tests(),
    parse_config_error_tests(),
    query_parameter_tests(),
    ssl_root_certificate_tests(),
    from_url_tests(),
  ])
}

fn builder_tests() {
  group("builders", [
    it("new returns the default Pog config for the pool name", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config = postgres.new(pool_name)

      // Assert
      config
      |> should
      |> be_equal(pog.default_config(pool_name: pool_name))
      |> or_fail_with("Expected the default Pog config")
    }),
    it("host sets the host", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.host(config, "db.example.com")

      // Assert
      updated.host
      |> should
      |> be_equal("db.example.com")
      |> or_fail_with("Expected the host to be 'db.example.com'")
    }),
    it("port sets the port", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.port(config, 6543)

      // Assert
      updated.port
      |> should
      |> be_equal(6543)
      |> or_fail_with("Expected the port to be 6543")
    }),
    it("database sets the database name", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.database(config, "myapp")

      // Assert
      updated.database
      |> should
      |> be_equal("myapp")
      |> or_fail_with("Expected the database name to be 'myapp'")
    }),
    it("user sets the user", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.user(config, "app_user")

      // Assert
      updated.user
      |> should
      |> be_equal("app_user")
      |> or_fail_with("Expected the user to be 'app_user'")
    }),
    it("password sets the password", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.password(config, "secret")

      // Assert
      updated.password
      |> should
      |> be_equal(Some("secret"))
      |> or_fail_with("Expected the password to be Some('secret')")
    }),
    it("pool_size sets the pool size", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config = postgres.new(pool_name)

      // Act
      let updated = postgres.pool_size(config, 20)

      // Assert
      updated.pool_size
      |> should
      |> be_equal(20)
      |> or_fail_with("Expected the pool size to be 20")
    }),
  ])
}

fn connect_tests() {
  group("connect", [
    it("connect gives a pool that runs a query on the server", fn() {
      // Act
      let answer = {
        use <- test_database.with_own_pools()
        test_database.config()
        |> postgres.pool_size(1)
        |> postgres.connect()
        |> result.map(test_database.texts(_, "SELECT 'connected'"))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Ok(["connected"])))
      |> or_fail_with("Expected the row of the query")
    }),
    it("connect returns a connection to the named pool", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let config =
        postgres.new(pool_name)
        |> postgres.host("127.0.0.1")
        |> postgres.port(database_url.unused_port())
        |> postgres.database("myapp")

      // Act
      let result = postgres.connect(config)

      // Assert
      result
      |> should
      |> be_equal(Ok(pog.named_connection(pool_name)))
      |> or_fail_with("Expected a connection to the named pool")
    }),
  ])
}

fn parse_config_value_tests() {
  group("parse_config values", [
    it("reads every value of the README URL", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.port(5432)
        |> postgres.database("myapp")
        |> postgres.user("user")
        |> postgres.password("pass")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://user:pass@localhost:5432/myapp",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected every value of the URL")
    }),
    it("decodes an encoded user, password and database", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("db.example.com")
        |> postgres.port(6543)
        |> postgres.database("my db")
        |> postgres.user("app user")
        |> postgres.password("p@ss:w/rd")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgres://app%20user:p%40ss%3Aw%2Frd@db.example.com:6543/my%20db",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected the decoded values")
    }),
    it("keeps a colon after the first one in the password", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> postgres.user("user")
        |> postgres.password("pa:ss")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://user:pa:ss@localhost/myapp",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected the password pa:ss")
    }),
    it("uses port 5432 when the URL has no port", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.port(5432)
        |> postgres.database("myapp")
        |> postgres.user("user")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://user@localhost/myapp")

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected port 5432 and no password")
    }),
    it("keeps the default user when the URL has no user", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost/myapp")

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected the default user")
    }),
    it("maps sslmode and application_name", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        pog.Config(
          ..postgres.new(pool_name)
          |> postgres.host("localhost")
          |> postgres.database("myapp")
          |> postgres.user("user")
          |> postgres.password("pass")
          |> pog.ssl(pog.SslVerified),
          connection_parameters: [#("application_name", "my app")],
        )

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://user:pass@localhost:5432/myapp?sslmode=verify-full&application_name=my%20app",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected SSL and the application name")
    }),
    it("maps sslmode=disable to SslDisabled", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> pog.ssl(pog.SslDisabled)

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=disable",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected SslDisabled")
    }),
    it("maps sslmode=require to SslUnverified", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> pog.ssl(pog.SslUnverified)

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=require",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected SslUnverified")
    }),
    it("maps sslmode=verify-ca to SslVerifiedChainOnly", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> pog.ssl(pog.SslVerifiedChainOnly)

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=verify-ca",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected SslVerifiedChainOnly")
    }),
    it("maps sslmode=verify-full to SslVerified", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("localhost")
        |> postgres.database("myapp")
        |> pog.ssl(pog.SslVerified)

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=verify-full",
        )

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected SslVerified")
    }),
    it("sets IPv6 for an IPv6 host", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")
      let expected =
        postgres.new(pool_name)
        |> postgres.host("::1")
        |> postgres.port(5433)
        |> postgres.database("myapp")
        |> pog.ip_version(pog.Ipv6)

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://[::1]:5433/myapp")

      // Assert
      config
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected the IPv6 host ::1")
    }),
  ])
}

fn parse_config_error_tests() {
  group("parse_config errors", [
    it("returns MalformedUrl for a port that is not a number", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://user:secret@localhost:abc/myapp",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MalformedUrl))
      |> or_fail_with("Expected Error(MalformedUrl)")
    }),
    it("returns MissingScheme for a URL with no scheme", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config = postgres.parse_config(pool_name, "localhost/myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MissingScheme))
      |> or_fail_with("Expected Error(MissingScheme)")
    }),
    it("returns UnsupportedScheme for another scheme", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "mysql://user:secret@localhost/myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.UnsupportedScheme("mysql")))
      |> or_fail_with("Expected Error(UnsupportedScheme('mysql'))")
    }),
    it("returns MissingHost for a URL with no host", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config = postgres.parse_config(pool_name, "postgresql:///myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MissingHost))
      |> or_fail_with("Expected Error(MissingHost)")
    }),
    it("returns InvalidPort for port 0", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost:0/myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidPort(0)))
      |> or_fail_with("Expected Error(InvalidPort(0))")
    }),
    it("returns InvalidPort for a port above 65535", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost:65536/myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidPort(65_536)))
      |> or_fail_with("Expected Error(InvalidPort(65_536))")
    }),
    it("returns MissingDatabase for a URL with no path", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost:5432")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MissingDatabase))
      |> or_fail_with("Expected Error(MissingDatabase)")
    }),
    it("returns MissingDatabase for an empty database name", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost:5432/")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MissingDatabase))
      |> or_fail_with("Expected Error(MissingDatabase)")
    }),
    it("returns InvalidDatabase for a nested path", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost/my/app")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidDatabase("/my/app")))
      |> or_fail_with("Expected Error(InvalidDatabase('/my/app'))")
    }),
    it("returns MissingUser for a password with no user", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://:secret@localhost/myapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MissingUser))
      |> or_fail_with("Expected Error(MissingUser)")
    }),
    it("returns InvalidUserEncoding for a bad user encoding", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://us%zzer:secret@localhost/myapp",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidUserEncoding))
      |> or_fail_with("Expected Error(InvalidUserEncoding)")
    }),
    it("returns InvalidPasswordEncoding for a bad password encoding", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://user:sec%zzret@localhost/myapp",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidPasswordEncoding))
      |> or_fail_with("Expected Error(InvalidPasswordEncoding)")
    }),
    it("returns InvalidDatabaseEncoding for a bad database encoding", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost/my%zzapp")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.InvalidDatabaseEncoding))
      |> or_fail_with("Expected Error(InvalidDatabaseEncoding)")
    }),
    it(
      "returns the encoding error of the part for %00 in the user, the password or the database",
      fn() {
        // Act
        let results = [
          postgres.parse_config(
            process.new_name("client_test_pool"),
            "postgresql://us%00er:secret@localhost/myapp",
          )
            |> result.replace(Nil),
          postgres.parse_config(
            process.new_name("client_test_pool"),
            "postgresql://user:sec%00ret@localhost/myapp",
          )
            |> result.replace(Nil),
          postgres.parse_config(
            process.new_name("client_test_pool"),
            "postgresql://localhost/my%00app",
          )
            |> result.replace(Nil),
        ]

        // Assert
        results
        |> should
        |> be_equal([
          Error(postgres.InvalidUserEncoding),
          Error(postgres.InvalidPasswordEncoding),
          Error(postgres.InvalidDatabaseEncoding),
        ])
        |> or_fail_with("Expected the encoding error of each part")
      },
    ),
    it("returns UnsupportedParameter with the parameter name", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=require&connect_timeout=10",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.UnsupportedParameter("connect_timeout")))
      |> or_fail_with("Expected Error(UnsupportedParameter('connect_timeout'))")
    }),
    it("returns UnsupportedSslMode with the mode", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=prefer",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.UnsupportedSslMode("prefer")))
      |> or_fail_with("Expected Error(UnsupportedSslMode('prefer'))")
    }),
    it("returns UnsupportedFragment for a URL with a fragment", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(pool_name, "postgresql://localhost/myapp#main")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.UnsupportedFragment))
      |> or_fail_with("Expected Error(UnsupportedFragment)")
    }),
    it("returns MalformedUrl for a query string it cannot read", fn() {
      // Arrange
      let pool_name = process.new_name("client_test_pool")

      // Act
      let config =
        postgres.parse_config(
          pool_name,
          "postgresql://localhost/myapp?sslmode=%zz",
        )

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.MalformedUrl))
      |> or_fail_with("Expected Error(MalformedUrl)")
    }),
  ])
}

// The libpq connection keywords that `parse_config` refuses, and
// `database`, the startup field that the path of the URL sets.
const refused_names = [
  "host", "hostaddr", "port", "dbname", "user", "password", "passfile",
  "require_auth", "channel_binding", "connect_timeout", "client_encoding",
  "fallback_application_name", "keepalives", "keepalives_idle",
  "keepalives_interval", "keepalives_count", "tcp_user_timeout", "replication",
  "gssencmode", "requiressl", "sslnegotiation", "sslcompression", "sslcert",
  "sslkey", "sslkeylogfile", "sslpassword", "sslcertmode", "sslcrl", "sslcrldir",
  "sslsni", "requirepeer", "ssl_min_protocol_version",
  "ssl_max_protocol_version", "min_protocol_version", "max_protocol_version",
  "krbsrvname", "gsslib", "gssdelegation", "scram_client_key",
  "scram_server_key", "service", "target_session_attrs", "load_balance_hosts",
  "oauth_issuer", "oauth_client_id", "oauth_client_secret", "oauth_scope",
  "database",
]

// Returns the connection parameters of the config for the query string
// `query`, for example `?search_path=app`.
fn parameters_of(
  query: String,
) -> Result(List(#(String, String)), postgres.UrlError) {
  postgres.parse_config(
    process.new_name("client_test_pool"),
    "postgresql://localhost/myapp" <> query,
  )
  |> result.map(fn(config) { config.connection_parameters })
}

// Returns the result of `parse_config` for the query string `query`.
fn parse_query(query: String) -> Result(postgres.Config, postgres.UrlError) {
  postgres.parse_config(
    process.new_name("client_test_pool"),
    "postgresql://localhost/myapp" <> query,
  )
}

fn query_parameter_tests() {
  group("parse_config query parameters", [
    it("passes server parameters and application_name in URL order", fn() {
      // Act
      let parameters =
        parameters_of("?search_path=app&timezone=UTC&application_name=billing")

      // Assert
      parameters
      |> should
      |> be_equal(
        Ok([
          #("search_path", "app"),
          #("timezone", "UTC"),
          #("application_name", "billing"),
        ]),
      )
      |> or_fail_with("Expected the server parameters in URL order")
    }),
    it("passes options to the server", fn() {
      // Act
      let parameters = parameters_of("?options=-c%20statement_timeout%3D5s")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("options", "-c statement_timeout=5s")]))
      |> or_fail_with("Expected the options parameter")
    }),
    it(
      "returns UnsupportedParameter for each client keyword it does not read",
      fn() {
        // Act
        let results =
          list.map(refused_names, fn(name) {
            parse_query("?" <> name <> "=1")
            |> result.replace(Nil)
          })

        // Assert
        results
        |> should
        |> be_equal(
          list.map(refused_names, fn(name) {
            Error(postgres.UnsupportedParameter(name))
          }),
        )
        |> or_fail_with("Expected UnsupportedParameter for each client keyword")
      },
    ),
    it("returns UnsupportedParameter for an empty name", fn() {
      // Act
      let result = parse_query("?=app")

      // Assert
      result
      |> should
      |> be_equal(Error(postgres.UnsupportedParameter("")))
      |> or_fail_with("Expected Error(UnsupportedParameter(''))")
    }),
    it("returns UnknownParameterLooksLike for sslmod", fn() {
      // Act
      let result = parse_query("?sslmod=require")

      // Assert
      result
      |> should
      |> be_equal(
        Error(postgres.UnknownParameterLooksLike("sslmod", "sslmode")),
      )
      |> or_fail_with("Expected UnknownParameterLooksLike('sslmod', 'sslmode')")
    }),
    it(
      "returns UnknownParameterLooksLike for each name one edit from a keyword",
      fn() {
        // Arrange
        let names = [
          "ssl_mode", "sslmdoe", "sslmodes", "SSLMODE", "sslMode",
          "applicaton_name", "Application_Name", "optons", "Options",
          "conect_timeout", "pasword", "databse", "User", "Port",
        ]

        // Act
        let results =
          list.map(names, fn(name) {
            parse_query("?" <> name <> "=1")
            |> result.replace(Nil)
          })

        // Assert
        results
        |> should
        |> be_equal([
          Error(postgres.UnknownParameterLooksLike("ssl_mode", "sslmode")),
          Error(postgres.UnknownParameterLooksLike("sslmdoe", "sslmode")),
          Error(postgres.UnknownParameterLooksLike("sslmodes", "sslmode")),
          Error(postgres.UnknownParameterLooksLike("SSLMODE", "sslmode")),
          Error(postgres.UnknownParameterLooksLike("sslMode", "sslmode")),
          Error(postgres.UnknownParameterLooksLike(
            "applicaton_name",
            "application_name",
          )),
          Error(postgres.UnknownParameterLooksLike(
            "Application_Name",
            "application_name",
          )),
          Error(postgres.UnknownParameterLooksLike("optons", "options")),
          Error(postgres.UnknownParameterLooksLike("Options", "options")),
          Error(postgres.UnknownParameterLooksLike(
            "conect_timeout",
            "connect_timeout",
          )),
          Error(postgres.UnknownParameterLooksLike("pasword", "password")),
          Error(postgres.UnknownParameterLooksLike("databse", "database")),
          Error(postgres.UnknownParameterLooksLike("User", "user")),
          Error(postgres.UnknownParameterLooksLike("Port", "port")),
        ])
        |> or_fail_with("Expected UnknownParameterLooksLike for each name")
      },
    ),
    it("passes a name two edits from every keyword to the server", fn() {
      // Act
      let parameters = parameters_of("?sslmox=require&serach_path=app")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("sslmox", "require"), #("serach_path", "app")]))
      |> or_fail_with("Expected both names in the connection parameters")
    }),
    it("keeps both values of a duplicate name, in URL order", fn() {
      // Act
      let parameters = parameters_of("?search_path=a&search_path=b")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("search_path", "a"), #("search_path", "b")]))
      |> or_fail_with("Expected both values in URL order")
    }),
    it("keeps both application_name values of the URL in order", fn() {
      // Act
      let parameters = parameters_of("?application_name=a&application_name=b")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("application_name", "a"), #("application_name", "b")]))
      |> or_fail_with("Expected both application names in URL order")
    }),
    it("uses the last sslmode of the URL", fn() {
      // Act
      let ssl =
        parse_query("?sslmode=disable&sslmode=require")
        |> result.map(fn(config) { config.ssl })

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslUnverified))
      |> or_fail_with("Expected Ok(SslUnverified)")
    }),
    it("passes a server parameter name with upper-case letters unchanged", fn() {
      // Act
      let parameters = parameters_of("?Search_Path=app&TimeZone=UTC")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("Search_Path", "app"), #("TimeZone", "UTC")]))
      |> or_fail_with("Expected the names as the URL gives them")
    }),
    it("percent-decodes the name and the value", fn() {
      // Act
      let parameters = parameters_of("?search%5Fpath=%22my%20app%22%2Cpublic")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("search_path", "\"my app\",public")]))
      |> or_fail_with("Expected the decoded name and value")
    }),
    it("passes an empty value", fn() {
      // Act
      let parameters = parameters_of("?search_path=")

      // Assert
      parameters
      |> should
      |> be_equal(Ok([#("search_path", "")]))
      |> or_fail_with("Expected an empty value")
    }),
    it("returns MalformedUrl for %00 in a name or a value", fn() {
      // Act
      let results = [
        parse_query("?application_name=a%00search_path%00b")
          |> result.replace(Nil),
        parse_query("?search%00path=app") |> result.replace(Nil),
      ]

      // Assert
      results
      |> should
      |> be_equal([Error(postgres.MalformedUrl), Error(postgres.MalformedUrl)])
      |> or_fail_with("Expected MalformedUrl for each %00")
    }),
    it("returns UnsupportedParameter for a _pq_. protocol option", fn() {
      // Act
      let config = parse_query("?_pq_.dream=1")

      // Assert
      config
      |> should
      |> be_equal(Error(postgres.UnsupportedParameter("_pq_.dream")))
      |> or_fail_with("Expected Error(UnsupportedParameter('_pq_.dream'))")
    }),
  ])
}

// Returns the SSL mode that `parse_config` gives for the query string
// `query`.
fn ssl_of(query: String) -> Result(pog.Ssl, postgres.UrlError) {
  parse_query(query)
  |> result.map(fn(config) { config.ssl })
}

fn ssl_root_certificate_tests() {
  group("parse_config sslrootcert", [
    it(
      "gives SslDisabled for sslmode=disable with a CA file, which it does not use",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=disable&sslrootcert=ca.pem")

        // Assert
        ssl
        |> should
        |> be_equal(Ok(pog.SslDisabled))
        |> or_fail_with("Expected Ok(pog.SslDisabled)")
      },
    ),
    it(
      "gives SslVerifiedChainOnlyCaFile for sslmode=require with a CA file",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=require&sslrootcert=ca.pem")

        // Assert
        ssl
        |> should
        |> be_equal(Ok(pog.SslVerifiedChainOnlyCaFile("ca.pem")))
        |> or_fail_with("Expected Ok(pog.SslVerifiedChainOnlyCaFile(ca.pem))")
      },
    ),
    it(
      "gives SslVerifiedChainOnlyCaFile for sslmode=verify-ca with a CA file",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=verify-ca&sslrootcert=ca.pem")

        // Assert
        ssl
        |> should
        |> be_equal(Ok(pog.SslVerifiedChainOnlyCaFile("ca.pem")))
        |> or_fail_with("Expected Ok(pog.SslVerifiedChainOnlyCaFile(ca.pem))")
      },
    ),
    it("gives SslVerifiedCaFile for sslmode=verify-full with a CA file", fn() {
      // Act
      let ssl = ssl_of("?sslmode=verify-full&sslrootcert=ca.pem")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerifiedCaFile("ca.pem")))
      |> or_fail_with("Expected Ok(pog.SslVerifiedCaFile(ca.pem))")
    }),
    it("gives SslVerifiedCaFile when sslrootcert comes before sslmode", fn() {
      // Act
      let ssl = ssl_of("?sslrootcert=ca.pem&sslmode=verify-full")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerifiedCaFile("ca.pem")))
      |> or_fail_with("Expected Ok(pog.SslVerifiedCaFile(ca.pem))")
    }),
    it("percent-decodes the path of the CA file", fn() {
      // Act
      let ssl = ssl_of("?sslmode=verify-full&sslrootcert=%2Fetc%2Fmy%20ca.pem")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerifiedCaFile("/etc/my ca.pem")))
      |> or_fail_with("Expected Ok(pog.SslVerifiedCaFile(/etc/my ca.pem))")
    }),
    it("uses the last sslrootcert of the URL", fn() {
      // Act
      let ssl =
        ssl_of("?sslmode=verify-full&sslrootcert=a.pem&sslrootcert=b.pem")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerifiedCaFile("b.pem")))
      |> or_fail_with("Expected Ok(pog.SslVerifiedCaFile(b.pem))")
    }),
    it(
      "gives SslVerified for sslrootcert=system with sslmode=verify-full",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=verify-full&sslrootcert=system")

        // Assert
        ssl
        |> should
        |> be_equal(Ok(pog.SslVerified))
        |> or_fail_with("Expected Ok(pog.SslVerified)")
      },
    ),
    it("gives SslVerified for sslrootcert=system without sslmode", fn() {
      // Act
      let ssl = ssl_of("?sslrootcert=system")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerified))
      |> or_fail_with("Expected Ok(pog.SslVerified)")
    }),
    it(
      "returns SslRootCertSystemNeedsVerifyFull for sslrootcert=system with verify-ca",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=verify-ca&sslrootcert=system")

        // Assert
        ssl
        |> should
        |> be_equal(
          Error(postgres.SslRootCertSystemNeedsVerifyFull("verify-ca")),
        )
        |> or_fail_with(
          "Expected Error(postgres.SslRootCertSystemNeedsVerifyFull(verify-ca))",
        )
      },
    ),
    it(
      "returns SslRootCertSystemNeedsVerifyFull for sslrootcert=system with disable",
      fn() {
        // Act
        let ssl = ssl_of("?sslmode=disable&sslrootcert=system")

        // Assert
        ssl
        |> should
        |> be_equal(Error(postgres.SslRootCertSystemNeedsVerifyFull("disable")))
        |> or_fail_with(
          "Expected Error(postgres.SslRootCertSystemNeedsVerifyFull(disable))",
        )
      },
    ),
    it("returns SslRootCertWithoutSslMode for a CA file without sslmode", fn() {
      // Act
      let ssl = ssl_of("?sslrootcert=ca.pem")

      // Assert
      ssl
      |> should
      |> be_equal(Error(postgres.SslRootCertWithoutSslMode))
      |> or_fail_with("Expected Error(postgres.SslRootCertWithoutSslMode)")
    }),
    it("returns UnknownParameterLooksLike for sslrootcrt", fn() {
      // Act
      let ssl = ssl_of("?sslmode=verify-full&sslrootcrt=ca.pem")

      // Assert
      ssl
      |> should
      |> be_equal(
        Error(postgres.UnknownParameterLooksLike("sslrootcrt", "sslrootcert")),
      )
      |> or_fail_with(
        "Expected Error(postgres.UnknownParameterLooksLike(sslrootcrt, sslrootcert))",
      )
    }),
    it("keeps the SSL mode of the config when the URL has neither", fn() {
      // Act
      let ssl = ssl_of("?search_path=app")

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslDisabled))
      |> or_fail_with("Expected Ok(pog.SslDisabled)")
    }),
  ])
}

fn from_url_tests() {
  group("from_url", [
    it("from_url gives a pool that runs a query on the server", fn() {
      // Act
      let answer = {
        use <- test_database.with_own_pools()
        postgres.from_url(test_database.url())
        |> result.map(test_database.texts(_, "SELECT 'connected'"))
      }

      // Assert
      answer
      |> should
      |> be_equal(Ok(Ok(["connected"])))
      |> or_fail_with("Expected the row of the query")
    }),
    it("returns InvalidUrl for a URL that is not valid", fn() {
      // Act
      let result = postgres.from_url("mysql://user:secret@localhost/myapp")

      // Assert
      result
      |> should
      |> be_equal(
        Error(postgres.InvalidUrl(postgres.UnsupportedScheme("mysql"))),
      )
      |> or_fail_with("Expected InvalidUrl(UnsupportedScheme('mysql'))")
    }),
    it("returns the URL error for each URL that is not valid", fn() {
      // Arrange
      let urls = [
        "postgresql://user:hunter2@localhost:abc/myapp",
        "mysql://user:hunter2@localhost/myapp",
        "postgresql://user:hunter2@localhost:0/myapp",
        "postgresql://user:hunter2@localhost/",
        "postgresql://user:hunter2@localhost/a/b",
        "postgresql://user:hunter2%zz@localhost/myapp",
        "postgresql://user:hunter2@localhost/myapp?password=hunter2",
        "postgresql://user:hunter2@localhost/myapp?sslmode=prefer",
        "postgresql://user:hunter2@localhost/myapp?sslmod=hunter2",
        "postgresql://user:hunter2@localhost/myapp#hunter2",
      ]

      // Act
      let results = list.map(urls, postgres.from_url)

      // Assert
      results
      |> should
      |> be_equal([
        Error(postgres.InvalidUrl(postgres.MalformedUrl)),
        Error(postgres.InvalidUrl(postgres.UnsupportedScheme("mysql"))),
        Error(postgres.InvalidUrl(postgres.InvalidPort(0))),
        Error(postgres.InvalidUrl(postgres.MissingDatabase)),
        Error(postgres.InvalidUrl(postgres.InvalidDatabase("/a/b"))),
        Error(postgres.InvalidUrl(postgres.InvalidPasswordEncoding)),
        Error(postgres.InvalidUrl(postgres.UnsupportedParameter("password"))),
        Error(postgres.InvalidUrl(postgres.UnsupportedSslMode("prefer"))),
        Error(
          postgres.InvalidUrl(postgres.UnknownParameterLooksLike(
            "sslmod",
            "sslmode",
          )),
        ),
        Error(postgres.InvalidUrl(postgres.UnsupportedFragment)),
      ])
      |> or_fail_with("Expected one URL error for each URL")
    }),
    it("returns errors that never contain the password", fn() {
      // Arrange
      let urls = [
        "postgresql://user:hunter2@localhost:abc/myapp",
        "mysql://user:hunter2@localhost/myapp",
        "postgresql://user:hunter2@localhost:0/myapp",
        "postgresql://user:hunter2@localhost/",
        "postgresql://user:hunter2@localhost/a/b",
        "postgresql://user:hunter2%zz@localhost/myapp",
        "postgresql://user:hunter2@localhost/myapp?password=hunter2",
        "postgresql://user:hunter2@localhost/myapp?sslmode=prefer",
        "postgresql://user:hunter2@localhost/myapp?sslmod=hunter2",
        "postgresql://user:hunter2@localhost/myapp#hunter2",
      ]

      // Act
      let text = string.inspect(list.map(urls, postgres.from_url))

      // Assert
      string.contains(text, "hunter2")
      |> should
      |> be_false()
      |> or_fail_with("Expected no error to contain the password")
    }),
    it(
      "returns a pool whose queries return ConnectionUnavailable when no database listens",
      fn() {
        // Arrange
        let url = database_url.unused_database_url()

        // Act
        let result =
          postgres.from_url(url)
          |> result.map(database.run_select_one)

        // Assert
        result
        |> should
        |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
        |> or_fail_with("Expected Ok(Error(ConnectionUnavailable))")
      },
    ),
    it("returns within 1 second when no database listens", fn() {
      // Arrange
      let url = database_url.unused_database_url()
      let started_at = clock.now_in_milliseconds()

      // Act
      let _result = postgres.from_url(url)
      let elapsed = clock.now_in_milliseconds() - started_at

      // Assert
      elapsed
      |> should
      |> be_less_than(1000)
      |> or_fail_with("Expected from_url to return within 1000 ms")
    }),
    it(
      "gives a pool whose query fails within 6 seconds when no database listens",
      fn() {
        // Arrange
        let url = database_url.unused_database_url()
        let started_at = clock.now_in_milliseconds()

        // Act
        let _result =
          postgres.from_url(url)
          |> result.map(database.run_select_one)
        let elapsed = clock.now_in_milliseconds() - started_at

        // Assert
        elapsed
        |> should
        |> be_less_than(6000)
        |> or_fail_with("Expected the query to fail within 6000 ms")
      },
    ),
    it("starts a new pool on each call", fn() {
      // Arrange
      let url = database_url.unused_database_url()

      // Act
      let first = postgres.from_url(url)
      let second = postgres.from_url(url)

      // Assert
      #(result.is_ok(first), result.is_ok(second), first == second)
      |> should
      |> be_equal(#(True, True, False))
      |> or_fail_with("Expected two different connections")
    }),
  ])
}
