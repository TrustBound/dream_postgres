import dream_postgres/config.{
  type Config, AuthorityFile, CheckAuthorityAndHost, TlsRequired, tls,
}

/// Requires TLS, and checks the certificate of the server: an authority of
/// the file must sign it, and it must name the host of the config.
pub fn verified_tls(config: Config, authority_file: String) -> Config {
  config
  |> tls(TlsRequired(
    check: CheckAuthorityAndHost(AuthorityFile(authority_file)),
    direct: False,
  ))
}
