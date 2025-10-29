#!/usr/bin/env python3
"""
Test QUIC Initial packet with proper AEAD construction
Based on RFC 9001 test vectors
"""
import socket
import struct
import hashlib
import hmac
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.backends import default_backend

# QUIC v1 Initial salt from RFC 9001
INITIAL_SALT_V1 = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")

def hkdf_extract(salt, ikm):
    """HKDF-Extract using SHA256"""
    return hmac.new(salt, ikm, hashlib.sha256).digest()

def hkdf_expand_label(secret, label, context, length):
    """HKDF-Expand-Label as per TLS 1.3"""
    hkdf_label = struct.pack('>H', length)
    hkdf_label += bytes([6 + len(label)]) + b'tls13 ' + label.encode()
    hkdf_label += bytes([len(context)]) + context

    hkdf = HKDFExpand(
        algorithm=hashes.SHA256(),
        length=length,
        info=hkdf_label,
        backend=default_backend()
    )
    return hkdf.derive(secret)

def derive_initial_secrets(dcid):
    """Derive Initial secrets from DCID"""
    initial_secret = hkdf_extract(INITIAL_SALT_V1, dcid)

    client_initial = hkdf_expand_label(initial_secret, "client in", b"", 32)
    server_initial = hkdf_expand_label(initial_secret, "server in", b"", 32)

    return client_initial, server_initial

def derive_keys(secret):
    """Derive key, IV, and HP from a secret"""
    key = hkdf_expand_label(secret, "quic key", b"", 16)
    iv = hkdf_expand_label(secret, "quic iv", b"", 12)
    hp = hkdf_expand_label(secret, "quic hp", b"", 16)
    return key, iv, hp

def protect_header(hp_key, sample):
    """Apply header protection using AES-ECB"""
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    cipher = Cipher(algorithms.AES(hp_key), modes.ECB(), backend=default_backend())
    encryptor = cipher.encryptor()
    mask = encryptor.update(sample) + encryptor.finalize()
    return mask[:5]

