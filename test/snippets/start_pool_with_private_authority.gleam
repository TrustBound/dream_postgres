import dream_errors.{type Error}
import dream_postgres/config.{
  AuthorityFile, CheckAuthorityAndHost, TlsRequired, default_config, host, tls,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

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
