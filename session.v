module vraklib

import net

const (
	max_split_size  = 128
	max_split_count = 4
	channel_count   = 32
	min_mtu_size    = 400
	window_size     = 2048 // should be mutable
)

enum State {
	connecting
	connected
	disconnecting
	disconnected
}

struct TmpMapEncapsulatedPacket {
mut:
	m map[string]EncapsulatedPacket
}

struct TmpMapInt {
mut:
	m map[string]int//u32?
}

struct Session {//This is Conn in go-raknet
mut:
	message_index                   u32 //u24
	send_ordered_index              []u32 //u24
	send_sequenced_index            []int//u32?
	receive_ordered_index           []int//u32?
	receive_sequenced_highest_index []int//u32?
	receive_ordered_packets         [][]EncapsulatedPacket
	session_manager                 SessionManager
	// logger logger
	address                         net.Addr
	state                           State
	// connecting
	mtu_size                        u16
	id                              u64
	split_id                        u32
	// 0
	send_seq_number                 u32 //u24
	// 0
	last_update                     f32
	disconnection_time              f32
	is_temporal                     bool
	// true
	// packet_to_send
	packet_to_send                  []Datagram
	is_active                       bool
	// false
	ack_queue                       map[string]u32
	nack_queue                      map[string]u32
	// maybe map[int]Datagram, key is seqNumber
	recovery_queue                  map[string]Datagram
	split_packets                   map[string]TmpMapEncapsulatedPacket
	need_ack                        map[string]TmpMapInt//u32?
	send_queue_data                 Datagram
	window_start                    u32
	window_end                      u32
	highest_seq_number              u32
	reliable_window_start           int
	reliable_window_end             int
	reliable_window                 map[string]bool
	last_ping_time                  f32
	// -1
	last_ping_measure               int
	// 1
	internal_id                     int
}

fn new_session(session_manager SessionManager, address net.Addr, client_id u64, mtu_size u16, internal_id int) Session {
	println('$address.saddr, $address.port, $client_id, $mtu_size, $internal_id')
	session := Session{
		send_ordered_index: [u32(0)].repeat(channel_count)
		send_sequenced_index: [0].repeat(channel_count)
		receive_ordered_index: [0].repeat(channel_count)
		receive_sequenced_highest_index: [0].repeat(channel_count)
		receive_ordered_packets: [[]EncapsulatedPacket{}].repeat(channel_count)
		session_manager: session_manager
		address: address
		mtu_size: mtu_size
		id: client_id
		send_queue_data: Datagram{}
		internal_id: internal_id
	}
	return session
}

fn (mut s Session) update() {
	diff := s.highest_seq_number - s.window_start + u32(1)
	assert diff > u32(0)
	if diff > u32(0) {// warning: comparison of unsigned expression >= 0 is always true [-Wtype-limits]
		s.window_start += diff
		s.window_end += diff
	}
	if s.ack_queue.len > 0 {
		// packet := Ack()
		// s.ack_queue = map[string]int{}
	}
	if s.nack_queue.len > 0 {
		// packet := Nack()
		// s.nack_queue = map[string]int{}
	}
	if s.need_ack.len > 0 {
		for _, ack in s.need_ack {
			if ack.m.len == 0 {
				// s.need_ack[i]
				// s.session_manager.notify_ack(s, i)
			}
		}
	}
	s.send_queue()
}

fn (mut s Session) send_datagram(datagram Datagram) {
	mut d := datagram
	if datagram.sequence_number != u32(-1) {
		s.recovery_queue.delete(datagram.sequence_number.str())
	}
	d.sequence_number = s.send_seq_number
	s.send_seq_number++
	s.recovery_queue[d.sequence_number.str()] = datagram
	// d,
	s.send_packet(d.p)
}

fn (s Session) send_packet(p Packet) {
	mut pp := p
	pp.address = s.address
	// r,
	s.session_manager.send_packet(pp)
}

fn (mut s Session) send_ping(reliability byte) {
	packet := ConnectedPing{
		client_timestamp: u64(s.session_manager.get_raknet_time_ms())
	}
	s.queue_connected_packet(packet.p, reliability, 0, priority_immediate)
}

fn (mut s Session) send_queue() {
	if s.send_queue_data.packets.len > 0 {
		s.send_datagram(s.send_queue_data)
		s.send_queue_data = Datagram{
			sequence_number: -1
		}
	}
}

fn (mut s Session) queue_connected_packet(packet Packet, reliability byte, order_channel int, flag byte) {
	mut encapsulated := EncapsulatedPacket{
		buffer: packet.buffer.buffer
		length: u16(packet.buffer.length)
		reliability: reliability
		order_channel: order_channel
	}
	s.add_encapsulated_to_queue(encapsulated, flag)
}

