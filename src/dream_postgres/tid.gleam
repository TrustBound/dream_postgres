//// The Gleam value of PostgreSQL's `tid`: where a row version is stored.

/// A row version's place: its block number (0 to 4294967295) and its
/// position in the block (0 to 65535).
pub type Tid {
  Tid(block: Int, offset: Int)
}
