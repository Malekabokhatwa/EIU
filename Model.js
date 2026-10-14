// EIU helpers shared by the bar widget and its panel.

.pragma library

var PLANS = [200, 300, 400, 500, 600, 700, 800, 900, 1000]

function planLabel(gb) {
  gb = parseInt(gb, 10) || 0
  if (!gb) return "No plan"
  return (gb >= 1000 && gb % 1000 === 0) ? (gb / 1000) + " TB" : gb + " GB"
}

function planOptions() {
  var out = []
  for (var i = 0; i < PLANS.length; i++) out.push({ value: String(PLANS[i]), label: planLabel(PLANS[i]) })
  out.push({ value: "custom", label: "Custom…" })
  return out
}

function isStandardPlan(gb) {
  return PLANS.indexOf(parseInt(gb, 10)) !== -1
}

function formatBytes(n, base) {
  base = base || 1000
  n = Math.max(0, Number(n) || 0)
  var units = base === 1024 ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= base && i < units.length - 1) { n /= base; i++ }
  var digits = (i <= 1 || n >= 100) ? 0 : (n >= 10 ? 1 : 2)
  return n.toFixed(digits) + " " + units[i]
}

// Shorter form for the bar: "312G", "1.2T", "840M".
function compactBytes(n, base) {
  var s = formatBytes(n, base)
  return s.replace(" GB", "G").replace(" TB", "T").replace(" MB", "M").replace(" KB", "K")
          .replace(" GiB", "G").replace(" TiB", "T").replace(" MiB", "M").replace(" KiB", "K")
}

function daysLabel(n) {
  if (n === 0) return "today"
  if (n === 1) return "tomorrow"
  return "in " + n + " days"
}

function shortDate(iso) {
  var d = new Date(iso + "T00:00:00")
  return Qt.formatDate(d, "ddd d MMM")
}

// Fraction of the cycle that has passed, for the "where you should be" marker.
function elapsedFraction(status) {
  if (!status || !status.cycle || !status.cycle.length) return 0
  return Math.min(1, status.cycle.elapsed / status.cycle.length)
}
