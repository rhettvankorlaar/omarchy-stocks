// Watchlist state for the Stocks app. Pure functions so the QML side only has
// to replace `state` and write the serialized result: no mutation triggers.

var VERSION = 1
var DEFAULT_NAME = "My Stocks"
var RANGES = ["1d", "5d", "1mo", "6mo", "1y"]
// Matches Model.MAX_FETCH_SYMBOLS: 30 worst-case 1d payloads fit the 1 MiB
// response cap.
var MAX_SYMBOLS = 30

function trimString(value) {
  return value === undefined || value === null ? "" : String(value).trim()
}

// Watchlist ids only need to be unique inside this file. Time + random keeps
// them sortable and collision-free without pulling in a dependency.
function newId(now, rand) {
  var stamp = Math.floor(Number(now) || Date.now()).toString(36)
  var noise = Math.floor((typeof rand === "function" ? Number(rand()) : Math.random()) * 1e9).toString(36)
  return "wl-" + stamp + "-" + noise
}

function normalizeName(value, fallback) {
  var name = trimString(value).replace(/\s+/g, " ").slice(0, 40)
  return name || (fallback === undefined ? "Watchlist" : fallback)
}

function normalizeSymbols(value) {
  var items = Array.isArray(value) ? value : String(value === undefined || value === null ? "" : value).split(/[\s,;]+/)
  var seen = {}
  var out = []
  for (var i = 0; i < items.length; i++) {
    var symbol = trimString(items[i]).toUpperCase()
    if (!symbol || seen[symbol]) continue
    seen[symbol] = true
    out.push(symbol)
  }
  return out
}

function normalizeRange(value) {
  var range = trimString(value).toLowerCase()
  return RANGES.indexOf(range) === -1 ? "1d" : range
}

function normalizeCurrency(value) {
  var code = trimString(value).toUpperCase()
  return /^[A-Z]{3}$/.test(code) ? code : ""
}

// Shares held per symbol, shared by every watchlist that lists the symbol.
// Mirrors Portfolio.normalizeHoldings; kept here so Store.js stays standalone.
var MAX_HOLDING = 1e12
var MAX_HOLDINGS = 500

function normalizeHolding(value) {
  if (value === undefined || value === null || value === "") return 0
  var n = Number(value)
  if (!isFinite(n) || n < 0 || n > MAX_HOLDING) return 0
  return Math.round(n * 1e8) / 1e8
}

function normalizeHoldings(input) {
  var out = {}
  if (!input || typeof input !== "object" || Array.isArray(input)) return out
  var count = 0
  for (var key in input) {
    if (count >= MAX_HOLDINGS) break
    var symbol = trimString(key).toUpperCase()
    if (!/^[A-Z0-9.^=-]{1,20}$/.test(symbol)) continue
    var amount = normalizeHolding(input[key])
    if (amount <= 0) continue
    out[symbol] = amount
    count++
  }
  return out
}

function copyHoldings(holdings) {
  var out = {}
  for (var key in holdings || {}) out[key] = holdings[key]
  return out
}

function emptyState(now, rand) {
  var listId = newId(now, rand)
  return {
    version: VERSION,
    watchlists: [{ id: listId, name: DEFAULT_NAME, symbols: [] }],
    activeWatchlist: listId,
    selectedSymbol: "",
    chartRange: "1d",
    currency: "",
    holdings: {}
  }
}

function copyState(state) {
  var lists = []
  for (var i = 0; i < state.watchlists.length; i++) {
    var list = state.watchlists[i]
    lists.push({ id: list.id, name: list.name, symbols: list.symbols.slice() })
  }
  return {
    version: VERSION,
    watchlists: lists,
    activeWatchlist: state.activeWatchlist,
    selectedSymbol: state.selectedSymbol,
    chartRange: state.chartRange,
    currency: state.currency,
    holdings: copyHoldings(state.holdings)
  }
}

function findWatchlist(state, id) {
  if (!state) return null
  for (var i = 0; i < state.watchlists.length; i++) {
    if (state.watchlists[i].id === id) return state.watchlists[i]
  }
  return null
}

