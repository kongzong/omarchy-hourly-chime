// Regression test for the "chime at :00, then again ~1 minute later" bug.
//
// Mirrors Chime.qml's msToNextMinute() / hourKey() / onTriggered line by line,
// and models QQmlTimer's clock: the next tick is scheduled relative to the
// PREVIOUS TICK timestamp, while the Date used to compute the interval is read
// a few ms later inside the handler.
//
//   node tools/repro-double-chime.mjs
//
// Before the fix the old logic produced 2 chimes for one hour; both the
// alignment epsilon and the hour-key dedupe are asserted below.

function msToNextMinuteOld(nowMs) {
  const now = new Date(nowMs)
  const next = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                       now.getHours(), now.getMinutes() + 1, 0, 0)
  return Math.max(1000, next.getTime() - nowMs)
}

// Chime.qml (fixed): aim at :00.050; the clamp only guards a backwards
// clock step / DST normalisation.
function msToNextMinuteFixed(nowMs) {
  const now = new Date(nowMs)
  const next = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                        now.getHours(), now.getMinutes() + 1, 0, 50)
  return Math.max(50, next.getTime() - nowMs)
}

function hourKey(d) {
  return d.getFullYear() + '-' + d.getMonth() + '-' + d.getDate() + '-' + d.getHours()
}

function stamp(ms) {
  const d = new Date(ms)
  return d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0')
}

// mode: 'old' = shipped 2.1.0, 'fixed' = current Chime.qml
// latencies: handler delay in ms, cycled (models a busy shell)
function replay(mode, latencies, startHour, minutes, verbose) {
  const start = new Date()
  start.setHours(startHour, 0, 0, 0)
  let tick = start.getTime()
  let lastFired = ''
  const fires = []
  const gaps = []
  let prevTick = null

  for (let i = 0; i < minutes; i++) {
    const trigger = tick
    const readAt = trigger + latencies[i % latencies.length]
    const now = new Date(readAt)
    let fired = false

    if (now.getMinutes() === 0) {
      if (mode === 'old') {
        fired = true
      } else {
        const key = hourKey(now)
        if (key !== lastFired) { lastFired = key; fired = true }
      }
    }
    if (fired) fires.push(stamp(readAt))
    if (verbose) console.log('   tick ' + stamp(trigger) + '  read ' + stamp(readAt) + (fired ? '   <-- CHIME' : ''))
    if (prevTick !== null) gaps.push(trigger - prevTick)
    prevTick = trigger

    const interval = mode === 'old' ? msToNextMinuteOld(readAt) : msToNextMinuteFixed(readAt)
    tick = trigger + interval
  }
  return { fires, gaps }
}

function assert(cond, msg) {
  if (!cond) { console.error('FAIL: ' + msg); process.exitCode = 1 }
  else console.log('PASS: ' + msg)
}

console.log('=== 2.1.0 shipped logic, 3 minutes around 19:00 ===')
const oldShort = replay('old', [3, 1, 2], 19, 3, true)
console.log('   => ' + oldShort.fires.length + ' chimes: ' + oldShort.fires.join(', ') + '\n')

console.log('=== current Chime.qml, 3 minutes around 19:00 ===')
const fixedShort = replay('fixed', [3, 1, 2], 19, 3, true)
console.log('   => ' + fixedShort.fires.length + ' chimes: ' + fixedShort.fires.join(', ') + '\n')

console.log('=== long replay: 18:00 -> 21:00 (181 ticks), handler 1..12 ms jitter ===')
const lat = [1, 12, 3, 8, 2, 7, 4, 9, 1, 6, 11, 2, 5, 8, 3, 10]
const oldLong = replay('old', lat, 18, 181, false)
const fixedLong = replay('fixed', lat, 18, 181, false)
const tally = fires => {
  const m = {}
  fires.forEach(t => { const h = t.slice(0, 2); m[h] = (m[h] || 0) + 1 })
  return m
}
const oldByHour = tally(oldLong.fires)
const byHour = tally(fixedLong.fires)
console.log('   old  : ' + oldLong.fires.length + ' chimes, per hour = ' + JSON.stringify(oldByHour))
console.log('   fixed: ' + fixedLong.fires.length + ' chimes, per hour = ' + JSON.stringify(byHour))
const minGap = Math.min(...fixedLong.gaps)
const maxGap = Math.max(...fixedLong.gaps)
console.log('   tick gaps: min ' + minGap + ' ms, max ' + maxGap + ' ms\n')

console.log('=== assertions ===')
assert(oldShort.fires.length === 2, 'old logic reproduces the double chime')
assert(fixedShort.fires.length === 1, 'fixed logic chimes once at 19:00')
assert(fixedLong.fires.length === 4, 'fixed logic chimes once for each of the 4 hour boundaries crossed')
assert(Object.values(byHour).every(n => n === 1), 'no hour receives two chimes')
assert(Object.keys(byHour).length === 4, 'no hour is skipped')
assert(minGap >= 50 && maxGap <= 61000, 'no 50 ms busy loop and no missed minute')
assert(Object.values(oldByHour).some(n => n !== 1), 'old logic has hours with != 1 chime (double or missed)')

if (process.exitCode) process.exit(1)
