import dream_errors.{type Error}
import dream_postgres.{
  type Connection, type PostgresError, AuthorityFile, CheckAuthorityAndHost,
  TlsRequired, default_config, host, start, tls,
}

pub fn start_pool_with_private_authority(
  server_host: String,
) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host(server_host)
  |> tls(TlsRequired(
    check: CheckAuthorityAndHost(AuthorityFile("/etc/ssl/database-ca.crt")),
    direct: False,
  ))
  |> start
}
