const test = require("node:test")
const assert = require("node:assert/strict")
const Portfolio = require("../Portfolio.js")
const Store = require("../Store.js")

function quote(symbol, price, currency, prevClose) {
  return { symbol, price, currency, prevClose, change: prevClose === undefined ? null : price - prevClose }
}

test("parseAmount: accepts dot, comma and thousands formats", () => {
  assert.equal(Portfolio.parseAmount("10"), 10)
  assert.equal(Portfolio.parseAmount("2.5"), 2.5)
  assert.equal(Portfolio.parseAmount("2,5"), 2.5)
  assert.equal(Portfolio.parseAmount("1,000"), 1000)
  assert.equal(Portfolio.parseAmount("1,000.25"), 1000.25)
  assert.equal(Portfolio.parseAmount("1 000"), 1000)
  assert.equal(Portfolio.parseAmount(".5"), 0.5)
  assert.equal(Portfolio.parseAmount(""), 0)
  assert.equal(Portfolio.parseAmount("0"), 0)
})

test("parseAmount: rejects junk, negatives and absurd values", () => {
  for (const raw of ["abc", "-1", "1e5", "1.2.3", "<b>1</b>", "Infinity", "NaN", "1e13"]) {
    assert.equal(Portfolio.parseAmount(raw), null, raw)
  }
  assert.equal(Portfolio.parseAmount(2e12), null)
})

test("formatAmount / editableAmount", () => {
  assert.equal(Portfolio.formatAmount(1234.5), "1,234.5")
  assert.equal(Portfolio.formatAmount(10), "10")
  assert.equal(Portfolio.formatAmount(0), "")
  assert.equal(Portfolio.editableAmount(1234.5), "1234.5")
  assert.equal(Portfolio.editableAmount(0.00000001), "0.00000001")
})

test("formatMoney / formatSignedMoney", () => {
  assert.equal(Portfolio.formatMoney(1234567.891, "EUR"), "1,234,567.89 EUR")
  assert.equal(Portfolio.formatMoney(-5, "USD"), "-5.00 USD")
  assert.equal(Portfolio.formatSignedMoney(12.3, "USD"), "+12.30 USD")
  assert.equal(Portfolio.formatSignedMoney(-12.3, ""), "-12.30")
  assert.equal(Portfolio.formatMoney(null, "USD"), "")
})

test("summary: single currency totals value and day change", () => {
  const quotes = [quote("AAPL", 200, "USD", 190), quote("NVDA", 100, "USD", 110), quote("MSFT", 400, "USD", 400)]
  const result = Portfolio.summary(["AAPL", "NVDA", "MSFT"], { AAPL: 10, NVDA: 5 }, quotes, "", {})
  assert.equal(result.currency, "USD")
  assert.equal(result.count, 2)
  assert.equal(result.value, 2500)
  assert.equal(result.dayChange, 50)
  assert.ok(Math.abs(result.dayChangePct - (50 / 2450) * 100) < 1e-9)
  assert.equal(result.missing, 0)
})

test("summary: mixed currencies convert into the dominant one, pence included", () => {
  const quotes = [quote("ASML.AS", 700, "EUR", 700), quote("AAPL", 200, "USD", 200), quote("VOD.L", 100, "GBp", 100)]
  const holdings = { "ASML.AS": 10, AAPL: 1, "VOD.L": 100 }
  assert.equal(Portfolio.portfolioCurrency(["ASML.AS", "AAPL", "VOD.L"], holdings, quotes, ""), "EUR")
  assert.deepEqual(Portfolio.ratePairs(["ASML.AS", "AAPL", "VOD.L"], holdings, quotes, "EUR"), ["USDEUR=X", "GBPEUR=X"])
  const result = Portfolio.summary(["ASML.AS", "AAPL", "VOD.L"], holdings, quotes, "", { "USDEUR=X": 0.9, "GBPEUR=X": 1.2 })
  // 7000 + 200*0.9 + 100*100p*0.01*1.2
  assert.ok(Math.abs(result.value - (7000 + 180 + 120)) < 1e-9)
  assert.equal(result.missing, 0)
})

test("summary: unknown FX rates and missing quotes count as missing", () => {
  const quotes = [quote("ASML.AS", 700, "EUR", 700), quote("AAPL", 200, "USD", 200)]
  const result = Portfolio.summary(["ASML.AS", "AAPL", "TSLA"], { "ASML.AS": 1, AAPL: 1, TSLA: 1 }, quotes, "EUR", {})
  assert.equal(result.value, 700)
  assert.equal(result.missing, 2)
})

test("summary: nothing held", () => {
  const result = Portfolio.summary(["AAPL"], {}, [quote("AAPL", 1, "USD")], "", {})
  assert.equal(result.count, 0)
  assert.equal(result.value, null)
  assert.equal(result.currency, "")
})

test("Store holdings: set, clear, persist and prune", () => {
  let state = Store.emptyState(1000, () => 0.5)
  state = Store.addSymbol(state, "AAPL")
  state = Store.setHolding(state, "aapl", 12.5)
  assert.equal(Store.holdingFor(state, "AAPL"), 12.5)
  // Not listed -> ignored.
  assert.equal(Store.setHolding(state, "TSLA", 3), state)

  const reparsed = Store.parseState(Store.serializeState(state), 1000, () => 0.5)
  assert.deepEqual(reparsed.holdings, { AAPL: 12.5 })

  state = Store.setHolding(state, "AAPL", 0)
  assert.deepEqual(state.holdings, {})

  state = Store.setHolding(state, "AAPL", 3)
  state = Store.removeSymbol(state, "AAPL")
  assert.deepEqual(state.holdings, {})
})

test("Store holdings: shared across watchlists, kept while still listed", () => {
  let state = Store.emptyState(1000, () => 0.5)
  state = Store.addSymbol(state, "AAPL")
  state = Store.setHolding(state, "AAPL", 4)
  const first = state.activeWatchlist
  state = Store.addWatchlist(state, "Other", 2000, () => 0.1)
  state = Store.addSymbol(state, "AAPL")
  assert.equal(Store.holdingFor(state, "AAPL"), 4)
  state = Store.removeSymbol(state, "AAPL")
  assert.equal(Store.holdingFor(state, "AAPL"), 4)
  state = Store.setActiveWatchlist(state, first)
  state = Store.deleteWatchlist(state, first)
  assert.deepEqual(state.holdings, {})
})

test("Store holdings: junk in the state file is dropped", () => {
  const state = Store.normalizeState({
    watchlists: [{ id: "a", name: "A", symbols: ["AAPL"] }],
    holdings: { AAPL: "7", BAD: -1, "<img>": 3, NVDA: "x", MSFT: 1e20 }
  })
  assert.deepEqual(state.holdings, { AAPL: 7 })
  assert.deepEqual(Store.normalizeState({ watchlists: [{ id: "a", symbols: [] }], holdings: [1, 2] }).holdings, {})
})
