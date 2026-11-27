//// The links of README.md, the guides and the doc comments: every link to
//// a file of this repository names the tag of the package version and a
//// file that is there, and every relative link reaches its document and
//// heading. The upgrading guide may also link to the code of 2.0.0.

import dream_test/matchers.{
  be_equal, be_greater_than, be_ok, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/document_links
import matchers/count_relative_links.{count_relative_links}
import matchers/count_repository_links.{count_repository_links}
import matchers/links_off_version.{links_off_version}
import matchers/links_off_version_or.{links_off_version_or}
import matchers/links_to_missing_files.{links_to_missing_files}
import matchers/relative_links_to_missing_targets.{
  relative_links_to_missing_targets,
}

const upgrading_guide = "docs/guides/upgrading-to-3.md"

pub fn tests() -> TestSuite {
  describe("document links", [
    it("finds the repository links of the documents", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> count_repository_links()
      |> be_greater_than(0)
      |> or_fail_with("Expected the documents to have repository links")
    }),
    it("finds the relative links of the guides", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> count_relative_links()
      |> be_greater_than(0)
      |> or_fail_with("Expected the guides to have relative links")
    }),
    it("links to the files of the package version", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> links_off_version(except_file: upgrading_guide)
      |> be_equal([])
      |> or_fail_with("Expected every repository link at the package version")
    }),
    it("links the upgrading guide to the package version or 2.0.0", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> links_off_version_or(file: upgrading_guide, older: "2.0.0")
      |> be_equal([])
      |> or_fail_with("Expected the upgrading guide at the version or 2.0.0")
    }),
    it("links to files that are in the repository", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> links_to_missing_files()
      |> be_equal([])
      |> or_fail_with("Expected every linked file in the repository")
    }),
    it("reaches the document and heading of every relative link", fn() {
      // Act
      let links = document_links.read()

      // Assert
      links
      |> should
      |> be_ok()
      |> relative_links_to_missing_targets()
      |> be_equal([])
      |> or_fail_with("Expected every relative link to reach its heading")
    }),
    it("gives a heading the anchor that GitHub gives it", fn() {
      // Act
      let anchor = document_links.heading_anchor("## Step 2: Make the tables")

      // Assert
      anchor
      |> should
      |> be_equal("step-2-make-the-tables")
      |> or_fail_with("Expected step-2-make-the-tables")
    }),
    it("leaves the HTML of a badge out of a heading anchor", fn() {
      // Act
      let anchor =
        document_links.heading_anchor(
          "### Record, then play back <a href=\"x\"><img alt=\"y\"></a>",
        )

      // Assert
      anchor
      |> should
      |> be_equal("record-then-play-back-")
      |> or_fail_with("Expected record-then-play-back-")
    }),
  ])
}