function activeWatchlist(state) {
  if (!state || state.watchlists.length === 0) return null
  return findWatchlist(state, state.activeWatchlist) || state.watchlists[0]
}

function activeSymbols(state) {
  var list = activeWatchlist(state)
  return list ? list.symbols.slice() : []
}

// Invalid saved data (hand edit, old version) is repaired here rather than
// rejected: the app must always have one watchlist to add tickers to.
function normalizeState(input, now, rand) {
  var fallback = emptyState(now, rand)
  if (!input || typeof input !== "object") return fallback

  var rawLists = Array.isArray(input.watchlists) ? input.watchlists : []
  var lists = []
  var seen = {}
  for (var i = 0; i < rawLists.length; i++) {
    var raw = rawLists[i]
    if (!raw || typeof raw !== "object") continue
    var id = trimString(raw.id)
    if (!id || seen[id]) id = newId(now, rand)
    seen[id] = true
    lists.push({
      id: id,
      name: normalizeName(raw.name),
      symbols: normalizeSymbols(raw.symbols)
    })
  }
  if (lists.length === 0) return fallback

  var active = trimString(input.activeWatchlist)
  if (!seen[active]) active = lists[0].id

  var list = findWatchlist({ watchlists: lists }, active)
  var selected = normalizeSymbols([input.selectedSymbol])[0] || ""
  if (selected && list.symbols.indexOf(selected) === -1) selected = ""
  if (!selected && list.symbols.length) selected = list.symbols[0]

  return {
    version: VERSION,
    watchlists: lists,
    activeWatchlist: active,
    selectedSymbol: selected,
    chartRange: normalizeRange(input.chartRange),
    currency: normalizeCurrency(input.currency),
    holdings: normalizeHoldings(input.holdings)
  }
}

function parseState(text, now, rand) {
  var raw = trimString(text)
  if (raw === "") return emptyState(now, rand)
  try {
    return normalizeState(JSON.parse(raw), now, rand)
  } catch (error) {
    return emptyState(now, rand)
  }
}

function serializeState(state) {
  return JSON.stringify(state) + "\n"
}

function statePath(home, xdgStateHome) {
  var base = trimString(xdgStateHome)
  var userHome = trimString(home)
  if (!base && userHome) base = userHome + "/.local/state"
  return (base || "/.local/state") + "/omarchy/stocks/state.json"
}

function ensureSelection(state) {
  var list = activeWatchlist(state)
  if (!list) {
    state.selectedSymbol = ""
    return state
  }
  var selected = trimString(state.selectedSymbol).toUpperCase()
  if (selected && list.symbols.indexOf(selected) !== -1) {
    state.selectedSymbol = selected
    return state
  }
  state.selectedSymbol = list.symbols.length ? list.symbols[0] : ""
  return state
}

function addWatchlist(state, name, now, rand) {
  var next = copyState(state)
  var id = newId(now, rand)
  while (findWatchlist(next, id)) id = newId(now, rand)
  next.watchlists.push({ id: id, name: normalizeName(name), symbols: [] })
  next.activeWatchlist = id
  next.selectedSymbol = ""
  return next
}

function renameWatchlist(state, id, name) {
  if (trimString(name) === "") return state
  var next = copyState(state)
  var list = findWatchlist(next, id)
  if (!list) return state
  list.name = normalizeName(name)
  return next
}

// The last watchlist stays: deleting it would leave nowhere to add a ticker.
function deleteWatchlist(state, id) {
  if (!state || state.watchlists.length <= 1) return state
  if (!findWatchlist(state, id)) return state
  var next = copyState(state)
  var lists = []
  for (var i = 0; i < next.watchlists.length; i++) {
    if (next.watchlists[i].id !== id) lists.push(next.watchlists[i])
  }
  next.watchlists = lists
  if (next.activeWatchlist === id) next.activeWatchlist = lists[0].id
  for (var symbol in copyHoldings(next.holdings)) {
    if (!symbolListed(next, symbol)) delete next.holdings[symbol]
  }
  return ensureSelection(next)
}