def build_proper_initial_packet():
    """Build a proper QUIC Initial packet with valid AEAD"""

    # Use a fixed DCID for testing (8 bytes)
    dcid = bytes([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08])

    # Random SCID
    scid = bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    # Derive Initial keys
    client_initial, server_initial = derive_initial_secrets(dcid)
    client_key, client_iv, client_hp = derive_keys(client_initial)

    # Build packet header
    header = bytearray()

    # Flags: 0xC0 = Long header, Initial packet
    # Lower 2 bits will encode PN length - 1 (so 0x00 for 1-byte PN)
    header.append(0xC0)

    # Version (QUIC v1)
    header.extend(struct.pack('>I', 0x00000001))

    # DCID length and value
    header.append(len(dcid))
    header.extend(dcid)

    # SCID length and value
    header.append(len(scid))
    header.extend(scid)

    # Token length (0 for initial client packet)
    header.append(0x00)

    # Build CRYPTO frame with minimal ClientHello
    crypto_frame = bytearray()
    crypto_frame.append(0x06)  # CRYPTO frame type
    crypto_frame.append(0x00)  # Offset (0)

    # Minimal TLS ClientHello
    client_hello = bytearray()
    client_hello.append(0x01)  # HandshakeType: ClientHello

    # Build the ClientHello content first to get the length
    ch_content = bytearray()
    ch_content.extend(b'\x03\x03')  # TLS 1.2
    ch_content.extend(bytes(32))  # Random
    ch_content.append(0x00)  # Session ID length
    ch_content.extend(b'\x00\x02')  # Cipher suites length
    ch_content.extend(b'\x13\x01')  # TLS_AES_128_GCM_SHA256
    ch_content.append(0x01)  # Compression methods length
    ch_content.append(0x00)  # No compression

    # Extensions
    extensions = bytearray()

    # QUIC transport parameters extension (mandatory)
    extensions.extend(b'\xff\xa5')  # QUIC transport params extension (0xffa5 = 65445)
    tp_data = bytearray()
    # Add some minimal transport parameters
    # max_idle_timeout = 0x01, value = 30000ms
    tp_data.extend(b'\x01\x04\x80\x00\x75\x30')
    extensions.extend(struct.pack('>H', len(tp_data)))
    extensions.extend(tp_data)

    ch_content.extend(struct.pack('>H', len(extensions)))
    ch_content.extend(extensions)

    # Now add the length to ClientHello
    client_hello.extend(struct.pack('>I', len(ch_content))[1:])  # 3-byte length
    client_hello.extend(ch_content)

    # Add ClientHello to CRYPTO frame
    crypto_frame.append(len(client_hello))  # Length as varint (assuming < 64 bytes)
    crypto_frame.extend(client_hello)

    # Add PADDING frames to reach minimum size (1200 bytes for Initial)
    padding_needed = 1200 - len(header) - 2 - 1 - 16  # Reserve for length, PN, AEAD tag
    if padding_needed > len(crypto_frame):
        padding_count = padding_needed - len(crypto_frame)
        padding = bytes(padding_count)  # PADDING frames are just 0x00 bytes
        payload = crypto_frame + padding
    else:
        payload = crypto_frame

    # Packet number (starting at 0)
    packet_number = 0
    pn_bytes = bytes([packet_number])

    # Calculate packet length (payload + PN + AEAD tag)
    packet_length = len(payload) + len(pn_bytes) + 16

    # Encode length as varint with 2-byte encoding
    length_bytes = struct.pack('>H', packet_length | 0x4000)
    header.extend(length_bytes)

    # Save header length for AAD
    header_len = len(header)

    # Add packet number
    header.extend(pn_bytes)

    # Create AAD (header bytes)
    aad = bytes(header)

    # Create nonce (IV XOR packet number)
    nonce = bytearray(client_iv)
    # XOR with packet number (right-aligned)
    for i in range(len(pn_bytes)):
        nonce[-(i+1)] ^= pn_bytes[-(i+1)]

    # Encrypt payload
    cipher = AESGCM(client_key)
    ciphertext = cipher.encrypt(bytes(nonce), payload, aad)

    # Combine header and ciphertext
    packet = bytearray(header)
    packet.extend(ciphertext)

    # Apply header protection
    # Sample is first 16 bytes of ciphertext (after any PN bytes, but PN is at end of header)
    sample_offset = header_len  # Start of ciphertext
    sample = bytes(packet[sample_offset:sample_offset + 16])

    # Generate mask
    mask = protect_header(client_hp, sample)

    # Apply mask to first byte (preserving top bits)
    packet[0] = (packet[0] & 0xF0) | ((packet[0] ^ mask[0]) & 0x0F)

    # Apply mask to packet number
    pn_offset = header_len - len(pn_bytes)
    for i in range(len(pn_bytes)):
        packet[pn_offset + i] ^= mask[1 + i]

    return bytes(packet)

def test_quic_server():
    """Send a proper QUIC Initial packet to the server"""
    print("Testing QUIC server at localhost:7567 with proper Initial packet...")

    # Create UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)

    # Build and send Initial packet
    packet = build_proper_initial_packet()
    print(f"Sending {len(packet)} byte Initial packet")
    print(f"First 32 bytes (hex): {packet[:32].hex()}")

    try:
        sock.sendto(packet, ('localhost', 7567))
        print("Packet sent, waiting for response...")

        # Try to receive response
        data, addr = sock.recvfrom(4096)
        print(f"Received {len(data)} bytes from {addr}")

        # Check if it's a QUIC packet
        if len(data) > 0:
            first_byte = data[0]
            if first_byte & 0x80:
                print("Received long header QUIC packet")
                packet_type = (first_byte & 0x30) >> 4
                types = ["Initial", "0-RTT", "Handshake", "Retry"]
                print(f"Packet type: {types[packet_type] if packet_type < 4 else 'Unknown'}")
            else:
                print("Received short header QUIC packet")

            print(f"First 32 bytes (hex): {data[:32].hex()}")

    except socket.timeout:
        print("No response received (timeout)")
    except Exception as e:
        print(f"Error: {e}")
    finally:
        sock.close()

if __name__ == "__main__":
    test_quic_server()