//// The Gleam values of PostgreSQL's network types: `inet`, `cidr`,
//// `macaddr` and `macaddr8`.
////
//// In PostgreSQL's binary formats:
////
//// - `inet`, `cidr`: the family (2 for IPv4, 3 for IPv6), the prefix
////   length, 1 for `cidr` or 0, the address length, then the address.
//// - `macaddr`, `macaddr8`: the 6 or 8 bytes.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, binary_bytes, is_base, wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// An IP address. Each part of `Ipv4` is from 0 to 255, and each part of
/// `Ipv6` is from 0 to 65535.
pub type IpAddress {
  Ipv4(Int, Int, Int, Int)
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// An `inet` or a `cidr` value: an address and the length of its network
/// prefix. A plain address has the full length, 32 or 128.
pub type IpNetwork {
  IpNetwork(address: IpAddress, prefix_length: Int)
}

/// A text that is not an IP address or network.
pub type NotAnIpNetwork {
  NotAnIpNetwork(text: String)
}

/// A MAC address of 6 bytes (`macaddr`) or 8 bytes (`macaddr8`). The type
/// is opaque, so each byte is always from 0 to 255.
pub opaque type MacAddress {
  MacAddress6(Int, Int, Int, Int, Int, Int)
  MacAddress8(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// The MAC address 00:00:00:00:00:00, the placeholder of the MAC address
/// codec.
@internal
pub const placeholder_mac_address = MacAddress6(0, 0, 0, 0, 0, 0)

/// A value that is not a MAC address.
pub type NotAMacAddress {
  NotAMacAddress
}

/// Whether each part of a network is in range: the address parts, and a
/// prefix length of at most 32 (IPv4) or 128 (IPv6).
pub fn is_valid(network: IpNetwork) -> Bool {
  valid_ip_network(network)
}

/// The network of a text such as `10.0.0.0/8`, `::1` or `192.168.0.1`.
pub fn ip_network_from_string(
  text: String,
) -> Result(IpNetwork, NotAnIpNetwork) {
  parse_network(text) |> result.replace_error(NotAnIpNetwork(text))
}

// PostgreSQL's inet takes no zone index (`fe80::1%eth0`), and OTP's
// parser does, so a `%` is refused here.
fn parse_network(text: String) -> Result(IpNetwork, Nil) {
  case string.contains(text, "%") {
    True -> Error(Nil)
    False -> parse_network_text(text)
  }
}

fn parse_network_text(text: String) -> Result(IpNetwork, Nil) {
  case string.split_once(text, "/") {
    Ok(#(address_text, length_text)) -> {
      use address <- result.try(parse_address(address_text))
      use length <- result.try(int.parse(length_text))
      checked_network(
        IpNetwork(address: address, prefix_length: length),
        length_text,
      )
    }
    Error(Nil) ->
      parse_address(text)
      |> result.map(fn(address) {
        IpNetwork(address: address, prefix_length: full_prefix_length(address))
      })
  }
}

fn checked_network(
  network: IpNetwork,
  length_text: String,
) -> Result(IpNetwork, Nil) {
  case
    int.to_string(network.prefix_length) == length_text
    && valid_ip_network(network)
  {
    True -> Ok(network)
    False -> Error(Nil)
  }
}

@external(erlang, "dream_postgres_network_ffi", "parse_address")
fn parse_address(text: String) -> Result(IpAddress, Nil)

/// The text of a network, as PostgreSQL writes an `inet` value: the
/// address alone when the prefix is the full length.
pub fn ip_network_to_string(value: IpNetwork) -> String {
  let address = ip_address_text(value.address)
  case value.prefix_length == full_prefix_length(value.address) {
    True -> address
    False -> address <> "/" <> int.to_string(value.prefix_length)
  }
}

/// The length of a full prefix: 32 for IPv4, 128 for IPv6.
pub fn full_prefix_length(address: IpAddress) -> Int {
  case address {
    Ipv4(..) -> 32
    Ipv6(..) -> 128
  }
}

fn valid_ip_network(value: IpNetwork) -> Bool {
  case value.address {
    Ipv4(a, b, c, d) ->
      list.all([a, b, c, d], in_range(_, 0, 255))
      && in_range(value.prefix_length, 0, 32)
    Ipv6(a, b, c, d, e, f, g, h) ->
      list.all([a, b, c, d, e, f, g, h], in_range(_, 0, 65_535))
      && in_range(value.prefix_length, 0, 128)
  }
}

fn in_range(value: Int, lowest: Int, highest: Int) -> Bool {
  value >= lowest && value <= highest
}

fn ip_address_text(address: IpAddress) -> String {
  case address {
    Ipv4(a, b, c, d) -> string.join(list.map([a, b, c, d], int.to_string), ".")
    Ipv6(a, b, c, d, e, f, g, h) -> ipv6_text([a, b, c, d, e, f, g, h])
  }
}

// The text that PostgreSQL gives for an IPv6 address. The longest run of
// two or more zero parts, the first one of two runs of the same length,
// becomes `::`. When the run is the first 6 parts, or the first 5 parts
// before a part `ffff`, the last 2 parts are an IPv4 address.
fn ipv6_text(parts: List(Int)) -> String {
  let #(start, length) = longest_zero_run(parts, 0, #(0, 0), #(0, 0))
  let ipv4_end =
    start == 0
    && {
      length == 6
      || { length == 5 && list.drop(parts, 5) |> list.first == Ok(0xffff) }
    }
  let text = ipv6_parts_text(parts, 0, start, length, ipv4_end, "")
  case length > 0 && start + length == 8 {
    True -> text <> ":"
    False -> text
  }
}

// The start and the length of the longest run of zero parts, from `index`
// on. `best` and `current` are the runs that the parts before gave. A run
// of 1 part does not count.
fn longest_zero_run(
  parts: List(Int),
  index: Int,
  best: #(Int, Int),
  current: #(Int, Int),
) -> #(Int, Int) {
  case parts {
    [] -> zero_run_worth_shortening(longer_run(best, current))
    [0, ..rest] ->
      longest_zero_run(rest, index + 1, best, extended_run(current, index))
    [_, ..rest] ->
      longest_zero_run(rest, index + 1, longer_run(best, current), #(0, 0))
  }
}

fn zero_run_worth_shortening(run: #(Int, Int)) -> #(Int, Int) {
  case run.1 >= 2 {
    True -> run
    False -> #(0, 0)
  }
}

fn extended_run(current: #(Int, Int), index: Int) -> #(Int, Int) {
  case current.1 {
    0 -> #(index, 1)
    length -> #(current.0, length + 1)
  }
}

fn longer_run(best: #(Int, Int), current: #(Int, Int)) -> #(Int, Int) {
  case current.1 > best.1 {
    True -> current
    False -> best
  }
}

fn run_colon(text: String, at_start: Bool) -> String {
  case at_start {
    True -> text <> ":"
    False -> text
  }
}

fn part_separator(index: Int) -> String {
  case index {
    0 -> ""
    _ -> ":"
  }
}

fn ipv6_parts_text(
  parts: List(Int),
  index: Int,
  start: Int,
  length: Int,
  ipv4_end: Bool,
  text: String,
) -> String {
  case parts {
    [] -> text
    [_, ..rest] if index >= start && index < start + length ->
      ipv6_parts_text(
        rest,
        index + 1,
        start,
        length,
        ipv4_end,
        run_colon(text, index == start),
      )
    [high, low] if index == 6 && ipv4_end ->
      text
      <> ":"
      <> string.join(
        list.map([high / 256, high % 256, low / 256, low % 256], int.to_string),
        ".",
      )
    [part, ..rest] -> {
      let text =
        text <> part_separator(index) <> string.lowercase(int.to_base16(part))
      ipv6_parts_text(rest, index + 1, start, length, ipv4_end, text)
    }
  }
}

/// The MAC address of 6 or 8 bytes.
pub fn mac_address_from_bit_array(
  bytes: BitArray,
) -> Result(MacAddress, NotAMacAddress) {
  case bytes {
    <<a, b, c, d, e, f>> -> Ok(MacAddress6(a, b, c, d, e, f))
    <<a, b, c, d, e, f, g, h>> -> Ok(MacAddress8(a, b, c, d, e, f, g, h))
    _ -> Error(NotAMacAddress)
  }
}

/// The 6 or 8 bytes of a MAC address.
pub fn mac_address_to_bit_array(value: MacAddress) -> BitArray {
  case value {
    MacAddress6(a, b, c, d, e, f) -> <<a, b, c, d, e, f>>
    MacAddress8(a, b, c, d, e, f, g, h) -> <<a, b, c, d, e, f, g, h>>
  }
}

/// The MAC address of a text such as `08:00:2b:01:02:03` or
/// `08-00-2b-01-02-03-04-05`.
pub fn mac_address_from_string(
  text: String,
) -> Result(MacAddress, NotAMacAddress) {
  let separator = case string.contains(text, "-") {
    True -> "-"
    False -> ":"
  }
  string.split(text, separator)
  |> list.try_map(hex_byte)
  |> result.replace_error(NotAMacAddress)
  |> result.try(fn(bytes) {
    list.fold(bytes, <<>>, fn(all, byte) { <<all:bits, byte>> })
    |> mac_address_from_bit_array
  })
}

fn hex_byte(text: String) -> Result(Int, Nil) {
  use byte <- result.try(int.base_parse(text, 16))
  case string.lowercase(text) == hex_text(byte) {
    True -> Ok(byte)
    False -> Error(Nil)
  }
}

fn hex_text(byte: Int) -> String {
  int.to_base16(byte)
  |> string.lowercase
  |> string.pad_start(to: 2, with: "0")
}

/// The text of a MAC address, as PostgreSQL writes it: `08:00:2b:01:02:03`.
pub fn mac_address_to_string(value: MacAddress) -> String {
  bytes_of(mac_address_to_bit_array(value))
  |> list.map(hex_text)
  |> string.join(":")
}

fn bytes_of(bytes: BitArray) -> List(Int) {
  case bytes {
    <<byte, rest:bytes>> -> [byte, ..bytes_of(rest)]
    _ -> []
  }
}

// --- Codecs ---------------------------------------------------------------------

/// `inet` and `cidr`, as an `IpNetwork`. A `cidr` parameter with bits set
/// right of its prefix is refused before the query is sent.
pub const ip_network =
  Codec(
    name: "ip network",
    gleam_type: "IpNetwork",
    format: cell.BinaryFormat,
    accepts: accepts_ip_network,
    encode: encode_ip_network,
    decode: decode_ip_network,
    placeholder: IpNetwork(Ipv4(0, 0, 0, 0), 32),
  )

fn accepts_ip_network(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["inet", "cidr"])
}

fn encode_ip_network(
  value: IpNetwork,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let is_cidr = description.name == "cidr"
  use Nil <- result.try(case is_valid(value) {
    True -> Ok(Nil)
    False -> Error(ip_network_to_string(value) <> " is not a valid network")
  })
  use Nil <- result.try(case is_cidr && has_host_bits(value) {
    True ->
      Error(
        ip_network_to_string(value)
        <> " has bits set right of its prefix, which cidr does not take",
      )
    False -> Ok(Nil)
  })
  let cidr_flag = case is_cidr {
    True -> 1
    False -> 0
  }
  let #(family, address) = address_bytes(value.address)
  Ok(
    Binary(<<
      family,
      value.prefix_length,
      cidr_flag,
      { bit_array.byte_size(address) },
      address:bits,
    >>),
  )
}

fn address_bytes(address: IpAddress) -> #(Int, BitArray) {
  case address {
    Ipv4(a, b, c, d) -> #(2, <<a, b, c, d>>)
    Ipv6(a, b, c, d, e, f, g, h) -> #(3, <<
      a:size(16),
      b:size(16),
      c:size(16),
      d:size(16),
      e:size(16),
      f:size(16),
      g:size(16),
      h:size(16),
    >>)
  }
}

