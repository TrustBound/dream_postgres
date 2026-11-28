//// The server endpoints that the error mapping tests use.

import dream_postgres/query/driver_executor.{type Endpoint, Endpoint}

/// The endpoint of the mapping tests: `db.example` on port 5432.
pub fn example_endpoint() -> Endpoint {
  Endpoint(host: "db.example", port: 5432)
}