fn (mut s Session) add_to_queue(packet EncapsulatedPacket, flags byte) {
	mut p := packet
	priority := flags & 0x07
	if p.need_ack && p.message_index != u32(-1) {
		mut arr := s.need_ack[p.identifier_ack.str()]
		arr.m[p.message_index.str()] = int(p.message_index)
	}
	length := s.send_queue_data.get_total_length()
	if u32(length) + p.get_length() > u32(s.mtu_size - u16(36)) {
		s.send_queue()
	}
	if p.need_ack {
		s.send_queue_data.packets << p
		p.need_ack = false
	} else {
		s.send_queue_data.packets << p
	}
	if priority == priority_immediate {
		s.send_queue()
	}
}

fn (mut s Session) add_encapsulated_to_queue(packet EncapsulatedPacket, flags byte) {
	mut p := packet
	p.need_ack = (flags & 0x09) != 0
	println(p.need_ack)
	if p.need_ack {
		s.need_ack[p.identifier_ack.str()] = TmpMapInt{}
	}
	if reliability_is_ordered(p.reliability) {
		p.order_index = s.send_ordered_index[p.order_channel]
		s.send_ordered_index[p.order_channel]++
	} else if reliability_is_sequenced(p.reliability) {
		p.order_index = s.send_ordered_index[p.order_channel]
		p.sequence_index = u32(s.send_sequenced_index[p.order_channel])
		s.send_sequenced_index[p.order_channel]++
	}
	max_size := u16(s.mtu_size) - u16(60)
	if p.length > max_size {
		mut buffers := []byte{}
		packet_buffers := p.buffer.str()//string TODO use bytes directly
		mut buffer_count := 0
		mut offset := u16(0)
		for offset < p.length {
			if offset + max_size > p.length {
				buffers << packet_buffers.substr(int(offset), packet_buffers.len - 1).bytes()//push to buffer
			} else {
				buffers << packet_buffers.substr(int(offset), int(offset + max_size)).bytes()
			}
			offset += max_size
			buffer_count++
		}
		split_id := s.split_id % 65536
		for count, buffer in buffers {
			mut encapsulated_packet := EncapsulatedPacket{}
			encapsulated_packet.split_id = u16(split_id)
			encapsulated_packet.has_split = true
			encapsulated_packet.split_count = u32(buffer_count)
			encapsulated_packet.reliability = p.reliability
			encapsulated_packet.split_index = u32(count)//int
			encapsulated_packet.buffer << buffer//byte
			if reliability_is_reliable(p.reliability) {
				encapsulated_packet.message_index = s.message_index
				s.message_index++
			}
			encapsulated_packet.sequence_index = p.sequence_index
			encapsulated_packet.order_channel = p.order_channel
			encapsulated_packet.order_index = p.order_index
			s.add_to_queue(encapsulated_packet, flags | priority_immediate)
		}
	} else {
		if reliability_is_reliable(p.reliability) {
			p.message_index = s.message_index
			s.message_index++
		}
		s.add_to_queue(p, flags)
	}
}

fn (mut s Session) handle_packet(packet Datagram) {
	mut p := packet
	p.decode()
	if u32(p.sequence_number) < s.window_start ||
		u32(p.sequence_number) > s.window_end || p.sequence_number.str() in s.ack_queue {
		// Received duplicate or out-of-window packet
		return
	}
	if p.sequence_number.str() in s.nack_queue {
		s.nack_queue.delete(p.sequence_number.str())
	}
	s.ack_queue[p.sequence_number.str()] = u32(p.sequence_number)
	if s.highest_seq_number < u32(p.sequence_number) {
		s.highest_seq_number = u32(p.sequence_number)
	}
	if u32(p.sequence_number) == s.window_start {
		for {
			if s.window_start.str() in s.ack_queue {
				s.window_end++
				s.window_start++
			} else {
				break
			}
		}
	} else if u32(p.sequence_number) > s.window_start {
		mut i := s.window_start
		for i < u32(p.sequence_number) {
			if !(i.str() in s.ack_queue) {
				s.nack_queue[i.str()] = i
			}
			i++
		}
	} else {
		// received packet before widnow start
		return
	}
	for pp in p.packets {
		s.handle_encapsulated_packet(pp)
	}
}