fn has_host_bits(value: IpNetwork) -> Bool {
  let #(total_bits, number) = case value.address {
    Ipv4(a, b, c, d) -> #(32, list.fold([a, b, c, d], 0, shift_in(8)))
    Ipv6(a, b, c, d, e, f, g, h) -> #(
      128,
      list.fold([a, b, c, d, e, f, g, h], 0, shift_in(16)),
    )
  }
  let host_bits = total_bits - value.prefix_length
  int.bitwise_and(number, int.bitwise_shift_left(1, host_bits) - 1) != 0
}

fn shift_in(width: Int) -> fn(Int, Int) -> Int {
  fn(number, part) { int.bitwise_shift_left(number, width) + part }
}

fn decode_ip_network(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(IpNetwork, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<2, prefix_length, _cidr, 4, a, b, c, d>> ->
      Ok(IpNetwork(Ipv4(a, b, c, d), prefix_length))
    <<
      3,
      prefix_length,
      _cidr,
      16,
      a:size(16),
      b:size(16),
      c:size(16),
      d:size(16),
      e:size(16),
      f:size(16),
      g:size(16),
      h:size(16),
    >> -> Ok(IpNetwork(Ipv6(a, b, c, d, e, f, g, h), prefix_length))
    _ -> Error(wrong_size(description, bytes))
  }
}

/// `macaddr` and `macaddr8`, as a `MacAddress`.
pub const mac_address =
  Codec(
    name: "mac address",
    gleam_type: "MacAddress",
    format: cell.BinaryFormat,
    accepts: accepts_mac_address,
    encode: encode_mac_address,
    decode: decode_mac_address,
    placeholder: placeholder_mac_address,
  )

fn accepts_mac_address(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["macaddr", "macaddr8"])
}

// A 6-byte address fits both types: PostgreSQL makes a macaddr8 of it. An
// 8-byte address does not fit macaddr.
fn encode_mac_address(
  value: MacAddress,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let bytes = mac_address_to_bit_array(value)
  case description.name, bit_array.byte_size(bytes) {
    "macaddr", 8 ->
      Error(mac_address_to_string(value) <> " has 8 bytes, and macaddr holds 6")
    _, _ -> Ok(Binary(bytes))
  }
}

fn decode_mac_address(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(MacAddress, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  mac_address_from_bit_array(bytes)
  |> result.replace_error(wrong_size(description, bytes))
}
