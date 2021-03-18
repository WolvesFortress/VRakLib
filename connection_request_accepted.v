module vraklib

import net

struct ConnectionRequestAccepted {
mut:
	client_address     net.Addr
	system_addresses   [/* 20 */]net.Addr
	request_timestamp  u64
	accepted_timestamp u64
}

pub fn (r ConnectionRequestAccepted) encode() ByteBuffer {
	mut b := empty_buffer()
	b.put_byte(id_connection_request_accepted)
	b.put_address(r.client_address)
	b.put_short(i16(0))
	println(r.system_addresses)
	for _, addr in r.system_addresses {
	println(addr)
		b.put_address(addr)
	}
	b.put_ulong(r.request_timestamp)
	b.put_ulong(r.accepted_timestamp)
	return b
}

pub fn (mut r ConnectionRequestAccepted) decode(mut p Packet) {
	mut b := p.buffer_from_packet()
	r.client_address = b.get_address()
	println(r.client_address)
	b.get_bytes(2)
	for i := 0; i < 20; i++ {
		r.system_addresses[i] = b.get_address()
	println(r.system_addresses[i])
		if b.remainder() == 16 {
			break
		}
	}
	r.request_timestamp = b.get_ulong()
	r.accepted_timestamp = b.get_ulong()
}
