//// The codecs of `inet`, `cidr`, `macaddr`, `macaddr8`, `bit`, `varbit`,
//// `tid` and the extension type `hstore`, in PostgreSQL's binary formats:
////
//// - `inet`, `cidr`: the family (2 for IPv4, 3 for IPv6), the prefix
////   length, 1 for `cidr` or 0, the address length, then the address.
//// - `macaddr`, `macaddr8`: the 6 or 8 bytes.
//// - `bit`, `varbit`: the number of bits (32 bits), then the bits, padded
////   with zeros to whole bytes.
//// - `tid`: the block number (32 bits), then the offset (16 bits).
//// - `hstore`: the number of pairs (32 bits), then each key and value as a
////   length (32 bits, -1 for a NULL value) and its bytes.

import dream_postgres/codecs/codec_type.{
  type DecodeIssue, type TypeLookup, Codec, Malformed, binary_bytes, is_base,
  utf8_bytes, wrong_size,
}
import dream_postgres/driver/cell.{type Cell, type TypeDescription, Binary}
import dream_postgres/network.{
  type IpAddress, type IpNetwork, type MacAddress, IpNetwork, Ipv4, Ipv6,
}
import dream_postgres/tid.{type Tid, Tid}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
  network.mac_address_from_bit_array(bytes)
  |> result.replace_error(wrong_size(description, bytes))
}

// --- bit and varbit -----------------------------------------------------------

pub const bit_string =
  Codec(
    name: "bit string",
    gleam_type: "BitArray",
    format: cell.BinaryFormat,
    accepts: accepts_bit_string,
    encode: encode_bit_string,
    decode: decode_bit_string,
    placeholder: <<>>,
  )

fn accepts_bit_string(
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Bool {
  is_base(description, ["bit", "varbit"])
}

fn encode_bit_string(
  value: BitArray,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let length = bit_array.bit_size(value)
  let padding = { 8 - length % 8 } % 8
  Ok(Binary(<<length:size(32), value:bits, 0:size(padding)>>))
}

fn decode_bit_string(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(BitArray, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<length:size(32), rest:bits>> -> take_bit_string(rest, length)
    _ -> Error(wrong_size(description, bytes))
  }
}

fn take_bit_string(
  rest: BitArray,
  length: Int,
) -> Result(BitArray, DecodeIssue) {
  case rest {
    <<bits:bits-size(length), _padding:bits>> -> Ok(bits)
    _ -> Error(Malformed("the bit string is shorter than its length"))
  }
}

// --- tid ----------------------------------------------------------------------

pub const tid_codec =
  Codec(
    name: "tid",
    gleam_type: "Tid",
    format: cell.BinaryFormat,
    accepts: accepts_tid,
    encode: encode_tid,
    decode: decode_tid,
    placeholder: Tid(0, 0),
  )

fn accepts_tid(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["tid"])
}

fn encode_tid(
  value: Tid,
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let Tid(block:, offset:) = value
  case block >= 0 && block <= 4_294_967_295 && offset >= 0 && offset <= 65_535 {
    True -> Ok(Binary(<<block:size(32), offset:size(16)>>))
    False ->
      Error(
        "("
        <> int.to_string(block)
        <> ","
        <> int.to_string(offset)
        <> ") is out of range for tid",
      )
  }
}

fn decode_tid(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Tid, DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<block:size(32), offset:size(16)>> -> Ok(Tid(block:, offset:))
    _ -> Error(wrong_size(description, bytes))
  }
}

// --- hstore -------------------------------------------------------------------

// A function, not a constant: a constant cannot hold a Dict.
pub fn hstore() -> codec_type.Codec(Dict(String, Option(String))) {
  Codec(
    name: "hstore",
    gleam_type: "Dict(String, Option(String))",
    format: cell.BinaryFormat,
    accepts: accepts_hstore,
    encode: encode_hstore,
    decode: decode_hstore,
    placeholder: dict.new(),
  )
}

fn accepts_hstore(description: TypeDescription, _lookup: TypeLookup) -> Bool {
  is_base(description, ["hstore"])
}

fn encode_hstore(
  value: Dict(String, Option(String)),
  _description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Cell, String) {
  let pairs = dict.to_list(value)
  let body =
    list.fold(pairs, <<>>, fn(bytes, pair) {
      let #(key, text) = pair
      let key_bytes = bit_array.from_string(key)
      let value_bytes = case text {
        Some(present) -> {
          let present_bytes = bit_array.from_string(present)
          <<
            { bit_array.byte_size(present_bytes) }:size(32),
            present_bytes:bits,
          >>
        }
        None -> <<-1:size(32)>>
      }
      <<
        bytes:bits,
        { bit_array.byte_size(key_bytes) }:size(32),
        key_bytes:bits,
        value_bytes:bits,
      >>
    })
  Ok(Binary(<<{ list.length(pairs) }:size(32), body:bits>>))
}

fn decode_hstore(
  value: Cell,
  description: TypeDescription,
  _lookup: TypeLookup,
) -> Result(Dict(String, Option(String)), DecodeIssue) {
  use bytes <- result.try(binary_bytes(value))
  case bytes {
    <<count:size(32), pairs:bits>> -> decode_pairs(pairs, count, dict.new())
    _ -> Error(wrong_size(description, bytes))
  }
}

fn decode_pairs(
  bytes: BitArray,
  remaining: Int,
  pairs: Dict(String, Option(String)),
) -> Result(Dict(String, Option(String)), DecodeIssue) {
  case remaining, bytes {
    0, <<>> -> Ok(pairs)
    0, _ -> Error(Malformed("the hstore has bytes after its last pair"))
    _,
      <<
        key_length:size(32),
        key:bytes-size(key_length),
        -1:signed-size(32),
        rest:bits,
      >>
    -> {
      use key_text <- result.try(utf8_bytes(key))
      decode_pairs(rest, remaining - 1, dict.insert(pairs, key_text, None))
    }
    _,
      <<
        key_length:size(32),
        key:bytes-size(key_length),
        value_length:size(32),
        text:bytes-size(value_length),
        rest:bits,
      >>
    -> {
      use key_text <- result.try(utf8_bytes(key))
      use value_text <- result.try(utf8_bytes(text))
      decode_pairs(
        rest,
        remaining - 1,
        dict.insert(pairs, key_text, Some(value_text)),
      )
    }
    _, _ -> Error(Malformed("the hstore's pairs are cut short"))
  }
}
