# Transparent Data Encryption (TDE)

- Enable: export GEODE_DISK_ENCRYPTION=on; export GEODE_DISK_KEY_HEX=<64 hex chars>; optional GEODE_WAL_ENCRYPTION=on
- Keys: 256-bit hex; rotation via `key_rotate` tool (prints `export GEODE_DISK_KEY_HEX=...`). Full re-encryption planned.
- Pages: PageManager encrypts on write and decrypts on load; checksum covers plaintext.
- WAL: Payload bytes encrypted per record LSN; recovery decrypts before applying.
- Permissions: data and WAL files created with mode 0600
- Tests: `zig test tests/unit_page_crypto.zig`.
