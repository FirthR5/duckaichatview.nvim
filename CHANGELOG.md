# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-12

First public version.

### Added

- Chat-style view for Duck.ai `.txt` exports, drawn with extmarks on top of
  markview.nvim without modifying the buffer.
- Automatic chat detection from the export header.
- Boilerplate hiding, conversation header, per-turn counters, dates, model
  badges and separators.
- Multi-line prompt blocks with a visual rail.
- Reasoning blocks with `fold`, `hide` and `show` modes.
- Optional per-turn folding.
- Outline integration through an in-process LSP server (outline.nvim).
- `:DuckOpen` picker using Telescope, with a `vim.ui.select` fallback.
- User commands and buffer-local keymaps.

