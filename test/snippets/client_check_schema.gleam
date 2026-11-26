import dream_postgres/client.{
  type Connection, type SchemaFingerprint, check_schema,
  format_schema_check_error,
}
import gleam/result.{map_error}

pub fn check_models(
  connection: Connection,
  models: List(SchemaFingerprint),
) -> Result(Nil, String) {
  check_schema(connection, models)
  |> map_error(format_schema_check_error)
}
