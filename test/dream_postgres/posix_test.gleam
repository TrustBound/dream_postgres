//// The Posix type lists exactly the errno names of OTP 28 and OTP 29, from
//// the copies of their lists in test/fixtures/otp, less "unknown" (the name
//// for an errno that OTP 28 does not know) and "esuccess" (success, not an
//// error).

import dream_postgres/posix.{Econnrefused, NotAnAtom, Unlisted}
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/atom
import fixtures/otp_errno_names
import gleam/dynamic
import gleam/list
import gleam/string

pub fn tests() -> TestSuite {
  describe("posix", [
    it("lists exactly the names of OTP 28 and OTP 29", fn() {
      // Arrange
      let otp_names = otp_errno_names.sorted()

      // Act
      let listed =
        posix.posix_codes() |> list.map(posix.name) |> list.sort(string.compare)

      // Assert
      listed
      |> should
      |> be_equal(otp_names)
      |> or_fail_with("Expected the names of OTP 28 and 29")
    }),
    it("gives each listed name its own variant", fn() {
      // Act
      let round_trips =
        list.all(posix.posix_codes(), fn(code) {
          posix.from_reason(atom.from_name(posix.name(code))) == Ok(code)
        })

      // Assert
      round_trips
      |> should
      |> be_true()
      |> or_fail_with("Expected every name to give its own variant")
    }),
    it("reads econnrefused as Econnrefused", fn() {
      // Arrange
      let reason = atom.from_name("econnrefused")

      // Act
      let code = posix.from_reason(reason)

      // Assert
      code
      |> should
      |> be_ok()
      |> be_equal(Econnrefused)
      |> or_fail_with("Expected Econnrefused")
    }),
    it("reads a name that no list has as Unlisted", fn() {
      // Arrange
      let reason = atom.from_name("errno_999")

      // Act
      let code = posix.from_reason(reason)

      // Assert
      code
      |> should
      |> be_ok()
      |> be_equal(Unlisted("errno_999"))
      |> or_fail_with("Expected Unlisted(\"errno_999\")")
    }),
    it("refuses a reason that is not an atom", fn() {
      // Arrange
      let reason = dynamic.int(7)

      // Act
      let code = posix.from_reason(reason)

      // Assert
      code
      |> should
      |> be_error()
      |> be_equal(NotAnAtom(reason))
      |> or_fail_with("Expected NotAnAtom for the integer 7")
    }),
    it("names an Unlisted value by the name it holds", fn() {
      // Act
      let name = posix.name(Unlisted("errno_999"))

      // Assert
      name
      |> should
      |> be_equal("errno_999")
      |> or_fail_with("Expected errno_999")
    }),
  ])
}
