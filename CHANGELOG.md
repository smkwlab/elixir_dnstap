# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release
- DNSTap protocol support (CLIENT_QUERY, CLIENT_RESPONSE)
- Frame Streams protocol implementation
- File writer
- Unix socket writer
- TCP writer with auto-reconnect
- GenStage pipeline with backpressure control
- OTP supervision tree
- Configuration via Application config

## [0.1.1] - 2026-08-26

### Changed
- Require protobuf `~> 0.17`. GHSA-rv48-qqj5-crxg covers `>= 0.8.0, < 0.16.1`,
  so neither the old `~> 0.15` floor nor the `~> 0.16` that replaced it kept a
  resolution out of the affected range.
- Move the `ex_doc` dev dependency to `~> 0.40`.

## [0.1.0] - 2025-10-09

### Added
- First public release
- Extracted from tenbin_cache DNS proxy server
