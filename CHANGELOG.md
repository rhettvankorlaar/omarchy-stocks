# Changelog

All notable changes to this plugin are documented here.

## [1.3.0] - 2026-11-12

### Added

- Portfolio tracking: enter how many shares you own of a ticker in the "Shares owned" field of the detail pane (or press `s`). The sidebar shows the watchlist's total portfolio value and today's change, and each row shows the holding and its value.
- Mixed-currency holdings are converted into the display currency, or else into the currency most of the value is in (London pence handled).

## [1.2.2] - 2026-11-07

### Fixed

- Validate chart timestamps against the requested range and derive 1D grid ticks from the received samples, so a tiny malicious response cannot amplify into millions of axis ticks.

## [1.2.1] - 2026-11-07

### Fixed

- Cap external responses at 1 MiB (`--max-filesize` plus a streamed `head -c`) and limit multi-symbol quote fetches to 30 symbols, so a compromised or oversized response cannot buffer unbounded data in the shell.
- Selecting a symbol that was not part of the last fetch now refreshes it immediately with the selected symbol prioritized.

### Changed

- Watchlists are limited to 30 symbols; adding a 31st shows a warning and is rejected.

## [1.2.0] - 2026-11-07

### Added

- Drag across the detail chart to measure chronological price and percentage changes, with gain/loss shading and endpoint prices and dates. Click to clear the selection.

## [1.1.0] - 2026-11-07

### Added

- Watchlist sparklines show the previous close as a dotted line across the full width, tinted like the surrounding text.
- Detail chart grid with hour/session guides for intraday ranges, evenly spaced guides for longer ranges, and horizontal guides scaled to the visible price range. Axis labels now sit on each guide.

### Fixed

- Intraday charts (1D/5D and watchlist sparklines) now grow from the session open and leave the rest of the session blank, instead of stretching a partial day across the whole width.
- Charts plot one x-slot per bar, so overnight, weekend and holiday gaps no longer widen the plot or draw long straight close-to-open lines.

## [1.0.0] - 2026-11-05

### Added

- Two-pane Stocks panel with ticker search, watchlists and a selected-ticker detail view.
- Yahoo Finance symbol search with debounced results and duplicate prevention.
- Watchlist creation, renaming, switching and deletion; the last watchlist is protected.
- Ticker add/remove, sparkline, price and previous-close change badge.
- 1D/5D/1M/6M/1Y charts, currency conversion and key quote statistics.
- Compact bar widget showing the selected ticker's price and daily change.
- Persistent watchlists and preferences in `~/.local/state/omarchy/stocks/state.json`.
- Keyboard controls for search, selection, watchlists, ranges and currency.
