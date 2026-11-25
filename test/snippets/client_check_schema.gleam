import dream_postgres/client as postgres
import gleam/result

pub fn check_models(
  connection: postgres.Connection,
  models: List(postgres.SchemaFingerprint),
) -> Result(Nil, String) {
  postgres.check_schema(connection, models)
  |> result.map_error(postgres.format_schema_check_error)
}
