//// A config from a database URL, as libpq reads one.

import dream_errors.{type Error}
import dream_postgres/config.{
  type CertificateCheck, type Config, type Tls, AuthorityFile, CheckAuthority,
  CheckAuthorityAndHost, NoCertificateCheck, SystemAuthorities, TlsOff,
  TlsPreferred, TlsRequired, config_with_url_parts,
}
import dream_postgres/error.{
  type PostgresError, type UrlFault, DirectNegotiationNeedsRequiredTls,
  InvalidConfig, InvalidDatabaseUrl, RootCertificateNeedsCertificateCheck,
  SystemRootCertificateNeedsVerifyFull,
}
import dream_postgres/error/failure.{failure_with_no_query}
import dream_postgres/url/database_url.{
  type DatabaseUrl, type RootCertificate, type SslMode, DefaultRootCertificate,
  RootCertificateFile, SystemRootCertificate,
}
import gleam/result

/// The config of a `postgres://` or `postgresql://` URL, read as libpq
/// reads it:
/// `postgresql://user:password@host:port/database?sslmode=verify-full`.
///
/// The user, the password and the database are percent-decoded. An IPv6
/// host goes in square brackets. A part that the URL does not give keeps
/// the value of `default_config`, except the database: with no database,
/// the database is the user, as in libpq. The URL must name a host: with
/// no host, libpq uses a Unix socket, which dream_postgres does not have.
/// With no `sslmode`, the TLS is
/// the TLS of `default_config`, which is `verify-full`.
///
/// The query parameters are the ones of libpq that a config has a setting
/// for:
///
/// - `sslmode`: `disable` gives `TlsOff`, `prefer` gives `TlsPreferred`,
///   `require` gives `TlsRequired` with `NoCertificateCheck`, `verify-ca`
///   gives `CheckAuthority`, and `verify-full` gives
///   `CheckAuthorityAndHost`. `allow` is not supported.
/// - `sslrootcert`: the PEM file of the authorities, or `system` for the
///   authorities of the operating system, which needs `verify-full`. With
///   a file, `require` checks the authority, as in libpq.
/// - `sslnegotiation`: `postgres`, or `direct` for a TLS start with no
///   request first, which needs `require` or a stronger mode.
///
/// Any other parameter, such as `connect_timeout`, more than one host, no
/// host, a Unix socket directory as the host, or a port outside 1 to 65535
/// gives
/// `InvalidConfig(InvalidDatabaseUrl(fault))` of kind `Invalid`. No fault
/// and no message holds the password.
///
/// ### Start a pool from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/database_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/config.{pool_size}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection, start_pool}
/// import dream_postgres/url.{parse_database_url}
/// import gleam/result
///
/// /// Starts a pool of 4 connections from a database URL, such as
/// /// `postgresql://app:secret@db.example.com:5432/app?sslmode=verify-full`.
/// pub fn connect_with_url(
///   database_url: String,
/// ) -> Result(Connection, Error(PostgresError)) {
///   use config <- result.try(parse_database_url(database_url))
///   config
///   |> pool_size(4)
///   |> start_pool
/// }
/// ```
pub fn parse_database_url(url: String) -> Result(Config, Error(PostgresError)) {
  database_url.parse(url)
  |> result.try(config_of_url)
  |> result.map_error(fn(fault) {
    failure_with_no_query(InvalidConfig(InvalidDatabaseUrl(fault:)))
  })
}

fn config_of_url(url: DatabaseUrl) -> Result(Config, UrlFault) {
  use url_tls <- result.try(tls_of_url(url))
  Ok(config_with_url_parts(
    host: url.host,
    port: url.port,
    user: url.user,
    password: url.password,
    database: url.database,
    tls: url_tls,
  ))
}

fn tls_of_url(url: DatabaseUrl) -> Result(Tls, UrlFault) {
  use checked_tls <- result.try(certificate_tls(
    url.ssl_mode,
    url.root_certificate,
  ))
  negotiated_tls(checked_tls, url.direct_negotiation)
}

// The TLS of an `sslmode` and an `sslrootcert`, as libpq uses them.
fn certificate_tls(
  mode: SslMode,
  root_certificate: RootCertificate,
) -> Result(Tls, UrlFault) {
  case mode, root_certificate {
    database_url.Disable, DefaultRootCertificate -> Ok(TlsOff)
    database_url.Prefer, DefaultRootCertificate -> Ok(TlsPreferred)
    database_url.Require, DefaultRootCertificate ->
      Ok(required_tls(NoCertificateCheck))
    database_url.VerifyCa, DefaultRootCertificate ->
      Ok(required_tls(CheckAuthority(SystemAuthorities)))
    database_url.Require, RootCertificateFile(path:)
    | database_url.VerifyCa, RootCertificateFile(path:)
    -> Ok(required_tls(CheckAuthority(AuthorityFile(path))))
    database_url.VerifyFull, DefaultRootCertificate
    | database_url.VerifyFull, SystemRootCertificate
    -> Ok(required_tls(CheckAuthorityAndHost(SystemAuthorities)))
    database_url.VerifyFull, RootCertificateFile(path:) ->
      Ok(required_tls(CheckAuthorityAndHost(AuthorityFile(path))))
    database_url.Disable, RootCertificateFile(..) ->
      Error(RootCertificateNeedsCertificateCheck(mode: "disable"))
    database_url.Prefer, RootCertificateFile(..) ->
      Error(RootCertificateNeedsCertificateCheck(mode: "prefer"))
    database_url.Disable, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "disable"))
    database_url.Prefer, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "prefer"))
    database_url.Require, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "require"))
    database_url.VerifyCa, SystemRootCertificate ->
      Error(SystemRootCertificateNeedsVerifyFull(mode: "verify-ca"))
  }
}

fn required_tls(check: CertificateCheck) -> Tls {
  TlsRequired(check:, direct: False)
}

// `sslnegotiation=direct` starts TLS at once, so it needs TLS that is
// required. Only `disable` gives `TlsOff`, and only `prefer` gives
// `TlsPreferred`.
fn negotiated_tls(tls: Tls, direct: Bool) -> Result(Tls, UrlFault) {
  case tls, direct {
    TlsRequired(check:, ..), _ -> Ok(TlsRequired(check:, direct:))
    TlsOff, False | TlsPreferred, False -> Ok(tls)
    TlsOff, True -> Error(DirectNegotiationNeedsRequiredTls(mode: "disable"))
    TlsPreferred, True ->
      Error(DirectNegotiationNeedsRequiredTls(mode: "prefer"))
  }
}
