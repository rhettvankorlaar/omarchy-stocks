// Portfolio maths for the Stocks app: how many shares of each ticker the user
// holds, and what that is worth right now. Pure functions so the QML side only
// binds to the results and Node tests can cover them.

// Generous but bounded: a hand-edited state file must not be able to produce
// absurd numbers in the UI.
var MAX_AMOUNT = 1e12
var AMOUNT_DECIMALS = 8

function toNumber(value) {
  if (value === undefined || value === null || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

// Accepts "10", "2.5", "2,5" (comma decimal), "1 000" and "1,000.5". Returns a
// positive number, 0 for "clear this holding", or null when the input is not a
// usable amount.
function parseAmount(value) {
  if (typeof value === "number") return clampAmount(value)
  var raw = String(value === undefined || value === null ? "" : value).trim().replace(/[\s_']/g, "")
  if (raw === "") return 0
  if (raw.indexOf(",") !== -1 && raw.indexOf(".") !== -1) raw = raw.replace(/,/g, "")
  else if (/^\d{1,3}(,\d{3})+$/.test(raw)) raw = raw.replace(/,/g, "")
  else raw = raw.replace(",", ".")
  if (!/^\d*\.?\d+$|^\d+\.$/.test(raw)) return null
  return clampAmount(Number(raw))
}

function clampAmount(value) {
  var n = toNumber(value)
  if (n === null || n < 0 || n > MAX_AMOUNT) return null
  var factor = Math.pow(10, AMOUNT_DECIMALS)
  return Math.round(n * factor) / factor
}

// {SYMBOL: amount} with only valid, positive amounts.
function normalizeHoldings(input) {
  var out = {}
  if (!input || typeof input !== "object" || Array.isArray(input)) return out
  var count = 0
  for (var key in input) {
    if (count >= 500) break
    var symbol = String(key).trim().toUpperCase()
    if (!/^[A-Z0-9.^=-]{1,20}$/.test(symbol)) continue
    var amount = clampAmount(input[key])
    if (amount === null || amount <= 0) continue
    out[symbol] = amount
    count++
  }
  return out
}

function amountFor(holdings, symbol) {
  if (!holdings) return 0
  var n = toNumber(holdings[String(symbol || "").toUpperCase()])
  return n === null || n <= 0 ? 0 : n
}

function formatAmount(amount) {
  var n = toNumber(amount)
  if (n === null || n <= 0) return ""
  var fixed = n.toFixed(AMOUNT_DECIMALS).replace(/\.?0+$/, "")
  var parts = fixed.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

// Plain text for the editable amount field: no thousands separators so it
// round-trips through parseAmount unchanged.
function editableAmount(amount) {
  var n = toNumber(amount)
  if (n === null || n <= 0) return ""
  return n.toFixed(AMOUNT_DECIMALS).replace(/\.?0+$/, "")
}

function formatMoney(value, currency) {
  var n = toNumber(value)
  if (n === null) return ""
  var fixed = Math.abs(n).toFixed(2)
  var parts = fixed.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  var text = (n < 0 ? "-" : "") + parts.join(".")
  return currency ? text + " " + currency : text
}

function formatSignedMoney(value, currency) {
  var n = toNumber(value)
  if (n === null) return ""
  return (n < 0 ? "-" : "+") + formatMoney(Math.abs(n), currency)
}

// --- Currency handling -------------------------------------------------------
// Quotes come in their native currency (London in pence, etc.). A portfolio
// total needs one currency: the chosen display currency, or else the currency
// most of the holdings are in. Kept local so this module has no dependency on
// Model.js.

var MINOR_UNITS = { GBp: "GBP", GBX: "GBP", ZAc: "ZAR", ILA: "ILS" }

function majorCurrency(currency) {
  var raw = String(currency || "").trim()
  if (raw === "") return { code: "", factor: 1 }
  if (MINOR_UNITS[raw]) return { code: MINOR_UNITS[raw], factor: 0.01 }
  return { code: raw.toUpperCase(), factor: 1 }
}

function isValidQuote(quote) {
  return !!quote && toNumber(quote.price) !== null
}

function nativeCurrencyOf(quote) {
  return quote ? quote.nativeCurrency || quote.currency || "" : ""
}

// Display currency when set, otherwise the currency holding the most value
// (by count when prices are unknown). "" when nothing is held.
function portfolioCurrency(symbols, holdings, quotes, display) {
  var target = String(display || "").trim().toUpperCase()
  if (/^[A-Z]{3}$/.test(target)) return target
  var bySymbol = indexQuotes(quotes)
  var weight = {}
  var order = []
  var list = symbols || []
  for (var i = 0; i < list.length; i++) {
    var amount = amountFor(holdings, list[i])
    var quote = bySymbol[list[i]]
    if (amount <= 0 || !isValidQuote(quote)) continue
    var cur = majorCurrency(nativeCurrencyOf(quote))
    if (cur.code === "") continue
    if (weight[cur.code] === undefined) {
      weight[cur.code] = 0
      order.push(cur.code)
    }
    weight[cur.code] += amount * Number(quote.price) * cur.factor
  }
  var best = ""
  for (var j = 0; j < order.length; j++) {
    if (best === "" || weight[order[j]] > weight[best]) best = order[j]
  }
  return best
}

// Yahoo FX pairs ("USDEUR=X") needed to express every held quote in `target`.
function ratePairs(symbols, holdings, quotes, target) {
  var out = []
  if (!target) return out
  var bySymbol = indexQuotes(quotes)
  var list = symbols || []
  for (var i = 0; i < list.length; i++) {
    if (amountFor(holdings, list[i]) <= 0) continue
    var quote = bySymbol[list[i]]
    if (!isValidQuote(quote)) continue
    var from = majorCurrency(nativeCurrencyOf(quote)).code
    if (from === "" || from === target) continue
    var pair = from + target + "=X"
    if (out.indexOf(pair) === -1) out.push(pair)
  }
  return out
}

// Multiplier from the quote's native currency into `target`; null when the FX
// rate is not known yet.
function rateInto(currency, target, rates) {
  var from = majorCurrency(currency)
  if (!target || from.code === "") return null
  if (from.code === target) return from.factor
  var rate = rates ? toNumber(rates[from.code + target + "=X"]) : null
  return rate === null ? null : rate * from.factor
}

function indexQuotes(quotes) {
  var out = {}
  var list = quotes || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].symbol) out[String(list[i].symbol)] = list[i]
  }
  return out
}

// One entry per held symbol in `symbols` with its value in `target`. Quotes
// must be the raw (native-currency) quotes.
function positions(symbols, holdings, quotes, target, rates) {
  var bySymbol = indexQuotes(quotes)
  var out = []
  var list = symbols || []
  for (var i = 0; i < list.length; i++) {
    var symbol = list[i]
    var amount = amountFor(holdings, symbol)
    if (amount <= 0) continue
    var quote = bySymbol[symbol]
    var row = { symbol: symbol, amount: amount, value: null, dayChange: null, currency: target }
    if (isValidQuote(quote)) {
      var rate = rateInto(nativeCurrencyOf(quote), target, rates)
      if (rate !== null) {
        row.value = amount * Number(quote.price) * rate
        var change = toNumber(quote.change)
        var prevClose = toNumber(quote.prevClose)
        if (change === null && prevClose !== null) change = Number(quote.price) - prevClose
        if (change !== null) row.dayChange = amount * change * rate
      }
    }
    out.push(row)
  }
  return out
}

// Totals over `positions`: value, day change (and %), and how many holdings
// could not be priced yet.
function summary(symbols, holdings, quotes, display, rates) {
  var target = portfolioCurrency(symbols, holdings, quotes, display)
  var rows = positions(symbols, holdings, quotes, target, rates)
  var value = 0
  var dayChange = 0
  var priced = 0
  var changeKnown = 0
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].value === null) continue
    value += rows[i].value
    priced++
    if (rows[i].dayChange !== null) {
      dayChange += rows[i].dayChange
      changeKnown++
    }
  }
  var previous = value - dayChange
  return {
    currency: target,
    count: rows.length,
    priced: priced,
    missing: rows.length - priced,
    value: priced ? value : null,
    dayChange: changeKnown ? dayChange : null,
    dayChangePct: changeKnown && previous > 0 ? (dayChange / previous) * 100 : null,
    positions: rows
  }
}

// Value of one holding in an already converted (display) quote; null when the
// amount or price is unknown.
function holdingValue(amount, quote) {
  var n = toNumber(amount)
  if (n === null || n <= 0 || !isValidQuote(quote)) return null
  return n * Number(quote.price)
}

function holdingDayChange(amount, quote) {
  var n = toNumber(amount)
  if (n === null || n <= 0 || !quote) return null
  var change = toNumber(quote.change)
  return change === null ? null : n * change
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_AMOUNT: MAX_AMOUNT,
    parseAmount: parseAmount,
    clampAmount: clampAmount,
    normalizeHoldings: normalizeHoldings,
    amountFor: amountFor,
    formatAmount: formatAmount,
    editableAmount: editableAmount,
    formatMoney: formatMoney,
    formatSignedMoney: formatSignedMoney,
    majorCurrency: majorCurrency,
    portfolioCurrency: portfolioCurrency,
    ratePairs: ratePairs,
    rateInto: rateInto,
    positions: positions,
    summary: summary,
    holdingValue: holdingValue,
    holdingDayChange: holdingDayChange
  }
}
