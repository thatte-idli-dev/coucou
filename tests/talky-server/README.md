# Talky-Talky Server (Vendored)

This directory contains a **test-only vendored copy** of the Talky-Talky v3 signaling server from the private repository `thatte-idli-dev/Talky-Talky`.

## Status

- **Pinned to git tree**: `de321d4a3b2c81f6c050b5feb3f2afb0dd57e091`
- **Last updated**: 2026-10-09
- **Purpose**: E2E testing of the walkie-talkie protocol implementation
- **Source**: Byte-identical to live production server with one test-only patch

## Test Patch

⚠️ **`service.go` has been patched for local testing** ⚠️

- **Modification**: `validateOrigin()` allows `http://` scheme for `localhost` and `127.0.0.1`
- **Reason**: E2E tests run server locally without TLS
- **Production**: Unchanged - live server enforces HTTPS

## Important Rules

1. Protocol changes must come from the upstream repository
2. To refresh: re-copy the latest files from `thatte-idli-dev/Talky-Talky/server/` and re-apply the test patch
3. This directory is **excluded from all app targets** (test-only)

## Usage

The E2E test builds and runs this server locally:

```bash
cd tests/talky-server
go build -o talky-server .
./talky-server init --config=config.json --origin=https://test.local
./talky-server serve --config=config.json --listen=127.0.0.1:8080
```

Channel access codes are minted via the init command and used to authenticate SSE connections.
