//// The codecs of `inet`, `cidr`, `macaddr` and `macaddr8`, in PostgreSQL's
//// binary formats:
//// - `inet`, `cidr`: the family (2 for IPv4, 3 for IPv6), the prefix
////   length, 1 for `cidr` or 0, the address length, then the address.
//// - `macaddr`, `macaddr8`: the 6 or 8 bytes.

import dream_postgres/codec/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, binary_bytes, is_base, wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import dream_postgres/network.{
  type IpAddress, type IpNetwork, type MacAddress, IpNetwork, Ipv4, Ipv6,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

// --- inet and cidr ------------------------------------------------------------

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
  use Nil <- result.try(case network.is_valid(value) {
    True -> Ok(Nil)
    False ->
      Error(network.ip_network_to_string(value) <> " is not a valid network")
  })
  use Nil <- result.try(case is_cidr && has_host_bits(value) {
    True ->
      Error(
        network.ip_network_to_string(value)
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

// --- macaddr and macaddr8 -----------------------------------------------------

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

const placeholder_mac_address = network.placeholder_mac_address

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
  let bytes = network.mac_address_to_bit_array(value)
  case description.name, bit_array.byte_size(bytes) {
    "macaddr", 8 ->
      Error(
        network.mac_address_to_string(value)
        <> " has 8 bytes, and macaddr holds 6",
      )
    _, _ -> Ok(Binary(bytes))
  }
}

fn decode_mac_address(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(MacAddress, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  network.bit_array_to_mac_address(bytes)
  |> result.replace_error(wrong_size(description, bytes))
}
