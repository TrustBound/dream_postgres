//// Database URLs for the tests of `config_from_url`: URLs with the config
//// that each one gives, and URLs with the fault and the message that each
//// one gives.

import dream_postgres/config.{
  type Config, AuthorityFile, CheckAuthority, CheckAuthorityAndHost,
  NoCertificateCheck, SystemAuthorities, TlsOff, TlsPreferred, TlsRequired,
  database, default_config, host, password, port, tls, user,
}
import dream_postgres/error.{
  type UrlFault, DirectNegotiationNeedsRequiredTls, InvalidPercentEncoding,
  InvalidUrlPort, MalformedBracketedHost, MissingScheme, MultipleHosts,
  ParameterGivenTwice, ParameterWithoutValue,
  RootCertificateNeedsCertificateCheck, SystemRootCertificateNeedsVerifyFull,
  UnixSocketHost, UnixSocketNotSupported, UnknownSslMode, UnknownSslNegotiation,
  UnsupportedParameter, UnsupportedScheme, UnsupportedSslMode, UrlDatabase,
  UrlHost, UrlParameters, UrlPassword, UrlUser,
}

/// A URL and the config that it gives.
pub type ConfigExample {
  ConfigExample(url: String, config: Config)
}

/// A URL and the fault that it gives, with the message of the fault.
pub type FaultExample {
  FaultExample(url: String, fault: UrlFault, message: String)
}

/// Each form of a valid URL, with its config.
///
/// ## Example
///
/// ```gleam
/// database_urls.configs()
/// ```
pub fn configs() -> List(ConfigExample) {
  let default = default_config()
  let app_host = default |> host("db.example.com") |> database("app")
  [
    ConfigExample(
      url: "postgresql://ada:p%40ss%3Aword@db.example.com:6543/app?sslmode=verify-full",
      config: app_host
        |> port(6543)
        |> user("ada")
        |> password("p@ss:word"),
    ),
    ConfigExample(
      url: "postgres://ada@db.example.com",
      config: default
        |> host("db.example.com")
        |> user("ada")
        |> database("ada"),
    ),
    ConfigExample(
      url: "postgres://ada:p@ss@db.example.com/app",
      config: app_host |> user("ada") |> password("p@ss"),
    ),
    ConfigExample(
      url: "postgres://[2001:db8::1234]:6000/app",
      config: default |> host("2001:db8::1234") |> port(6000) |> database("app"),
    ),
    ConfigExample(
      url: "postgres://[::1]/app",
      config: default |> host("::1") |> database("app"),
    ),
    ConfigExample(url: "postgres://db.example.com:/app", config: app_host),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=disable",
      config: app_host |> tls(TlsOff),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=prefer",
      config: app_host |> tls(TlsPreferred),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=require",
      config: app_host
        |> tls(TlsRequired(check: NoCertificateCheck, direct: False)),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=verify-ca",
      config: app_host
        |> tls(TlsRequired(
          check: CheckAuthority(SystemAuthorities),
          direct: False,
        )),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=verify-full",
      config: app_host,
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=require&sslrootcert=%2Fetc%2Fca.crt",
      config: app_host
        |> tls(TlsRequired(
          check: CheckAuthority(AuthorityFile("/etc/ca.crt")),
          direct: False,
        )),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=verify-ca&sslrootcert=/etc/ca.crt",
      config: app_host
        |> tls(TlsRequired(
          check: CheckAuthority(AuthorityFile("/etc/ca.crt")),
          direct: False,
        )),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=verify-full&sslrootcert=/etc/ca.crt",
      config: app_host
        |> tls(TlsRequired(
          check: CheckAuthorityAndHost(AuthorityFile("/etc/ca.crt")),
          direct: False,
        )),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslrootcert=/etc/ca.crt",
      config: app_host
        |> tls(TlsRequired(
          check: CheckAuthorityAndHost(AuthorityFile("/etc/ca.crt")),
          direct: False,
        )),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=verify-full&sslrootcert=system",
      config: app_host,
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslrootcert=system",
      config: app_host,
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslmode=require&sslnegotiation=direct",
      config: app_host
        |> tls(TlsRequired(check: NoCertificateCheck, direct: True)),
    ),
    ConfigExample(
      url: "postgres://db.example.com/app?sslnegotiation=postgres",
      config: app_host,
    ),
  ]
}

