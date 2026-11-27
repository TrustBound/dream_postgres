//// Opens transport connections for the tests whose subject is not the
//// setup deadline.

import dream_postgres/driver/deadline
import dream_postgres/driver/transport.{
  type Connection, type TransportConfig, type TransportError,
}

/// Opens a connection whose setup deadline is a minute away, so only the
/// connect timeout of the settings bounds each step.
pub fn connect_with_minute_deadline(
  config: TransportConfig,
) -> Result(Connection, TransportError) {
  transport.connect(config, deadline.from_now(60_000))
}