function setActiveWatchlist(state, id) {
  if (!findWatchlist(state, id) || state.activeWatchlist === id) return state
  var next = copyState(state)
  next.activeWatchlist = id
  next.selectedSymbol = ""
  return ensureSelection(next)
}

function addSymbol(state, symbol) {
  var value = normalizeSymbols([symbol])[0]
  if (!value) return state
  var next = copyState(state)
  var list = activeWatchlist(next)
  if (!list) return state
  if (list.symbols.indexOf(value) === -1) {
    if (list.symbols.length >= MAX_SYMBOLS) return state
    list.symbols.push(value)
  }
  next.selectedSymbol = value
  return next
}

function removeSymbol(state, symbol) {
  var value = normalizeSymbols([symbol])[0]
  var next = copyState(state)
  var list = activeWatchlist(next)
  if (!list) return state
  var index = list.symbols.indexOf(value)
  if (index === -1) return state
  list.symbols.splice(index, 1)
  if (next.selectedSymbol === value) next.selectedSymbol = ""
  if (!symbolListed(next, value)) delete next.holdings[value]
  return ensureSelection(next)
}

function symbolListed(state, symbol) {
  for (var i = 0; i < state.watchlists.length; i++) {
    if (state.watchlists[i].symbols.indexOf(symbol) !== -1) return true
  }
  return false
}

function holdingFor(state, symbol) {
  var value = normalizeSymbols([symbol])[0]
  if (!value || !state || !state.holdings) return 0
  return normalizeHolding(state.holdings[value])
}

// amount <= 0 (or empty) clears the holding. Only listed symbols can be held.
function setHolding(state, symbol, amount) {
  var value = normalizeSymbols([symbol])[0]
  if (!value || !symbolListed(state, value)) return state
  var n = normalizeHolding(amount)
  if (n === holdingFor(state, value)) return state
  var holdings = state.holdings || {}
  if (n <= 0 && holdings[value] === undefined) return state
  if (n > 0 && holdings[value] === undefined && Object.keys(holdings).length >= MAX_HOLDINGS) return state
  var next = copyState(state)
  if (n > 0) next.holdings[value] = n
  else delete next.holdings[value]
  return next
}

function selectSymbol(state, symbol) {
  var value = normalizeSymbols([symbol])[0]
  var list = activeWatchlist(state)
  if (!list || list.symbols.indexOf(value) === -1) return state
  if (state.selectedSymbol === value) return state
  var next = copyState(state)
  next.selectedSymbol = value
  return next
}

function setChartRange(state, range) {
  var raw = trimString(range).toLowerCase()
  if (RANGES.indexOf(raw) === -1) return state
  var value = raw
  if (state.chartRange === value) return state
  var next = copyState(state)
  next.chartRange = value
  return next
}

function setCurrency(state, currency) {
  var value = normalizeCurrency(currency)
  if (state.currency === value) return state
  var next = copyState(state)
  next.currency = value
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION,
    DEFAULT_NAME: DEFAULT_NAME,
    RANGES: RANGES,
    MAX_SYMBOLS: MAX_SYMBOLS,
    newId: newId,
    normalizeName: normalizeName,
    normalizeSymbols: normalizeSymbols,
    normalizeRange: normalizeRange,
    normalizeCurrency: normalizeCurrency,
    emptyState: emptyState,
    normalizeState: normalizeState,
    parseState: parseState,
    serializeState: serializeState,
    statePath: statePath,
    findWatchlist: findWatchlist,
    activeWatchlist: activeWatchlist,
    activeSymbols: activeSymbols,
    addWatchlist: addWatchlist,
    renameWatchlist: renameWatchlist,
    deleteWatchlist: deleteWatchlist,
    setActiveWatchlist: setActiveWatchlist,
    addSymbol: addSymbol,
    removeSymbol: removeSymbol,
    selectSymbol: selectSymbol,
    setChartRange: setChartRange,
    setCurrency: setCurrency,
    normalizeHoldings: normalizeHoldings,
    holdingFor: holdingFor,
    setHolding: setHolding
  }
}