/// Each fault of a URL, with its message.
///
/// ## Example
///
/// ```gleam
/// database_urls.faults()
/// ```
pub fn faults() -> List(FaultExample) {
  [
    FaultExample(
      url: "db.example.com:5432/app",
      fault: MissingScheme,
      message: "it does not start with postgres:// or postgresql://",
    ),
    FaultExample(
      url: "mysql://db.example.com/app",
      fault: UnsupportedScheme(scheme: "mysql"),
      message: "the scheme mysql is not postgres or postgresql",
    ),
    FaultExample(
      url: "postgres://one.example.com:5432,two.example.com:5432/app",
      fault: MultipleHosts,
      message: "it names more than one host, and dream_postgres connects to one host",
    ),
    FaultExample(
      url: "postgres://[::1/app",
      fault: MalformedBracketedHost,
      message: "the host in square brackets has no closing bracket, or text after it that is not a port",
    ),
    FaultExample(
      url: "postgres://[::1]5432/app",
      fault: MalformedBracketedHost,
      message: "the host in square brackets has no closing bracket, or text after it that is not a port",
    ),
    FaultExample(
      url: "postgres://[::1]:0/app",
      fault: InvalidUrlPort(port: "0"),
      message: "the port \"0\" is not a number in 1 to 65535",
    ),
    FaultExample(
      url: "postgresql://",
      fault: UnixSocketNotSupported,
      message: "it has no host, which libpq takes as the default Unix socket, and dream_postgres connects only over TCP",
    ),
    FaultExample(
      url: "postgres://ada@/app",
      fault: UnixSocketNotSupported,
      message: "it has no host, which libpq takes as the default Unix socket, and dream_postgres connects only over TCP",
    ),
    FaultExample(
      url: "postgres://%2Fvar%2Frun%2Fpostgresql/app",
      fault: UnixSocketHost(path: "/var/run/postgresql"),
      message: "the host /var/run/postgresql is a Unix socket directory, and dream_postgres connects only over TCP",
    ),
    FaultExample(
      url: "postgres://db.example.com:65536/app",
      fault: InvalidUrlPort(port: "65536"),
      message: "the port \"65536\" is not a number in 1 to 65535",
    ),
    FaultExample(
      url: "postgres://db.example.com:5x/app",
      fault: InvalidUrlPort(port: "5x"),
      message: "the port \"5x\" is not a number in 1 to 65535",
    ),
    FaultExample(
      url: "postgres://db.example.com:05432/app",
      fault: InvalidUrlPort(port: "05432"),
      message: "the port \"05432\" is not a number in 1 to 65535",
    ),
    FaultExample(
      url: "postgres://%zz@db.example.com/app",
      fault: InvalidPercentEncoding(part: UrlUser),
      message: "the user has a % that is not followed by two hex digits, or is not UTF-8",
    ),
    FaultExample(
      url: "postgres://ada:hunter2%zz@db.example.com/app",
      fault: InvalidPercentEncoding(part: UrlPassword),
      message: "the password has a % that is not followed by two hex digits, or is not UTF-8",
    ),
    FaultExample(
      url: "postgres://db%zz.example.com/app",
      fault: InvalidPercentEncoding(part: UrlHost),
      message: "the host has a % that is not followed by two hex digits, or is not UTF-8",
    ),
    FaultExample(
      url: "postgres://db.example.com/%FF",
      fault: InvalidPercentEncoding(part: UrlDatabase),
      message: "the database has a % that is not followed by two hex digits, or is not UTF-8",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=%zz",
      fault: InvalidPercentEncoding(part: UrlParameters),
      message: "the query has a % that is not followed by two hex digits, or is not UTF-8",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode",
      fault: ParameterWithoutValue(name: "sslmode"),
      message: "the parameter \"sslmode\" has no value",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?connect_timeout=10",
      fault: UnsupportedParameter(name: "connect_timeout"),
      message: "the parameter connect_timeout is not supported by dream_postgres",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?application_name=app",
      fault: UnsupportedParameter(name: "application_name"),
      message: "the parameter application_name is not supported by dream_postgres",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=require&sslmode=disable",
      fault: ParameterGivenTwice(name: "sslmode"),
      message: "the parameter sslmode is given more than one time",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=verify",
      fault: UnknownSslMode(mode: "verify"),
      message: "the sslmode verify is not disable, prefer, require, verify-ca or verify-full",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=allow",
      fault: UnsupportedSslMode(mode: "allow"),
      message: "the sslmode allow is not supported: use prefer or require",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslnegotiation=fast",
      fault: UnknownSslNegotiation(negotiation: "fast"),
      message: "the sslnegotiation fast is not postgres or direct",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=disable&sslnegotiation=direct",
      fault: DirectNegotiationNeedsRequiredTls(mode: "disable"),
      message: "sslnegotiation=direct needs the sslmode require, verify-ca or verify-full, not disable",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=prefer&sslnegotiation=direct",
      fault: DirectNegotiationNeedsRequiredTls(mode: "prefer"),
      message: "sslnegotiation=direct needs the sslmode require, verify-ca or verify-full, not prefer",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=disable&sslrootcert=/etc/ca.crt",
      fault: RootCertificateNeedsCertificateCheck(mode: "disable"),
      message: "an sslrootcert file needs the sslmode require, verify-ca or verify-full, not disable",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=prefer&sslrootcert=/etc/ca.crt",
      fault: RootCertificateNeedsCertificateCheck(mode: "prefer"),
      message: "an sslrootcert file needs the sslmode require, verify-ca or verify-full, not prefer",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=disable&sslrootcert=system",
      fault: SystemRootCertificateNeedsVerifyFull(mode: "disable"),
      message: "sslrootcert=system needs the sslmode verify-full, not disable",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=prefer&sslrootcert=system",
      fault: SystemRootCertificateNeedsVerifyFull(mode: "prefer"),
      message: "sslrootcert=system needs the sslmode verify-full, not prefer",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=require&sslrootcert=system",
      fault: SystemRootCertificateNeedsVerifyFull(mode: "require"),
      message: "sslrootcert=system needs the sslmode verify-full, not require",
    ),
    FaultExample(
      url: "postgres://db.example.com/app?sslmode=verify-ca&sslrootcert=system",
      fault: SystemRootCertificateNeedsVerifyFull(mode: "verify-ca"),
      message: "sslrootcert=system needs the sslmode verify-full, not verify-ca",
    ),
  ]
}
