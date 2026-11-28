//// A matcher that checks and writes the parameters of the query of the
//// chain, for the parameter types of a prepared statement.

import dream_postgres/driver/cell.{type TypeDescription}
import dream_postgres/error.{type Reason}
import dream_postgres/query/definition.{type Query, type WrittenParameters}
import dream_test/types.{type MatchResult, MatchFailed, MatchOk}
import fixtures/type_catalog

/// Check the parameters of the query against `parameter_types`, the types
/// that the server gives for the statement, and write them. The chain goes
/// on with the written parameters, or the reason that they do not fit.
///
/// ## Example
///
/// ```gleam
/// query.query("SELECT $1") |> query.parameter(codec.int, 7)
/// |> should
/// |> write_parameters([type_catalog.int4()])
/// |> be_ok()
/// |> be_equal(WrittenParameters(formats: [BinaryFormat], values: [Binary(<<7:size(32)>>)]))
/// |> or_fail_with("Expected the four bytes of 7")
/// ```
pub fn write_parameters(
  result: MatchResult(Query),
  parameter_types: List(TypeDescription),
) -> MatchResult(Result(WrittenParameters, Reason)) {
  case result {
    MatchFailed(failure) -> MatchFailed(failure)
    MatchOk(subject) ->
      MatchOk(definition.write_parameters(
        subject,
        parameter_types,
        type_catalog.lookup,
      ))
  }
}