fn (mut s Session) handle_split(packet EncapsulatedPacket) ?EncapsulatedPacket {
	if packet.split_count >= max_split_size ||
		packet.split_index >= max_split_size {
		return error('Invalid split packet part')
	}
	if !(packet.split_id.str() in s.split_packets) {
		if s.split_packets.len >= max_split_size {
			return error('Invalid split packet part')
		}
		mut tmp := TmpMapEncapsulatedPacket{}
		tmp.m[packet.split_index.str()] = packet
		s.split_packets[packet.split_id.str()] = tmp
	} else {
		mut tmp := s.split_packets[packet.split_id.str()]
		tmp.m[packet.split_index.str()] = packet
	}
	if s.split_packets[packet.split_id.str()].m.len == packet.split_count {
		mut p := EncapsulatedPacket{}
		mut buffer := []byte{}
		p.reliability = packet.reliability
		p.message_index = packet.message_index
		p.sequence_index = packet.sequence_index
		p.order_index = packet.order_index
		p.order_channel = packet.order_channel
		for i in 0 .. (int(packet.split_count)-1) {
			d := s.split_packets[packet.split_id.str()]//vraklib.TmpMapEncapsulatedPacket
			buffer << d.m[i.str()].buffer//vraklib.EncapsulatedPacket.buffer//warning: initialization of 'unsigned char' from 'byteptr' {aka 'unsigned char *'} makes integer from pointer without a cast; note: (near initialization for '(anonymous)[0]')
			//i++
		}
		p.buffer = buffer
		p.length = u16(buffer.len)
		s.split_packets.delete(packet.split_id.str())
		return p
	}
	return error('')
}

fn (mut s Session) handle_encapsulated_packet(packet EncapsulatedPacket) {
	mut p := packet
	if p.message_index != u32(-1) {
		if p.message_index < s.reliable_window_start ||
			p.message_index > s.reliable_window_end || p.message_index.str() in s.reliable_window {
			return
		}
		s.reliable_window[p.message_index.str()] = true
		if p.message_index == s.reliable_window_start {
			for {
				if s.reliable_window_start.str() in s.reliable_window {
					s.reliable_window.delete(s.reliable_window_start.str())
					s.reliable_window_end++
					s.reliable_window_start++
				} else {
					break
				}
			}
		}
	}
	if packet.has_split {
		pp := s.handle_split(packet) or { return }
		p = pp
	}
	if reliability_is_sequenced_or_ordered(packet.reliability) && (packet.order_channel < 0 || packet.order_channel >= channel_count) {
		// Invalid packet
		return
	}
	if reliability_is_sequenced(packet.reliability) {
		if packet.sequence_index < s.receive_sequenced_highest_index[packet.order_channel] ||
			packet.order_index < s.receive_ordered_index[packet.order_channel] {
			// too old sequenced packet
			return
		}
		s.receive_sequenced_highest_index[packet.order_channel] = int(packet.sequence_index + 1)
		s.handle_encapsulated_packet_route(packet)
	} else if reliability_is_ordered(packet.reliability) {
		if packet.order_index == s.receive_ordered_index[packet.order_channel] {
			s.receive_sequenced_highest_index[packet.order_index] = 0
			s.receive_ordered_index[packet.order_channel] = int(packet.order_index + 1)
			s.handle_encapsulated_packet_route(packet)
			mut i := s.receive_ordered_index[packet.order_channel]
			for {
				// d := s.receive_ordered_packets[packet.order_channel]
				// if !d[i] {
				// break
				// }
				dd := s.receive_ordered_packets[packet.order_channel]
				s.handle_encapsulated_packet_route(dd[i])
				s.receive_ordered_packets[packet.order_channel].delete(i)
				i++
			}
			s.receive_ordered_index[packet.order_channel] = i
		} else if packet.order_index > s.receive_ordered_index[packet.order_channel] {
			mut d := s.receive_ordered_packets[packet.order_channel]
			d[packet.order_index] = packet
		} else {
			// duplicate/alredy receive packet
		}
	} else {
		// not ordered or sequenced
		s.handle_encapsulated_packet_route(packet)
	}
}

fn (mut s Session) handle_encapsulated_packet_route(packet EncapsulatedPacket) {
	unsafe {
		pid := packet.buffer[0]
	println('Encapsulated, $pid')
	if pid < id_user_packet_enum {
		if s.state == .connecting {
			if pid == id_connection_request {
				mut connection := ConnectionRequest{
					p: new_packet(packet.buffer, u32(packet.length))
				}
				connection.decode()
				mut accepted := ConnectionRequestAccepted{
					p: new_packet([byte(0)].repeat(96), u32(96))
					request_timestamp: connection.request_timestamp
					accepted_timestamp: u64(s.session_manager.get_raknet_time_ms())
				}
				accepted.encode()
				accepted.p.address = connection.p.address
				s.queue_connected_packet(accepted.p, reliability_unreliable, 0, priority_immediate)
			} else if pid == id_new_incoming_connection {
				mut connection := NewIncomingConnection{
					p: new_packet(packet.buffer, u32(packet.length))
				}
				connection.decode()
				if connection.server_address.port == 19132 || !s.session_manager.port_checking {
					s.state = .connected
					s.is_temporal = false
					s.session_manager.open_session(s)
					s.send_ping(reliability_unreliable)
				}
				println('NEW INCOMING CONNECTION')
			}
		} else if pid == id_connected_ping {
		} else if pid == id_connected_pong {
		}
	} else if s.state == .connected {
		s.session_manager.handle_encapsulated(s, packet)
	} else {
		// Received packet before connection
	}
	}
}
