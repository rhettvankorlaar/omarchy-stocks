# Stocks for Omarchy

A small stocks app for the Omarchy bar. The bar shows the selected ticker's
last price and day change; clicking it opens a two-pane panel with searchable
watchlists on the left and a chart, range selector and key stats on the right.

Quotes, charts and search come from Yahoo Finance. No API key.

![Stocks panel](preview.png)

## Requirements

- Omarchy Quattro.
- `curl` for quotes, charts and search.
- `xdg-open` for the TradingView link.
- Network access to Yahoo Finance.

## Install

```sh
omarchy plugin add https://github.com/alvmarrod/omarchy-stocks.git --enable
```

The widget lands in the bar's center section. Move it with:

```sh
omarchy bar move io.github.alvmarrod.stocks --section right
```

Then click the bar label to open the app.

## Use

- Type a symbol or company name in the search field to add a ticker. Enter
  adds the first match; a plain symbol such as `AAPL` or `BTC-USD` also works.
- Click a ticker to show it in the detail pane and the bar.
- `+` creates a watchlist. `Rename` and `Delete` manage the current one. The
  last watchlist cannot be deleted.
- The `×` on a ticker removes it, after which the next ticker is selected.
- Range chips (1D/5D/1M/6M/1Y) and the currency chip are saved with the rest
  of the app state.
- Type how many shares you own in **Shares owned** under the chart (or
  press `s`); Enter saves, an empty value or `0` clears it. Decimals with a
  dot or comma work. The sidebar then shows the watchlist's **Portfolio**
  value and today's change, and each ticker row shows `10 sh · value`.
  Holdings are per symbol, so the same ticker in two watchlists shares one
  amount. Totals use the display currency, or the currency most of your
  value is in when set to Native.
- Clicking `Open on TradingView ↗` opens the selected symbol's TradingView page.

Drag between two points on the detail chart to measure the price change and
percentage gain or loss over that interval. The highlighted area is green for
a gain and red for a loss. Dragging in either direction compares the earlier
price with the later price. Release to keep the measurement; click the chart
to clear it. Changing ticker, range or currency clears the selection.

Keyboard: `/` focuses search, `j`/`k` move the selection, `Delete` removes
the selected ticker, `n` creates a watchlist, `r` renames it, `D` twice
deletes it, `[`/`]` switch watchlists, `,`/`.` change the chart range, and
`c` cycles the display currency, and `s` edits the shares you own. `Esc` clears search first, then closes the
panel.

Useful commands:

```sh
omarchy-shell io.github.alvmarrod.stocks toggle
omarchy-shell io.github.alvmarrod.stocks refresh
```

## Remove

```sh
omarchy plugin remove io.github.alvmarrod.stocks --yes
```

To also delete your watchlists and preferences:

```sh
rm -rf ~/.local/state/omarchy/stocks
```

## State

Watchlists, the selected symbol, chart range and display currency live in:

```
~/.local/state/omarchy/stocks/state.json
```

It is created on first run, mode 0600, and written atomically. No symbols are
added by default.

## Develop

```sh
node --test test/*.test.js
qmllint -I /usr/share/omarchy/shell Panel.qml
qmllint -I /usr/share/omarchy/shell BarWidget.qml
omarchy plugin validate "$PWD"
```

To test changes in the running shell, sync into the installed plugin and
restart:

```sh
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/io.github.alvmarrod.stocks/
omarchy restart shell
```

The pure `Model.js`, `Store.js` and `Search.js` modules are covered by Node
tests. `Screen.js` is the momentum screen from an earlier design and is kept
dormant; it does not run in this version.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See `LICENSE`.
