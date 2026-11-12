import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Store.js" as Store
import "Search.js" as Search
import "Selection.js" as Selection
import "Portfolio.js" as Portfolio

// Stocks app: a two-pane popup. The sidebar owns search + watchlists, the
// detail pane shows the selected ticker. This file also owns the quote state
// so the compact bar widget can read the selected quote while closed.
Panel {
  id: root
  moduleName: "io.github.alvmarrod.stocks"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Persistent state ---------------------------------------------------
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/stocks"
  readonly property string statePath: stateDir + "/state.json"
  property bool storeReady: false
  property bool stateLoaded: false
  property var store: Store.emptyState()

  readonly property var activeList: Store.activeWatchlist(store)
  readonly property var symbols: Store.activeSymbols(store)
  readonly property string symbolsKey: symbols.join(",")
  readonly property string selectedSymbol: String(store.selectedSymbol || "")
  readonly property string activeRange: Store.normalizeRange(store.chartRange)
  readonly property string displayCurrency: Store.normalizeCurrency(store.currency)
  readonly property var holdings: store.holdings || ({})

  // ---- Quotes, chart and FX ----------------------------------------------
  property var quotes: []
  property var fetchRequested: []
  property bool fetchPending: false
  property var chartSeries: ({})
  property real chartSeriesEnd: 0
  property string chartSeriesRange: ""
  property string chartRequestedSymbol: ""
  property string chartRequestedRange: ""
  property bool chartLoading: false
  property var rates: ({})
  property var ratesRequested: []
  property int ratesRetries: 0
  property bool ratesPending: false
  property string fetchError: ""
  property double lastUpdated: 0
  property int retries: 0

  readonly property string userAgent: "Mozilla/5.0 (X11; Linux x86_64) omarchy-stocks/1.3.0"
  readonly property bool loading: quotes.length === 0 && fetchError === ""
  readonly property var shownQuotes: Model.convertAll(quotes, displayCurrency, rates)

  function quoteFor(symbol) {
    var list = root.shownQuotes
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].symbol) === symbol) return list[i]
    }
    return null
  }

  readonly property var selectedQuote: root.selectedSymbol !== "" ? root.quoteFor(root.selectedSymbol) : null
  readonly property var detailQuote: root.selectedQuote
    ? root.selectedQuote
    : Model.emptyQuote(root.selectedSymbol)
  readonly property var detailSeries: root.seriesFor(root.selectedQuote)

  // ---- Portfolio ----------------------------------------------------------
  // Totals use the raw native-currency quotes so Portfolio.js can pick one
  // currency (the display currency, or the one most of the value is in).
  readonly property var portfolio: Portfolio.summary(root.symbols, root.holdings, root.quotes, root.displayCurrency, root.rates)
  readonly property string portfolioRateKey: Portfolio.ratePairs(root.symbols, root.holdings, root.quotes, root.portfolio.currency).join(",")
  readonly property real selectedHolding: Store.holdingFor(root.store, root.selectedSymbol)
  readonly property var selectedPosition: root.positionFor(root.selectedSymbol)
  property string holdingEditSymbol: ""
  property string holdingError: ""

  // Value of one holding in its own (major) currency, or the display currency.
  function positionFor(symbol) {
    if (symbol === "" || Store.holdingFor(root.store, symbol) <= 0) return null
    var single = Portfolio.summary([symbol], root.holdings, root.quotes, root.displayCurrency, root.rates)
    return single.count ? single : null
  }

  function positionLabel(symbol) {
    var amount = Store.holdingFor(root.store, symbol)
    if (amount <= 0) return symbol
    var pos = root.positionFor(symbol)
    var label = symbol + " · " + Portfolio.formatAmount(amount) + " sh"
    if (pos && pos.value !== null) label += " · " + Portfolio.formatMoney(pos.value, pos.currency)
    return label
  }

  function beginHoldingEdit() {
    root.holdingEditSymbol = root.selectedSymbol
    root.holdingError = ""
  }

  function commitHolding(text) {
    var symbol = root.holdingEditSymbol || root.selectedSymbol
    root.holdingEditSymbol = ""
    if (symbol === "") return
    var amount = Portfolio.parseAmount(text)
    if (amount === null) {
      root.holdingError = "Enter a number, e.g. 12 or 2.5"
      root.syncHoldingField(true)
      return
    }
    root.holdingError = ""
    root.commit(Store.setHolding(root.store, symbol, amount))
    root.syncHoldingField(true)
  }

  function cancelHoldingEdit() {
    root.holdingEditSymbol = ""
    root.holdingError = ""
    root.syncHoldingField(true)
    keyCatcher.forceActiveFocus()
  }

  function syncHoldingField(force) {
    if (!force && holdingField.activeFocus) return
    holdingField.text = Portfolio.editableAmount(Store.holdingFor(root.store, root.selectedSymbol))
  }

  onStoreChanged: root.syncHoldingField(false)
  onPortfolioRateKeyChanged: root.ensureRates()

  // Sidebar rows exist as soon as a symbol is added; quotes fill in after.
  readonly property var listRows: {
    var bySymbol = {}
    var list = root.shownQuotes
    for (var i = 0; i < list.length; i++) bySymbol[list[i].symbol] = list[i]
    var out = []
    for (var j = 0; j < root.symbols.length; j++) {
      out.push(bySymbol[root.symbols[j]] || Model.emptyQuote(root.symbols[j]))
    }
    return out
  }

  // The panel only needs to be as tall as its tallest pane. The detail pane is
  // effectively fixed once a ticker is selected; the sidebar grows with the
  // watchlist and scrolls past the cap. 320 keeps an empty app panel-sized.
  readonly property real sidebarRequiredHeight: Style.space(20)
    + searchField.height + Style.space(10)
    + sideHeader.implicitHeight + Style.space(6)
    + tickerColumn.implicitHeight
  readonly property real detailRequiredHeight: Style.space(28)
    + (root.selectedSymbol === "" ? emptyDetail.implicitHeight : detailColumn.implicitHeight)
  readonly property real panelContentHeight: Math.max(Style.space(320),
    root.sidebarRequiredHeight, root.detailRequiredHeight)

  // ---- Bar widget contract ------------------------------------------------
  readonly property var barQuote: root.selectedQuote
  readonly property bool barDown: Model.isDown(root.barQuote)
  readonly property bool barUp: Model.isUp(root.barQuote)
  readonly property string barSymbol: root.selectedSymbol !== "" ? root.selectedSymbol : "Stocks"
  readonly property string barPrice: Model.isValid(root.barQuote) ? Model.formatPrice(root.barQuote.price) : ""
  readonly property string barChange: {
    if (!Model.isValid(root.barQuote)) return ""
    var pct = Model.formatPercent(root.barQuote.changePct)
    return pct ? Model.arrowFor(root.barQuote.change) + pct : ""
  }

  // ---- Presentation helpers ----------------------------------------------
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(barForeground, 1.5)
  readonly property color urgentForeground: bar ? bar.urgent : Color.urgent
  property string themeGreen: ""
  property string themeRed: ""
  readonly property color upColor: themeGreen !== "" ? themeGreen : "#5fbf6f"
  readonly property color downColor: themeRed !== "" ? themeRed : urgentForeground

  function trendColor(quote) {
    if (Model.isDown(quote)) return root.downColor
    if (Model.isUp(quote)) return root.upColor
    return root.barForeground
  }

  function signedColor(value) {
    if (value === null || value === undefined) return root.mutedForeground
    if (value < 0) return root.downColor
    if (value > 0) return root.upColor
    return root.mutedForeground
  }

  // ---- State edits --------------------------------------------------------
  function commit(next) {
    if (!next || next === root.store) return
    root.store = next
    root.saveState()
  }

  function saveState() {
    if (!root.storeReady || !root.stateLoaded) return
    stateFile.setText(Store.serializeState(root.store))
  }

  function loadState(text) {
    var raw = String(text || "")
    var parsed = Store.parseState(raw)
    root.store = parsed
    root.stateLoaded = true
    // Repair malformed/empty state once, keeping the file the source of truth.
    if (Store.serializeState(parsed) !== raw) Qt.callLater(root.saveState)
    if (root.opened) Qt.callLater(function() { root.ensureChartSeries(true) })
  }

  function cycleWatchlist(step) {
    var lists = root.store.watchlists
    if (lists.length < 2) return
    var index = 0
    for (var i = 0; i < lists.length; i++) {
      if (lists[i].id === root.store.activeWatchlist) index = i
    }
    var next = lists[(index + step + lists.length) % lists.length]
    root.commit(Store.setActiveWatchlist(root.store, next.id))
  }

  function createWatchlist(name) {
    root.commit(Store.addWatchlist(root.store, name))
    root.cancelEditor()
  }

  function renameCurrentWatchlist(name) {
    if (!root.activeList) return
    root.commit(Store.renameWatchlist(root.store, root.activeList.id, name))
    root.cancelEditor()
  }

  function deleteCurrentWatchlist() {
    if (root.store.watchlists.length <= 1) return
    root.commit(Store.deleteWatchlist(root.store, root.store.activeWatchlist))
    root.confirmingDelete = false
  }

  function startCreate() {
    root.addingWatchlist = true
    root.renamingWatchlist = false
    root.nameDraft = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function startRename() {
    if (!root.activeList) return
    root.addingWatchlist = false
    root.renamingWatchlist = true
    root.nameDraft = root.activeList.name
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function cancelEditor() {
    root.addingWatchlist = false
    root.renamingWatchlist = false
    root.nameDraft = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitEditor() {
    var value = root.nameDraft.trim()
    if (root.addingWatchlist) root.createWatchlist(value)
    else if (root.renamingWatchlist) {
      if (value !== "") root.renameCurrentWatchlist(value)
      else root.cancelEditor()
    }
  }

  function selectSymbol(symbol) {
    root.commit(Store.selectSymbol(root.store, symbol))
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeSymbol(symbol) {
    root.commit(Store.removeSymbol(root.store, symbol))
  }

  function moveSelection(step) {
    var list = root.symbols
    if (list.length === 0) return
    var index = list.indexOf(root.selectedSymbol)
    if (index === -1) index = 0
    var next = (index + step + list.length) % list.length
    root.selectSymbol(list[next])
  }

  function cycleRange(step) {
    var index = Model.CHART_RANGES.indexOf(root.activeRange)
    if (index === -1) index = 0
    var next = (index + step + Model.CHART_RANGES.length) % Model.CHART_RANGES.length
    root.selectRange(Model.CHART_RANGES[next])
  }

  // ---- Search -------------------------------------------------------------
  property string searchText: ""
  property var searchResults: []
  property string searchError: ""
  property bool searching: false
  property string searchRequested: ""
  property bool addingWatchlist: false
  property bool renamingWatchlist: false
  property bool confirmingDelete: false
  property string nameDraft: ""

  function handleSearchText() {
    root.searchError = ""
    if (root.searchText.trim() === "") {
      root.searchResults = []
      root.searching = false
      searchTimer.stop()
      if (searchProc.running) searchProc.running = false
      return
    }
    root.searchResults = []
    root.searching = true
    searchTimer.restart()
  }

  function startSearch() {
    var query = root.searchText.trim()
    if (query === "") return
    if (searchProc.running) searchProc.running = false
    root.searchRequested = query
    root.searching = true
    searchProc.command = Search.searchCommand(query, root.userAgent)
    searchProc.running = true
  }

  function handleSearchOutput(text) {
    if (root.searchRequested !== root.searchText.trim()) return
    root.searching = false
    var raw = String(text || "")
    if (raw.trim() === "") {
      root.searchResults = []
      root.searchError = "No response from Yahoo Finance"
      return
    }
    var rows = Search.parseSearch(raw)
    root.searchResults = rows
    root.searchError = rows.length ? "" : "No matches"
  }

  function clearSearch() {
    root.searchText = ""
    searchField.text = ""
    root.searchResults = []
    root.searchError = ""
    root.searching = false
    searchTimer.stop()
    if (searchProc.running) searchProc.running = false
  }

  function addSymbol(symbol) {
    var value = Model.normalizeSymbols([symbol], [])[0]
    if (!value) return false
    if (root.symbols.indexOf(value) === -1 && root.symbols.length >= Store.MAX_SYMBOLS) {
      root.searchError = "Watchlist limit is " + Store.MAX_SYMBOLS + " symbols"
      return false
    }
    root.commit(Store.addSymbol(root.store, value))
    root.clearSearch()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    return true
  }

  function addResult(result) {
    if (!result || !result.symbol) return
    root.addSymbol(result.symbol)
  }

  function submitSearch() {
    if (root.searchResults.length > 0) {
      root.addResult(root.searchResults[0])
      return
    }
    var raw = root.searchText.trim().toUpperCase()
    if (/^[A-Z0-9.^=-]+$/.test(raw)) root.addSymbol(raw)
  }

  // ---- Fetching -----------------------------------------------------------
  function refresh() {
    root.retries = 0
    root.startFetch()
    root.ensureChartSeries(true)
  }

  function startFetch() {
    if (fetchProc.running) return
    var requested = Model.fetchSymbols(root.symbols, root.selectedSymbol)
    if (requested.length === 0) {
      root.quotes = []
      return
    }
    root.fetchRequested = requested
    fetchProc.command = Model.curlCommand(requested, root.userAgent, "1d")
    fetchProc.running = true
  }

  function handleFetchOutput(text) {
    var raw = String(text || "")
    if (raw.replace(/\s+/g, "") === "") {
      root.fetchError = "No response from Yahoo Finance"
      root.scheduleRetry()
      return
    }
    var requested = root.fetchRequested.length > 0 ? root.fetchRequested : root.symbols
    var parsed = Model.parseQuoteLines(raw, requested, "1d")
    root.quotes = parsed
    if (Model.validCount(parsed) === 0) {
      root.fetchError = "No data from Yahoo Finance"
      root.scheduleRetry()
      return
    }
    root.fetchError = ""
    root.lastUpdated = Date.now()
    root.retries = 0
    root.ensureRates()
  }

  function ensureRates() {
    var pairs = Model.ratePairs(root.quotes, root.displayCurrency)
    if (ratesProc.running) {
      root.ratesPending = true
      return
    }
    var held = Portfolio.ratePairs(root.symbols, root.holdings, root.quotes, root.portfolio.currency)
    for (var h = 0; h < held.length; h++) {
      if (pairs.indexOf(held[h]) === -1 && root.rates[held[h]] === undefined) pairs.push(held[h])
    }
    if (!pairs.length || ratesProc.running) return
    root.ratesRequested = pairs
    ratesProc.command = Model.curlCommand(pairs, root.userAgent, "1d")
    ratesProc.running = true
  }

  function handleRatesOutput(text) {
    var raw = String(text || "")
    var fresh = raw.replace(/\s+/g, "") === "" ? {} : Model.parseRateLines(raw, root.ratesRequested)
    var missing = false
    for (var i = 0; i < root.ratesRequested.length; i++) {
      if (fresh[root.ratesRequested[i]] === undefined) missing = true
    }
    if (missing && root.ratesRetries < 3) {
      root.ratesRetries++
      ratesRetryTimer.restart()
    } else {
      root.ratesRetries = 0
    }
    var merged = {}
    for (var k in root.rates) merged[k] = root.rates[k]
    for (var f in fresh) merged[f] = fresh[f]
    root.rates = merged
  }

  function scheduleRetry() {
    if (root.retries >= 3) return
    root.retries++
    retryTimer.restart()
  }

  // ---- Range chart --------------------------------------------------------
  function ensureChartSeries(force) {
    if (root.activeRange === "1d" || root.selectedSymbol === "") return
    if (!force && root.chartSeriesRange === root.activeRange
        && (root.chartSeries[root.selectedSymbol] || []).length > 0) return
    root.startChartFetch()
  }

  function startChartFetch() {
    if (chartProc.running) return
    if (root.selectedSymbol === "" || root.activeRange === "1d") return
    root.chartRequestedSymbol = root.selectedSymbol
    root.chartRequestedRange = root.activeRange
    root.chartLoading = true
    chartProc.command = Model.curlCommand([root.selectedSymbol], root.userAgent, root.activeRange)
    chartProc.running = true
  }

  function handleChartOutput(text) {
    root.chartLoading = false
    var raw = String(text || "")
    if (raw.replace(/\s+/g, "") === "") return
    var parsed = Model.parseSeriesLines(raw, [root.chartRequestedSymbol], root.chartRequestedRange)
    root.chartSeries = parsed.series
    root.chartSeriesEnd = parsed.ends[root.chartRequestedSymbol] || 0
    root.chartSeriesRange = root.chartRequestedRange
    // The selection or range changed while this response was in flight.
    if (root.chartRequestedRange !== root.activeRange || root.chartRequestedSymbol !== root.selectedSymbol)
      Qt.callLater(function() { root.ensureChartSeries(true) })
  }

  function seriesFor(quote) {
    if (!quote) return []
    if (root.activeRange === "1d") return quote.series || []
    var raw = root.chartSeries[quote.symbol] || []
    return Model.convertSeries(raw, Model.rateFor(quote.nativeCurrency || quote.currency, root.displayCurrency, root.rates))
  }

  // Session close used as the chart's right edge while intraday data is partial.
  function chartEndFor(quote) {
    if (!quote) return 0
    if (root.activeRange === "1d") return quote.sessionEnd || 0
    if (root.activeRange === "5d") return root.chartSeriesEnd
    return 0
  }

  function selectRange(range) {
    root.commit(Store.setChartRange(root.store, range))
  }

  function selectCurrency(step) {
    var next = Model.currencyCycle(root.displayCurrency, Model.DEFAULT_CURRENCIES, step)
    root.commit(Store.setCurrency(root.store, next))
  }

  function currencyLabel(quote) {
    if (!quote) return ""
    if (quote.converted) return quote.nativeCurrency + " → " + quote.currency
    return quote.currency
  }

  function rangeLabel(range) {
    return { "1d": "1D", "5d": "5D", "1mo": "1M", "6mo": "6M", "1y": "1Y" }[range] || range
  }

  function formatStamp(ts, range) {
    if (ts === null || ts === undefined) return ""
    var date = new Date(ts * 1000)
    return Qt.formatDateTime(date, range === "1d" ? "HH:mm" : (range === "5d" ? "ddd HH:mm" : "d MMM"))
  }

  function openTradingView(symbol) {
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("xdg-open " + Model.shellQuote(Model.tradingViewUrl(symbol)))
  }

  // ---- Lifecycle ----------------------------------------------------------
  function open() {
    root.controller.show()
    root.refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onSymbolsKeyChanged: {
    root.quotes = []
    root.fetchRequested = []
    root.fetchPending = false
    root.chartSeries = {}
    root.chartSeriesEnd = 0
    root.chartSeriesRange = ""
    root.fetchError = ""
    root.lastUpdated = 0
    root.retries = 0
    if (fetchProc.running) fetchProc.running = false
    if (chartProc.running) chartProc.running = false
    Qt.callLater(root.startFetch)
    if (root.opened) Qt.callLater(function() { root.ensureChartSeries(true) })
  }

  onSelectedSymbolChanged: {
    root.holdingError = ""
    root.syncHoldingField(true)
    root.chartSeries = {}
    root.chartSeriesEnd = 0
    root.chartSeriesRange = ""
    if (root.opened) Qt.callLater(function() { root.ensureChartSeries(true) })
    if (root.selectedSymbol !== "" && root.quoteFor(root.selectedSymbol) === null) {
      if (fetchProc.running) root.fetchPending = true
      else Qt.callLater(root.startFetch)
    }
  }

  onActiveRangeChanged: if (root.opened) root.ensureChartSeries(true)
  onDisplayCurrencyChanged: {
    if (ratesProc.running) ratesProc.running = false
    root.ensureRates()
  }

  Component.onCompleted: statePrepare.running = true

  // ---- Processes ----------------------------------------------------------
  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFetchOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").split("\n")[0].replace(/^curl:\s*\(\d+\)\s*/, "").trim()
        if (message !== "" && root.fetchError !== "" && root.quotes.length === 0) root.fetchError = message
      }
    }
    onExited: {
      if (root.fetchPending) {
        root.fetchPending = false
        Qt.callLater(root.startFetch)
      }
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSearchOutput(text)
    }
  }

  Process {
    id: chartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleChartOutput(text)
    }
  }

  Process {
    id: ratesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRatesOutput(text)
    }
    onExited: {
      if (root.ratesPending) {
        root.ratesPending = false
        Qt.callLater(root.ensureRates)
      }
    }
  }

  // Directory and file exist before FileView binds; 0700/0600 because this is
  // private user data, and an atomic write keeps the mode.
  Process {
    id: statePrepare
    command: ["bash", "-c",
      "umask 077\n" +
      "dir=$1\n" +
      "mkdir -p -- \"$dir\" && chmod 700 -- \"$dir\" || exit 1\n" +
      "file=$dir/state.json\n" +
      "if [[ -L $file ]]; then rm -f -- \"$file\"; fi\n" +
      "if [[ -f $file ]]; then chmod 600 -- \"$file\"; elif [[ ! -e $file ]]; then : >\"$file\"; fi\n",
      "omarchy-stocks-state", root.stateDir]
    onExited: function(code) { root.storeReady = code === 0 }
  }

  FileView {
    id: stateFile
    path: root.storeReady ? root.statePath : ""
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: if (root.storeReady) root.loadState("")
  }

  Timer {
    id: searchTimer
    interval: 350
    onTriggered: root.startSearch()
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.startFetch()
  }

  Timer {
    id: ratesRetryTimer
    interval: 2500
    onTriggered: root.ensureRates()
  }

  Timer {
    id: deleteTimer
    interval: 3000
    onTriggered: root.confirmingDelete = false
  }

  Timer {
    id: refreshTimer
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: if (root.symbols.length > 0) root.refresh()
  }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.themeGreen = Model.parseThemeColor(text(), "green")
      root.themeRed = Model.parseThemeColor(text(), "red")
    }
    onLoadFailed: {
      root.themeGreen = ""
      root.themeRed = ""
    }
  }

  // ---- Chart sparkline / line --------------------------------------------
  component SeriesCanvas: Canvas {
    id: canvas
    property var series: []
    property color lineColor: "white"
    property real lineWidth: 1.5
    property real pad: 2
    property bool fill: false
    property var referenceValue: null
    property color referenceColor: lineColor
    property var boundsValue: null
    property real endTime: 0
    property real interval: 0
    property bool grid: false
    property color gridColor: "white"
    property string range: ""

    onSeriesChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onReferenceValueChanged: requestPaint()
    onReferenceColorChanged: requestPaint()
    onBoundsValueChanged: requestPaint()
    onEndTimeChanged: requestPaint()
    onIntervalChanged: requestPaint()
    onGridColorChanged: requestPaint()
    onRangeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = Model.seriesPoints(canvas.series, canvas.width, canvas.height, canvas.pad, canvas.endTime, canvas.boundsValue, canvas.interval)
      if (pts.length < 2) return

      if (canvas.grid) {
        var bounds = Model.seriesBounds(canvas.series, canvas.boundsValue)
        ctx.strokeStyle = Qt.rgba(canvas.gridColor.r, canvas.gridColor.g, canvas.gridColor.b, 0.18)
        ctx.lineWidth = 1
        ctx.setLineDash([3, 3])
        var ticks = Model.chartTimeTicks(canvas.series, canvas.range, canvas.endTime, canvas.interval)
        for (var gx = 0; gx < ticks.length; gx++) {
          var x = canvas.pad + ticks[gx].fraction * (canvas.width - canvas.pad * 2)
          ctx.beginPath()
          ctx.moveTo(x, canvas.pad)
          ctx.lineTo(x, canvas.height - canvas.pad)
          ctx.stroke()
        }
        for (var gy = 1; gy <= 3; gy++) {
          var y = Model.valueToY(bounds.min + (bounds.max - bounds.min) * gy / 4, bounds, canvas.height, canvas.pad)
          ctx.beginPath()
          ctx.moveTo(canvas.pad, y)
          ctx.lineTo(canvas.width - canvas.pad, y)
          ctx.stroke()
        }
        ctx.setLineDash([])
      }

      if (canvas.fill) {
        var gradient = ctx.createLinearGradient(0, 0, 0, canvas.height)
        gradient.addColorStop(0, Qt.rgba(canvas.lineColor.r, canvas.lineColor.g, canvas.lineColor.b, 0.28))
        gradient.addColorStop(1, Qt.rgba(canvas.lineColor.r, canvas.lineColor.g, canvas.lineColor.b, 0.0))
        ctx.fillStyle = gradient
        ctx.beginPath()
        ctx.moveTo(pts[0].x, canvas.height)
        for (var f = 0; f < pts.length; f++) ctx.lineTo(pts[f].x, pts[f].y)
        ctx.lineTo(pts[pts.length - 1].x, canvas.height)
        ctx.closePath()
        ctx.fill()
      }

      var refY = Model.valueToY(canvas.referenceValue, Model.seriesBounds(canvas.series, canvas.boundsValue), canvas.height, canvas.pad)
      if (refY !== null) {
        ctx.strokeStyle = Qt.rgba(canvas.referenceColor.r, canvas.referenceColor.g, canvas.referenceColor.b, 0.55)
        ctx.lineWidth = 1
        ctx.setLineDash([3, 3])
        ctx.beginPath()
        ctx.moveTo(canvas.pad, refY)
        ctx.lineTo(canvas.width - canvas.pad, refY)
        ctx.stroke()
        ctx.setLineDash([])
      }

      ctx.strokeStyle = canvas.lineColor
      ctx.lineWidth = canvas.lineWidth
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(pts[0].x, pts[0].y)
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
      ctx.stroke()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(960), Style.space(1180))
    contentHeight: panel.fittedContentHeight(root.panelContentHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || nameField.activeFocus || holdingField.activeFocus
      onCloseRequested: root.close()
      onReturnRequested: root.refresh()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onDeleteRequested: if (root.selectedSymbol !== "") root.removeSymbol(root.selectedSymbol)
      onTextKey: function(text, modifiers) {
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        if (text === "/") searchField.forceActiveFocus()
        else if (text === "n") root.startCreate()
        else if (text === "r") root.startRename()
        else if (text === "D") {
          if (root.confirmingDelete) {
            deleteTimer.stop()
            root.deleteCurrentWatchlist()
          } else {
            root.confirmingDelete = true
            deleteTimer.restart()
          }
        }
        else if (text === "c") root.selectCurrency(1)
        else if (text === "s" && root.selectedSymbol !== "") holdingField.forceActiveFocus()
        else if (text === "[") root.cycleWatchlist(-1)
        else if (text === "]") root.cycleWatchlist(1)
        else if (text === ",") root.cycleRange(-1)
        else if (text === ".") root.cycleRange(1)
      }

      Item {
        width: parent.width
        height: parent.height

        Row {
          anchors.fill: parent
          spacing: 0

          // =============================================================
          // Sidebar: search, watchlist controls, tickers.
          // =============================================================
          Item {
            id: sidebar
            width: Math.min(Style.space(330), parent.width * 0.42)
            height: parent.height

            Item {
              anchors.fill: parent
              anchors.margins: Style.space(10)

              TextField {
                id: searchField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Style.spacing.controlHeight
                placeholderText: "Search symbol or company"
                foreground: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: {
                  root.searchText = text
                  root.handleSearchText()
                }
                onAccepted: root.submitSearch()
                Keys.onEscapePressed: function(event) {
                  if (root.searchText !== "") root.clearSearch()
                  else root.close()
                  event.accepted = true
                }
                Keys.onDownPressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }

              Column {
                id: sideHeader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: searchField.bottom
                anchors.topMargin: Style.space(10)
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  height: Style.space(26)

                  Text {
                    textFormat: Text.PlainText
                    id: watchlistName
                    anchors.left: parent.left
                    anchors.right: prevWatchlist.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.activeList ? root.activeList.name : ""
                    elide: Text.ElideRight
                    color: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Button {
                    id: prevWatchlist
                    anchors.right: nextWatchlist.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: Style.space(22)
                    text: "‹"
                    fontSize: Style.font.body
                    foreground: root.barForeground
                    horizontalPadding: 0
                    verticalPadding: 0
                    enabled: root.store.watchlists.length > 1
                    opacity: enabled ? 1 : 0.4
                    tooltipText: "Previous watchlist"
                    onClicked: root.cycleWatchlist(-1)
                  }

                  Button {
                    id: nextWatchlist
                    anchors.right: addWatchlistButton.left
                    anchors.rightMargin: Style.space(2)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: Style.space(22)
                    text: "›"
                    fontSize: Style.font.body
                    foreground: root.barForeground
                    horizontalPadding: 0
                    verticalPadding: 0
                    enabled: root.store.watchlists.length > 1
                    opacity: enabled ? 1 : 0.4
                    tooltipText: "Next watchlist"
                    onClicked: root.cycleWatchlist(1)
                  }

                  Button {
                    id: addWatchlistButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(24)
                    height: Style.space(24)
                    text: "+"
                    fontSize: Style.font.subtitle
                    foreground: root.barForeground
                    horizontalPadding: 0
                    verticalPadding: 0
                    tooltipText: "New watchlist"
                    onClicked: root.startCreate()
                  }
                }

                Row {
                  width: parent.width
                  height: Style.space(18)
                  visible: !root.addingWatchlist && !root.renamingWatchlist
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    id: renameAction
                    text: "Rename"
                    color: renameMouse.containsMouse ? root.barForeground : root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.underline: renameMouse.containsMouse

                    MouseArea {
                      id: renameMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.startRename()
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: deleteAction
                    visible: root.store.watchlists.length > 1
                    text: root.confirmingDelete ? "Confirm delete" : "Delete"
                    color: root.confirmingDelete || deleteMouse.containsMouse
                      ? root.urgentForeground : root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.underline: deleteMouse.containsMouse

                    MouseArea {
                      id: deleteMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (root.confirmingDelete) {
                          deleteTimer.stop()
                          root.deleteCurrentWatchlist()
                        } else {
                          root.confirmingDelete = true
                          deleteTimer.restart()
                        }
                      }
                    }
                  }
                }

                TextField {
                  id: nameField
                  width: parent.width
                  height: visible ? Style.spacing.controlHeight : 0
                  visible: root.addingWatchlist || root.renamingWatchlist
                  placeholderText: root.addingWatchlist ? "New watchlist name" : "Watchlist name"
                  text: root.nameDraft
                  foreground: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onTextChanged: root.nameDraft = text
                  onAccepted: root.submitEditor()
                  Keys.onEscapePressed: function(event) {
                    root.cancelEditor()
                    event.accepted = true
                  }
                }

                // Portfolio value of the holdings in this watchlist.
                Rectangle {
                  id: portfolioCard
                  visible: root.portfolio.count > 0
                  width: parent.width
                  height: portfolioInner.implicitHeight + Style.space(12)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.06)

                  Column {
                    id: portfolioInner
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(2)

                    Item {
                      width: parent.width
                      height: portfolioValue.implicitHeight

                      Text {
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Portfolio"
                        color: root.mutedForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        id: portfolioValue
                        anchors.right: parent.right
                        text: root.portfolio.value !== null
                          ? Portfolio.formatMoney(root.portfolio.value, root.portfolio.currency)
                          : "…"
                        color: root.barForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                      }
                    }

                    Item {
                      width: parent.width
                      height: portfolioChange.implicitHeight

                      Text {
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.right: portfolioChange.left
                        anchors.rightMargin: Style.space(6)
                        text: root.portfolio.missing > 0
                          ? root.portfolio.missing + " of " + root.portfolio.count + " not priced yet"
                          : root.portfolio.count + (root.portfolio.count === 1 ? " position" : " positions")
                        elide: Text.ElideRight
                        color: root.mutedForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        id: portfolioChange
                        anchors.right: parent.right
                        text: root.portfolio.dayChange !== null
                          ? Portfolio.formatSignedMoney(root.portfolio.dayChange, "")
                            + (root.portfolio.dayChangePct !== null
                                ? " (" + Model.formatSignedPercent2(root.portfolio.dayChangePct) + ")" : "")
                            + " today"
                          : ""
                        color: root.signedColor(root.portfolio.dayChange)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }

                PanelSeparator {
                  visible: !root.addingWatchlist && !root.renamingWatchlist
                  foreground: root.barForeground
                }
              }

              // Sidebar list area.
              Flickable {
                id: tickerList
                visible: root.searchText.trim() === ""
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: sideHeader.bottom
                anchors.topMargin: Style.space(6)
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: tickerColumn.implicitHeight
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Column {
                  id: tickerColumn
                  width: tickerList.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.listRows

                    Rectangle {
                      id: tickerRow
                      required property var modelData
                      readonly property bool valid: Model.isValid(modelData)
                      readonly property bool selected: modelData.symbol === root.selectedSymbol
                      readonly property var changePct: modelData.changePct
                      width: tickerColumn.width
                      height: Style.space(50)
                      radius: Style.cornerRadius
                      color: tickerRow.selected
                        ? Style.selectedFillFor(root.barForeground, Color.accent)
                        : (rowMouse.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

                      MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectSymbol(tickerRow.modelData.symbol)
                      }

                      Text {
                        textFormat: Text.PlainText
                        id: tickerName
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.right: spark.left
                        anchors.rightMargin: Style.space(8)
                        anchors.top: parent.top
                        anchors.topMargin: Style.space(6)
                        text: tickerRow.valid
                          ? (tickerRow.modelData.name || tickerRow.modelData.symbol)
                          : (tickerRow.modelData.error || "Loading…")
                        elide: Text.ElideRight
                        color: tickerRow.valid ? root.barForeground : root.mutedForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.italic: !tickerRow.valid
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.left: tickerName.left
                        anchors.right: tickerName.right
                        anchors.top: tickerName.bottom
                        anchors.topMargin: 1
                        text: root.positionLabel(tickerRow.modelData.symbol)
                        elide: Text.ElideRight
                        color: root.mutedForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      SeriesCanvas {
                        id: spark
                        anchors.right: priceColumn.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(46)
                        height: Style.space(18)
                        visible: tickerRow.valid
                        series: tickerRow.modelData.series || []
                        endTime: tickerRow.modelData.sessionEnd || 0
                        interval: Model.intervalSeconds(Model.chartInterval("1d"))
                        referenceValue: tickerRow.modelData.prevClose
                        referenceColor: root.barForeground
                        boundsValue: tickerRow.modelData.prevClose
                        lineColor: root.trendColor(tickerRow.modelData)
                        lineWidth: 1.25
                        pad: 1.5
                      }

                      Column {
                        id: priceColumn
                        anchors.right: removeButton.left
                        anchors.rightMargin: Style.space(2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(74)
                        spacing: Style.space(2)

                        Text {
                          textFormat: Text.PlainText
                          anchors.right: parent.right
                          text: tickerRow.valid ? Model.formatPrice(tickerRow.modelData.price) : "…"
                          color: root.barForeground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Rectangle {
                          anchors.right: parent.right
                          visible: tickerRow.valid && tickerRow.changePct !== null
                          width: badgeText.implicitWidth + Style.space(8)
                          height: badgeText.implicitHeight + Style.space(1)
                          radius: Style.space(3)
                          color: Qt.rgba(root.signedColor(tickerRow.changePct).r,
                                         root.signedColor(tickerRow.changePct).g,
                                         root.signedColor(tickerRow.changePct).b, 0.14)

                          Text {
                            textFormat: Text.PlainText
                            id: badgeText
                            anchors.centerIn: parent
                            text: Model.formatSignedPercent2(tickerRow.changePct)
                            color: root.signedColor(tickerRow.changePct)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }
                      }

                      Button {
                        id: removeButton
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(18)
                        height: Style.space(18)
                        text: "×"
                        fontSize: Style.font.body
                        foreground: removeButton.hot ? root.urgentForeground : root.mutedForeground
                        horizontalPadding: 0
                        verticalPadding: 0
                        opacity: rowMouse.containsMouse || removeButton.hot || tickerRow.selected ? 1 : 0.45
                        tooltipText: "Remove ticker"
                        onClicked: root.removeSymbol(tickerRow.modelData.symbol)
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.symbols.length === 0
                    width: parent.width
                    topPadding: Style.space(10)
                    text: "No tickers yet.\nSearch above to add one."
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.italic: true
                  }
                }
              }

              // Search results replace the ticker list while typing.
              Flickable {
                id: searchList
                visible: root.searchText.trim() !== ""
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: sideHeader.bottom
                anchors.topMargin: Style.space(6)
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: searchColumn.implicitHeight
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Column {
                  id: searchColumn
                  width: searchList.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.searchResults

                    Rectangle {
                      id: resultRow
                      required property var modelData
                      width: searchColumn.width
                      height: Style.space(44)
                      radius: Style.cornerRadius
                      color: resultMouse.containsMouse
                        ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"

                      Column {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.right: resultMeta.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: resultRow.modelData.symbol
                          elide: Text.ElideRight
                          color: root.barForeground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: resultRow.modelData.name
                          elide: Text.ElideRight
                          color: root.mutedForeground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        id: resultMeta
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.symbols.indexOf(resultRow.modelData.symbol) === -1
                          ? resultRow.modelData.exchange : "Added"
                        color: root.mutedForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        id: resultMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.addResult(resultRow.modelData)
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.searching
                    width: parent.width
                    topPadding: Style.space(10)
                    text: "Searching…"
                    horizontalAlignment: Text.AlignHCenter
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.italic: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: !root.searching && root.searchError !== ""
                    width: parent.width
                    topPadding: Style.space(10)
                    text: root.searchError
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.italic: true
                  }
                }
              }
            }
          }

          Rectangle {
            width: 1
            height: parent.height
            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)
          }

          // =============================================================
          // Detail pane: selected ticker, chart, range, stats.
          // =============================================================
          Item {
            width: parent.width - sidebar.width - 1
            height: parent.height

            Item {
              anchors.fill: parent
              anchors.margins: Style.space(14)

              Column {
                id: emptyDetail
                visible: root.selectedSymbol === ""
                anchors.centerIn: parent
                width: parent.width * 0.8
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "No ticker selected"
                  horizontalAlignment: Text.AlignHCenter
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "Search for a symbol or company on the left to add it to this watchlist."
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  color: root.mutedForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Column {
                id: detailColumn
                visible: root.selectedSymbol !== ""
                anchors.fill: parent
                spacing: Style.space(10)

                // Header: name on the left, price and day change on the right.
                Item {
                  width: parent.width
                  height: Math.max(nameColumn.implicitHeight, priceColumn.implicitHeight)

                  Column {
                    id: nameColumn
                    anchors.left: parent.left
                    anchors.right: priceColumn.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: Model.isValid(root.detailQuote)
                        ? (root.detailQuote.name || root.detailQuote.symbol)
                        : root.selectedSymbol
                      elide: Text.ElideRight
                      color: root.barForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: Model.isValid(root.detailQuote)
                        ? [root.detailQuote.symbol, root.detailQuote.exchange, root.currencyLabel(root.detailQuote)]
                            .filter(function(part) { return !!part }).join(" · ")
                        : root.selectedSymbol
                      elide: Text.ElideRight
                      color: root.mutedForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Column {
                    id: priceColumn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Text {
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      text: Model.isValid(root.detailQuote) ? Model.formatPrice(root.detailQuote.price) : "…"
                      color: root.barForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.displayLarge
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      text: Model.isValid(root.detailQuote) ? Model.formatChange(root.detailQuote) : ""
                      color: root.trendColor(root.detailQuote)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }

                // Range and display currency.
                Row {
                  width: parent.width
                  height: Style.space(26)
                  spacing: Style.space(4)

                  Repeater {
                    model: Model.CHART_RANGES

                    Button {
                      required property string modelData
                      text: root.rangeLabel(modelData)
                      selected: modelData === root.activeRange
                      fontSize: Style.font.caption
                      foreground: root.barForeground
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(3)
                      onClicked: root.selectRange(modelData)
                    }
                  }

                  Item { width: Style.space(6); height: 1 }

                  Button {
                    readonly property bool active: root.displayCurrency !== ""
                    text: (root.displayCurrency !== "" ? root.displayCurrency : "Native") + " ⇄"
                    selected: active
                    fontSize: Style.font.caption
                    foreground: root.barForeground
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(3)
                    tooltipText: "Right-click to cycle back"
                    onClicked: root.selectCurrency(1)
                    onRightClicked: root.selectCurrency(-1)
                  }
                }

                // Price chart.
                Item {
                  id: chartFrame
                  width: parent.width
                  height: Style.space(250)
                  readonly property var bounds: Model.seriesBounds(root.detailSeries)
                  readonly property var selectionSeries: root.detailSeries
                  onSelectionSeriesChanged: clearSelection()
                  property int selectionStart: -1
                  property int selectionEnd: -1
                  readonly property var points: Model.seriesPoints(root.detailSeries, width, height,
                    detailChart.pad, detailChart.endTime, detailChart.boundsValue, detailChart.interval)
                  readonly property var measurement: Selection.measurement(root.detailSeries, selectionStart, selectionEnd)
                  readonly property color selectionColor: measurement ? root.signedColor(measurement.change) : root.barForeground
                  readonly property real selectionLeft: measurement ? points[Math.min(selectionStart, selectionEnd)].x : 0
                  readonly property real selectionRight: measurement ? points[Math.max(selectionStart, selectionEnd)].x : 0
                  readonly property string selectionContext: root.selectedSymbol + ":" + root.activeRange + ":" + root.displayCurrency
                  onSelectionContextChanged: clearSelection()
                  function clearSelection() { selectionStart = -1; selectionEnd = -1 }


                  SeriesCanvas {
                    id: detailChart
                    anchors.fill: parent
                    series: root.detailSeries
                    endTime: root.chartEndFor(root.detailQuote)
                    interval: Model.intervalSeconds(Model.chartInterval(root.activeRange))
                    grid: true
                    gridColor: root.barForeground
                    range: root.activeRange
                    lineColor: root.trendColor(root.detailQuote)
                    lineWidth: 1.75
                    pad: 4
                    fill: true
                    referenceValue: root.activeRange === "1d" && Model.isValid(root.detailQuote)
                      ? root.detailQuote.prevClose : null
                  }

                  Repeater {
                    model: 3

                    Text {
                      textFormat: Text.PlainText
                      required property int index
                      readonly property var bounds: chartFrame.bounds
                      readonly property real value: bounds
                        ? bounds.min + (bounds.max - bounds.min) * (index + 1) / 4 : 0
                      visible: root.detailSeries.length >= 2
                      x: chartFrame.width - width - Style.space(4)
                      y: bounds ? Model.valueToY(value, bounds, chartFrame.height, detailChart.pad) - height / 2 : 0
                      text: bounds ? Model.formatPrice(value) : ""
                      color: root.mutedForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    text: chartFrame.bounds ? Model.formatPrice(chartFrame.bounds.max) : ""
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    text: chartFrame.bounds ? Model.formatPrice(chartFrame.bounds.min) : ""
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: root.detailSeries.length < 2
                    text: root.chartLoading ? "Loading chart…" : (root.loading ? "Loading…" : "No chart data")
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.italic: true
                  }
                  // Selection follows the same sample positions as the chart, not wall-clock gaps.
                  Rectangle {
                    visible: chartFrame.measurement !== null
                    x: chartFrame.selectionLeft
                    width: chartFrame.selectionRight - x
                    height: parent.height
                    color: Qt.rgba(chartFrame.selectionColor.r, chartFrame.selectionColor.g, chartFrame.selectionColor.b, 0.12)
                  }
                  Repeater {
                    model: chartFrame.measurement ? [chartFrame.selectionStart, chartFrame.selectionEnd] : []
                    Item {
                      required property int modelData
                      x: chartFrame.points[modelData].x
                      height: chartFrame.height
                      Rectangle { width: 1; height: parent.height; color: chartFrame.selectionColor }
                      Rectangle {
                        x: -4; y: chartFrame.points[modelData].y - 4
                        width: 8; height: 8; radius: 4
                        color: chartFrame.selectionColor
                      }
                    }
                  }
                  Rectangle {
                    visible: chartFrame.measurement !== null
                    x: Style.space(8); y: Style.space(8)
                    width: Math.min(parent.width - Style.space(16), selectionText.implicitWidth + Style.space(16))
                    height: selectionText.implicitHeight + Style.space(12)
                    color: Color.background
                    radius: Style.space(4)
                    border.color: chartFrame.selectionColor
                    Text {
                      id: selectionText
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: chartFrame.selectionColor
                      elide: Text.ElideRight
                      text: {
                        var m = chartFrame.measurement
                        if (!m) return ""
                        var change = (m.change > 0 ? "+" : (m.change < 0 ? "−" : "")) + Model.formatPrice(Math.abs(m.change))
                        var percent = m.percent === null ? "—" : Model.formatSignedPercent2(m.percent)
                        return change + " (" + percent + ") · " + root.currencyLabel(root.detailQuote)
                          + "\n" + root.formatStamp(m.start.t, root.activeRange) + " → " + root.formatStamp(m.end.t, root.activeRange)
                          + "\n" + Model.formatPrice(m.start.c) + " → " + Model.formatPrice(m.end.c)
                      }
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: root.detailSeries.length >= 2
                    cursorShape: Qt.CrossCursor
                    preventStealing: true
                    onPressed: function(mouse) {
                      chartFrame.selectionStart = Selection.nearestIndex(chartFrame.points, mouse.x)
                      chartFrame.selectionEnd = chartFrame.selectionStart
                    }
                    onPositionChanged: function(mouse) {
                      if (pressed) chartFrame.selectionEnd = Selection.nearestIndex(chartFrame.points, mouse.x)
                    }
                    onReleased: function(mouse) {
                      chartFrame.selectionEnd = Selection.nearestIndex(chartFrame.points, mouse.x)
                      if (chartFrame.selectionEnd === chartFrame.selectionStart) chartFrame.clearSelection()
                    }
                    onCanceled: chartFrame.clearSelection()
                  }
                }

                Item {
                  id: timeAxis
                  width: parent.width
                  height: firstStamp.implicitHeight
                  visible: root.detailSeries.length >= 2
                  readonly property var ticks: Model.chartTimeTicks(root.detailSeries, root.activeRange,
                    root.chartEndFor(root.detailQuote), Model.intervalSeconds(Model.chartInterval(root.activeRange)))

                  Repeater {
                    model: timeAxis.ticks

                    Text {
                      textFormat: Text.PlainText
                      required property var modelData
                      // Keep the end labels readable instead of overlapping them.
                      visible: modelData.fraction > 0.12 && modelData.fraction < 0.88
                      text: root.formatStamp(modelData.t, root.activeRange)
                      x: Math.max(0, Math.min(timeAxis.width - width,
                        detailChart.pad + modelData.fraction * (timeAxis.width - detailChart.pad * 2) - width / 2))
                      color: root.mutedForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: firstStamp
                    anchors.left: parent.left
                    text: root.detailSeries.length
                      ? root.formatStamp(root.detailSeries[0].t, root.activeRange) : ""
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    text: {
                      if (!root.detailSeries.length) return ""
                      var end = root.chartEndFor(root.detailQuote)
                      return root.formatStamp(end || root.detailSeries[root.detailSeries.length - 1].t, root.activeRange)
                    }
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                PanelSeparator { foreground: root.barForeground }

                // Holding: shares owned, editable, and what they are worth now.
                Item {
                  id: holdingRow
                  width: parent.width
                  height: Math.max(holdingField.height, holdingValues.implicitHeight)

                  Text {
                    textFormat: Text.PlainText
                    id: holdingLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Shares owned"
                    color: root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  TextField {
                    id: holdingField
                    anchors.left: holdingLabel.right
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(120)
                    height: Style.spacing.controlHeight
                    placeholderText: "0"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    maximumLength: 24
                    foreground: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    onActiveFocusChanged: if (activeFocus) root.beginHoldingEdit()
                    onEditingFinished: if (root.holdingEditSymbol !== "") root.commitHolding(text)
                    onAccepted: keyCatcher.forceActiveFocus()
                    Keys.onEscapePressed: function(event) {
                      root.cancelHoldingEdit()
                      event.accepted = true
                    }
                  }

                  Column {
                    id: holdingValues
                    anchors.left: holdingField.right
                    anchors.leftMargin: Style.space(12)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: root.holdingError !== ""
                        ? root.holdingError
                        : (root.selectedPosition
                            ? (root.selectedPosition.value !== null
                                ? "Value " + Portfolio.formatMoney(root.selectedPosition.value, root.selectedPosition.currency)
                                : "Value …")
                            : "Type how many shares you own")
                      elide: Text.ElideLeft
                      color: root.holdingError !== "" ? root.urgentForeground
                        : (root.selectedPosition ? root.barForeground : root.mutedForeground)
                      font.family: root.fontFamily
                      font.pixelSize: root.selectedPosition && root.holdingError === "" ? Style.font.body : Style.font.caption
                      font.bold: root.selectedPosition !== null && root.holdingError === ""
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      visible: root.holdingError === "" && root.selectedPosition !== null
                        && root.selectedPosition.dayChange !== null
                      text: visible
                        ? Portfolio.formatSignedMoney(root.selectedPosition.dayChange, root.selectedPosition.currency) + " today"
                        : ""
                      color: root.selectedPosition ? root.signedColor(root.selectedPosition.dayChange) : root.mutedForeground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                PanelSeparator { foreground: root.barForeground }

                Grid {
                  id: stats
                  width: parent.width
                  columns: 4
                  columnSpacing: 0
                  rowSpacing: Style.space(4)

                  readonly property real statLabelWidth: Style.space(84)
                  readonly property real statValueWidth: (stats.width - statLabelWidth * 2) / 2
                  readonly property var entries: Model.isValid(root.detailQuote) ? [
                    ["Prev close", Model.formatPrice(root.detailQuote.prevClose)],
                    ["Open", Model.formatPrice(root.detailQuote.open)],
                    ["Day range", root.detailQuote.dayLow !== null && root.detailQuote.dayHigh !== null
                      ? Model.formatPrice(root.detailQuote.dayLow) + " – " + Model.formatPrice(root.detailQuote.dayHigh) : ""],
                    ["52w range", root.detailQuote.week52Low !== null && root.detailQuote.week52High !== null
                      ? Model.formatPrice(root.detailQuote.week52Low) + " – " + Model.formatPrice(root.detailQuote.week52High) : ""],
                    ["Volume", Model.formatVolume(root.detailQuote.volume)],
                    ["Last trade", root.detailQuote.marketTime !== null
                      ? Qt.formatDateTime(new Date(root.detailQuote.marketTime * 1000), "ddd HH:mm") : ""]
                  ] : []

                  Repeater {
                    model: stats.entries.length * 2

                    Text {
                      textFormat: Text.PlainText
                      required property int index
                      readonly property bool isLabel: index % 2 === 0
                      readonly property var entry: stats.entries[Math.floor(index / 2)]
                      width: isLabel ? stats.statLabelWidth : stats.statValueWidth
                      text: entry ? (isLabel ? entry[0] : (entry[1] || "—")) : ""
                      elide: Text.ElideRight
                      color: isLabel ? root.mutedForeground : root.barForeground
                      font.family: root.fontFamily
                      font.pixelSize: isLabel ? Style.font.caption : Style.font.bodySmall
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: footerText.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: footerText
                    anchors.left: parent.left
                    anchors.right: tradingViewLink.left
                    anchors.rightMargin: Style.space(10)
                    text: root.fetchError !== ""
                      ? "Could not update: " + root.fetchError
                      : (root.lastUpdated > 0
                          ? "Updated " + Qt.formatTime(new Date(root.lastUpdated), "HH:mm")
                          : (root.loading ? "Fetching quotes…" : "No data yet"))
                    elide: Text.ElideRight
                    color: root.fetchError !== "" ? root.urgentForeground : root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: tradingViewLink
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Open on TradingView ↗"
                    color: linkMouse.containsMouse ? root.barForeground : root.mutedForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.underline: linkMouse.containsMouse

                    MouseArea {
                      id: linkMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openTradingView(root.selectedSymbol)
                    }
                  }
                }

                Item { width: 1; height: 1 }
              }
            }
          }
        }
      }
    }
  }
}
