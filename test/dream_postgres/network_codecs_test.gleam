//// The network, bit string, tid and hstore codecs against the exact bytes
//// of PostgreSQL's binary formats, and the network value functions.

import dream_postgres/codec
import dream_postgres/codecs/codec_type.{Malformed}
import dream_postgres/codecs/network.{
  IpNetwork, Ipv4, Ipv6, NotAMacAddress, NotAnIpNetwork,
}
import dream_postgres/codecs/tid.{Tid}
import dream_postgres/driver/cell.{Binary, Null}
import dream_test/matchers.{
  be_equal, be_error, be_false, be_ok, be_true, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/hstore_bytes
import fixtures/network_bytes
import fixtures/type_catalog
import gleam/dict
import gleam/option.{None, Some}
import matchers/accept_type.{accept_type}
import matchers/decode_as.{decode_as}
import matchers/encode_as.{encode_as}
import matchers/have_ip_network_text.{have_ip_network_text}
import matchers/have_mac_address_text.{have_mac_address_text}

pub fn tests() -> TestSuite {
  describe("network codecs", [
    group("inet and cidr", [
      it("takes inet", fn() {
        // Arrange
        let subject = network.ip_network

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("inet"))
        |> be_true()
        |> or_fail_with("Expected ip_network to take the type inet")
      }),
      it("takes cidr", fn() {
        // Arrange
        let subject = network.ip_network

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("cidr"))
        |> be_true()
        |> or_fail_with("Expected ip_network to take the type cidr")
      }),
      it("writes an IPv4 inet", fn() {
        // Arrange
        let value = IpNetwork(Ipv4(192, 168, 0, 1), 24)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("inet"))
        |> be_ok()
        |> be_equal(Binary(<<2, 24, 0, 4, 192, 168, 0, 1>>))
        |> or_fail_with("Expected 192.168.0.1/24 as an inet of family 2")
      }),
      it("writes an IPv4 cidr", fn() {
        // Arrange
        let value = IpNetwork(Ipv4(10, 0, 0, 0), 8)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("cidr"))
        |> be_ok()
        |> be_equal(Binary(<<2, 8, 1, 4, 10, 0, 0, 0>>))
        |> or_fail_with("Expected 10.0.0.0/8 with the cidr flag set")
      }),
      it("writes an IPv6 inet", fn() {
        // Arrange
        let value = IpNetwork(Ipv6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1), 128)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("inet"))
        |> be_ok()
        |> be_equal(
          Binary(<<3, 128, 0, 16, network_bytes.ipv6_address():bits>>),
        )
        |> or_fail_with("Expected 2001:db8::1/128 as an inet of family 3")
      }),
      it("refuses a cidr with host bits", fn() {
        // Arrange
        let value = IpNetwork(Ipv4(10, 0, 0, 1), 8)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("cidr"))
        |> be_error()
        |> be_equal(
          "10.0.0.1/8 has bits set right of its prefix, which cidr does not take",
        )
        |> or_fail_with("Expected cidr to refuse 10.0.0.1/8 for its host bits")
      }),
      it("refuses an IPv6 cidr with host bits", fn() {
        // Arrange
        let value = IpNetwork(Ipv6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1), 32)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("cidr"))
        |> be_error()
        |> be_equal(
          "2001:db8::1/32 has bits set right of its prefix, which cidr does not take",
        )
        |> or_fail_with(
          "Expected cidr to refuse 2001:db8::1/32 for its host bits",
        )
      }),
      it("refuses a part out of range", fn() {
        // Arrange
        let value = IpNetwork(Ipv4(300, 0, 0, 1), 32)

        // Act and assert
        value
        |> should
        |> encode_as(network.ip_network, type_catalog.base("inet"))
        |> be_error()
        |> be_equal("300.0.0.1 is not a valid network")
        |> or_fail_with("Expected the part 300 to make the network not valid")
      }),
      it("reads an IPv4 network", fn() {
        // Arrange
        let cell = Binary(<<2, 8, 1, 4, 10, 0, 0, 0>>)

        // Act and assert
        cell
        |> should
        |> decode_as(network.ip_network, type_catalog.base("cidr"))
        |> be_ok()
        |> be_equal(IpNetwork(Ipv4(10, 0, 0, 0), 8))
        |> or_fail_with("Expected the network 10.0.0.0/8")
      }),
      it("reads an IPv6 network", fn() {
        // Arrange
        let cell = Binary(<<3, 64, 0, 16, network_bytes.ipv6_address():bits>>)

        // Act and assert
        cell
        |> should
        |> decode_as(network.ip_network, type_catalog.base("inet"))
        |> be_ok()
        |> be_equal(IpNetwork(Ipv6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1), 64))
        |> or_fail_with("Expected the network 2001:db8::1/64")
      }),
      it("refuses an address of the wrong length", fn() {
        // Arrange
        let cell = Binary(<<2, 8, 0, 3, 1, 2, 3>>)

        // Act and assert
        cell
        |> should
        |> decode_as(network.ip_network, type_catalog.base("inet"))
        |> be_error()
        |> be_equal(Malformed("7 bytes are not a inet value"))
        |> or_fail_with("Expected an IPv4 address of 3 bytes to be malformed")
      }),
    ]),
    group("network text", [
      it("reads and writes an IPv4 address", fn() {
        // Arrange
        let text = "192.168.0.1"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("192.168.0.1")
        |> or_fail_with("Expected the IPv4 address to come back as it was")
      }),
      it("reads and writes an IPv4 network", fn() {
        // Arrange
        let text = "10.0.0.0/8"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("10.0.0.0/8")
        |> or_fail_with("Expected the IPv4 network to come back as it was")
      }),
      it("writes ::1", fn() {
        // Arrange
        let text = "0:0:0:0:0:0:0:1"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("::1")
        |> or_fail_with("Expected the loopback address as ::1")
      }),
      it("writes a zero run in the middle", fn() {
        // Arrange
        let text = "2001:db8:0:0:0:0:0:1"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("2001:db8::1")
        |> or_fail_with("Expected the zero run in the middle as ::")
      }),
      it("writes a zero run at the end", fn() {
        // Arrange
        let text = "1:0:0:0:0:0:0:0"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("1::")
        |> or_fail_with("Expected the zero run at the end as ::")
      }),
      it("writes the first of two runs of one length", fn() {
        // Arrange
        let text = "1:0:0:2:3:0:0:4"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("1::2:3:0:0:4")
        |> or_fail_with("Expected only the first of two equal zero runs as ::")
      }),
      it("writes no run for a single zero", fn() {
        // Arrange
        let text = "1:0:2:3:4:5:6:7"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("1:0:2:3:4:5:6:7")
        |> or_fail_with("Expected a single zero to stay a 0")
      }),
      it("writes an IPv4-mapped address", fn() {
        // Arrange
        let text = "::ffff:1.2.3.4"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("::ffff:1.2.3.4")
        |> or_fail_with("Expected the IPv4-mapped address with its IPv4 part")
      }),
      it("writes an IPv4-compatible address", fn() {
        // Arrange
        let text = "::1.2.3.4"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("::1.2.3.4")
        |> or_fail_with(
          "Expected the IPv4-compatible address with its IPv4 part",
        )
      }),
      it("writes an IPv6 network", fn() {
        // Arrange
        let text = "2001:db8::/32"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_ip_network_text()
        |> be_equal("2001:db8::/32")
        |> or_fail_with("Expected the IPv6 network with its prefix")
      }),
      it("refuses a zone index", fn() {
        // Arrange
        let text = "fe80::1%eth0"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAnIpNetwork("fe80::1%eth0"))
        |> or_fail_with("Expected an address with a zone index to be refused")
      }),
      it("refuses a prefix with a leading zero", fn() {
        // Arrange
        let text = "10.0.0.0/08"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAnIpNetwork("10.0.0.0/08"))
        |> or_fail_with("Expected the prefix 08 to be refused")
      }),
      it("refuses a prefix that is too long", fn() {
        // Arrange
        let text = "10.0.0.0/33"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAnIpNetwork("10.0.0.0/33"))
        |> or_fail_with("Expected the IPv4 prefix 33 to be refused")
      }),
      it("refuses a prefix that is not a number", fn() {
        // Arrange
        let text = "10.0.0.0/x"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAnIpNetwork("10.0.0.0/x"))
        |> or_fail_with("Expected the prefix x to be refused")
      }),
      it("refuses a bad address before a prefix", fn() {
        // Arrange
        let text = "10.0.0/8"

        // Act
        let parsed = network.ip_network_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAnIpNetwork("10.0.0/8"))
        |> or_fail_with("Expected the address of three parts to be refused")
      }),
      it("checks an IPv6 network", fn() {
        // Arrange
        let subject = IpNetwork(Ipv6(0, 0, 0, 0, 0, 0, 0, 70_000), 128)

        // Act
        let valid = network.is_valid(subject)

        // Assert
        valid
        |> should
        |> be_false()
        |> or_fail_with(
          "Expected an IPv6 part of 70000 to make the network not valid",
        )
      }),
      it("gives the full prefix of IPv6", fn() {
        // Arrange
        let address = Ipv6(0, 0, 0, 0, 0, 0, 0, 1)

        // Act
        let prefix_length = network.full_prefix_length(address)

        // Assert
        prefix_length
        |> should
        |> be_equal(128)
        |> or_fail_with("Expected the full prefix of IPv6 to be 128")
      }),
    ]),
    group("mac addresses", [
      it("takes macaddr8", fn() {
        // Arrange
        let subject = network.mac_address

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("macaddr8"))
        |> be_true()
        |> or_fail_with("Expected mac_address to take the type macaddr8")
      }),
      it("reads a text with colons", fn() {
        // Arrange
        let text = "08:00:2b:01:02:03"

        // Act
        let parsed = network.mac_address_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_mac_address_text()
        |> be_equal("08:00:2b:01:02:03")
        |> or_fail_with(
          "Expected the MAC address with colons to come back as it was",
        )
      }),
      it("reads an 8-byte text with dashes", fn() {
        // Arrange
        let text = "08-00-2B-01-02-03-04-05"

        // Act
        let parsed = network.mac_address_from_string(text)

        // Assert
        parsed
        |> should
        |> be_ok()
        |> have_mac_address_text()
        |> be_equal("08:00:2b:01:02:03:04:05")
        |> or_fail_with(
          "Expected the 8-byte MAC address in lower case with colons",
        )
      }),
      it("refuses 5 bytes", fn() {
        // Arrange
        let text = "08:00:2b:01:02"

        // Act
        let parsed = network.mac_address_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAMacAddress)
        |> or_fail_with("Expected a text of 5 bytes to be refused")
      }),
      it("refuses a part that is not hex", fn() {
        // Arrange
        let text = "08:00:2b:01:02:zz"

        // Act
        let parsed = network.mac_address_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAMacAddress)
        |> or_fail_with("Expected the part zz to be refused")
      }),
      it("refuses a part of one digit", fn() {
        // Arrange
        let text = "8:00:2b:01:02:03"

        // Act
        let parsed = network.mac_address_from_string(text)

        // Assert
        parsed
        |> should
        |> be_error()
        |> be_equal(NotAMacAddress)
        |> or_fail_with("Expected the part 8 of one digit to be refused")
      }),
      it("writes 6 bytes to macaddr", fn() {
        // Arrange
        let bytes = <<8, 0, 43, 1, 2, 3>>

        // Act
        let address = network.mac_address_from_bit_array(bytes)

        // Assert
        address
        |> should
        |> be_ok()
        |> encode_as(network.mac_address, type_catalog.base("macaddr"))
        |> be_ok()
        |> be_equal(Binary(<<8, 0, 43, 1, 2, 3>>))
        |> or_fail_with("Expected the 6 bytes as they are in a macaddr")
      }),
      it("writes 6 bytes to macaddr8", fn() {
        // Arrange
        let bytes = <<8, 0, 43, 1, 2, 3>>

        // Act
        let address = network.mac_address_from_bit_array(bytes)

        // Assert
        address
        |> should
        |> be_ok()
        |> encode_as(network.mac_address, type_catalog.base("macaddr8"))
        |> be_ok()
        |> be_equal(Binary(<<8, 0, 43, 1, 2, 3>>))
        |> or_fail_with("Expected the 6 bytes as they are in a macaddr8")
      }),
      it("refuses 8 bytes for macaddr", fn() {
        // Arrange
        let bytes = <<8, 0, 43, 1, 2, 3, 4, 5>>

        // Act
        let address = network.mac_address_from_bit_array(bytes)

        // Assert
        address
        |> should
        |> be_ok()
        |> encode_as(network.mac_address, type_catalog.base("macaddr"))
        |> be_error()
        |> be_equal("08:00:2b:01:02:03:04:05 has 8 bytes, and macaddr holds 6")
        |> or_fail_with("Expected macaddr to refuse an address of 8 bytes")
      }),
      it("reads 8 bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2, 3, 4, 5, 6, 7, 8>>)

        // Act and assert
        cell
        |> should
        |> decode_as(network.mac_address, type_catalog.base("macaddr8"))
        |> be_ok()
        |> have_mac_address_text()
        |> be_equal("01:02:03:04:05:06:07:08")
        |> or_fail_with(
          "Expected the 8-byte MAC address 01:02:03:04:05:06:07:08",
        )
      }),
      it("refuses 7 bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2, 3, 4, 5, 6, 7>>)

        // Act and assert
        cell
        |> should
        |> decode_as(network.mac_address, type_catalog.base("macaddr8"))
        |> be_error()
        |> or_fail_with("Expected 7 bytes to be refused as a MAC address")
      }),
      it("has the zero address as its placeholder", fn() {
        // Arrange
        let subject = network.mac_address

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> have_mac_address_text()
        |> be_equal("00:00:00:00:00:00")
        |> or_fail_with("Expected the placeholder to be the zero address")
      }),
    ]),
    group("bit strings", [
      it("takes varbit", fn() {
        // Arrange
        let subject = codec.bit_string

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("varbit"))
        |> be_true()
        |> or_fail_with("Expected bit_string to take the type varbit")
      }),
      it("writes 3 bits padded to a byte", fn() {
        // Arrange
        let value = <<5:size(3)>>

        // Act and assert
        value
        |> should
        |> encode_as(codec.bit_string, type_catalog.base("varbit"))
        |> be_ok()
        |> be_equal(Binary(<<3:size(32), 0b10100000>>))
        |> or_fail_with(
          "Expected the length 3 and the bits 101 padded with zeros",
        )
      }),
      it("writes 16 bits with no padding", fn() {
        // Arrange
        let value = <<1, 2>>

        // Act and assert
        value
        |> should
        |> encode_as(codec.bit_string, type_catalog.base("bit"))
        |> be_ok()
        |> be_equal(Binary(<<16:size(32), 1, 2>>))
        |> or_fail_with("Expected the length 16 and the two bytes")
      }),
      it("reads 3 bits", fn() {
        // Arrange
        let cell = Binary(<<3:size(32), 0b10100000>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.bit_string, type_catalog.base("varbit"))
        |> be_ok()
        |> be_equal(<<5:size(3)>>)
        |> or_fail_with("Expected the three bits 101")
      }),
      it("refuses bits shorter than the length", fn() {
        // Arrange
        let cell = Binary(<<9:size(32), 1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.bit_string, type_catalog.base("varbit"))
        |> be_error()
        |> be_equal(Malformed("the bit string is shorter than its length"))
        |> or_fail_with("Expected 8 bits for a length of 9 to be malformed")
      }),
      it("refuses a cut length", fn() {
        // Arrange
        let cell = Binary(<<1, 2>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.bit_string, type_catalog.base("varbit"))
        |> be_error()
        |> be_equal(Malformed("2 bytes are not a varbit value"))
        |> or_fail_with("Expected a length of two bytes to be malformed")
      }),
    ]),
    group("tid", [
      it("takes tid", fn() {
        // Arrange
        let subject = tid.tid

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("tid"))
        |> be_true()
        |> or_fail_with("Expected tid to take the type tid")
      }),
      it("writes a block and an offset", fn() {
        // Arrange
        let value = Tid(7, 3)

        // Act and assert
        value
        |> should
        |> encode_as(tid.tid, type_catalog.base("tid"))
        |> be_ok()
        |> be_equal(Binary(<<7:size(32), 3:size(16)>>))
        |> or_fail_with(
          "Expected the block 7 in 4 bytes and the offset 3 in 2 bytes",
        )
      }),
      it("refuses an offset out of range", fn() {
        // Arrange
        let value = Tid(7, 65_536)

        // Act and assert
        value
        |> should
        |> encode_as(tid.tid, type_catalog.base("tid"))
        |> be_error()
        |> be_equal("(7,65536) is out of range for tid")
        |> or_fail_with("Expected the offset 65536 to be out of range")
      }),
      it("reads a block and an offset", fn() {
        // Arrange
        let cell = Binary(<<7:size(32), 3:size(16)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(tid.tid, type_catalog.base("tid"))
        |> be_ok()
        |> be_equal(Tid(7, 3))
        |> or_fail_with("Expected the tid (7,3)")
      }),
      it("refuses five bytes", fn() {
        // Arrange
        let cell = Binary(<<1, 2, 3, 4, 5>>)

        // Act and assert
        cell
        |> should
        |> decode_as(tid.tid, type_catalog.base("tid"))
        |> be_error()
        |> be_equal(Malformed("5 bytes are not a tid value"))
        |> or_fail_with("Expected five bytes to be a malformed tid")
      }),
    ]),
    group("hstore", [
      it("takes hstore", fn() {
        // Arrange
        let subject = codec.hstore()

        // Act and assert
        subject
        |> should
        |> accept_type(type_catalog.base("hstore"))
        |> be_true()
        |> or_fail_with("Expected hstore to take the type hstore")
      }),
      it("writes a pair", fn() {
        // Arrange
        let value = dict.from_list([#("a", Some("b"))])

        // Act and assert
        value
        |> should
        |> encode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_ok()
        |> be_equal(Binary(hstore_bytes.one_pair()))
        |> or_fail_with("Expected the bytes of the pair a, b")
      }),
      it("writes a NULL value", fn() {
        // Arrange
        let value = dict.from_list([#("a", None)])

        // Act and assert
        value
        |> should
        |> encode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_ok()
        |> be_equal(Binary(hstore_bytes.null_pair()))
        |> or_fail_with("Expected the bytes of the key a with the length -1")
      }),
      it("reads a pair", fn() {
        // Arrange
        let cell = Binary(hstore_bytes.one_pair())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_ok()
        |> be_equal(dict.from_list([#("a", Some("b"))]))
        |> or_fail_with("Expected the pair a, b")
      }),
      it("reads a NULL value", fn() {
        // Arrange
        let cell = Binary(hstore_bytes.null_pair())

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_ok()
        |> be_equal(dict.from_list([#("a", None)]))
        |> or_fail_with("Expected the key a with no value")
      }),
      it("refuses bytes after the last pair", fn() {
        // Arrange
        let cell = Binary(<<hstore_bytes.one_pair():bits, 0>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_error()
        |> be_equal(Malformed("the hstore has bytes after its last pair"))
        |> or_fail_with("Expected a byte after the last pair to be malformed")
      }),
      it("refuses pairs that are cut short", fn() {
        // Arrange
        let cell = Binary(<<2:size(32), 1:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_error()
        |> be_equal(Malformed("the hstore's pairs are cut short"))
        |> or_fail_with("Expected two pairs with no bytes to be malformed")
      }),
      it("refuses a key that is not UTF-8", fn() {
        // Arrange
        let cell = Binary(<<1:size(32), 1:size(32), 255, -1:size(32)>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_error()
        |> be_equal(Malformed("the text is not UTF-8"))
        |> or_fail_with("Expected the key byte 255 to be refused as not UTF-8")
      }),
      it("refuses a cut count", fn() {
        // Arrange
        let cell = Binary(<<1>>)

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_error()
        |> be_equal(Malformed("1 bytes are not a hstore value"))
        |> or_fail_with("Expected a count of one byte to be malformed")
      }),
      it("refuses NULL", fn() {
        // Arrange
        let cell = Null

        // Act and assert
        cell
        |> should
        |> decode_as(codec.hstore(), type_catalog.base("hstore"))
        |> be_error()
        |> or_fail_with("Expected NULL to be refused as an hstore")
      }),
      it("has an empty placeholder", fn() {
        // Arrange
        let subject = codec.hstore()

        // Act
        let placeholder = codec_type.placeholder(subject)

        // Assert
        placeholder
        |> should
        |> be_equal(dict.new())
        |> or_fail_with("Expected the placeholder to be the empty hstore")
      }),
    ]),
  ])
}
