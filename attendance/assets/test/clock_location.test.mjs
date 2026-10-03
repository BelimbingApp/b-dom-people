import assert from "node:assert/strict"
import {test} from "node:test"

import {execFileSync} from "node:child_process"
import {fileURLToPath} from "node:url"

// Execute the host's generated, selected hook bundle. Compiled extraction
// directories may retain stale files; the composition collector owns selection.
const workspace = fileURLToPath(new URL("../../../../../../", import.meta.url))
const binary = `${workspace}_build/esbuild-${process.platform}-${process.arch}`
const bundle = execFileSync(binary, [
  `${workspace}_build/test/bilimbi-hooks/index.js`,
  "--bundle", "--format=esm", "--platform=node"
], {env: {...process.env, NODE_PATH: `${workspace}_build/test:${workspace}deps`}})
const {hooks} = await import(`data:text/javascript;base64,${bundle.toString("base64")}`)
const hook = hooks["Bilimbi.People.Attendance.Web.MyLive.ClockLocation"]

function mount({required = true, geolocation, secure = true, authorized = true} = {}) {
  const buttons = ["in", "out"].map(type => ({type, disabled: !authorized}))
  const status = {textContent: ""}
  const listeners = new Map()
  const attrs = new Map()
  const el = {
    dataset: {locationRequired: String(required), authorized: String(authorized)},
    querySelector(selector) {
      if (selector === "[role=status]") return status
      return buttons.find(button => selector === `[data-clock-type="${button.type}"]`)
    },
    querySelectorAll() { return buttons },
    setAttribute(key, value) { attrs.set(key, value) },
    addEventListener(key, listener) { listeners.set(key, listener) },
    removeEventListener(key) { listeners.delete(key) }
  }
  Object.defineProperty(globalThis, "window", {value: {isSecureContext: secure}, configurable: true})
  Object.defineProperty(globalThis, "navigator", {value: {geolocation}, configurable: true})
  const events = []
  const replies = []
  const mounted = {
    ...hook, el,
    pushEvent(name, params, reply) { events.push({name, params}); replies.push(reply) }
  }
  mounted.mounted()
  return {
    mounted, events, buttons, status, attrs,
    click(type = "in") { listeners.get("attendance:clock")?.({detail: {type}}) },
    reply() { replies.shift()?.() }
  }
}

test("fresh coordinates are forwarded once; repeated clicks wait for acknowledgement", () => {
  let locate
  const page = mount({geolocation: {
    getCurrentPosition(success, _failure, options) {
      locate = success
      assert.equal(options.maximumAge, 0)
      assert.equal(options.enableHighAccuracy, true)
      assert.ok(options.timeout > 0)
    }
  }})
  page.click()
  assert.equal(page.status.textContent, "Finding your location…")
  assert.ok(page.buttons.every(button => button.disabled))
  page.click("out")
  locate({coords: {latitude: 1.5, longitude: 103.7}})
  assert.deepEqual(page.events, [{name: "clock", params: {type: "in", latitude: 1.5, longitude: 103.7}}])
  assert.equal(page.status.textContent, "Recording clock event…")
  page.mounted.updated()
  page.reply()
  assert.ok(page.buttons.every(button => !button.disabled))
  assert.equal(page.attrs.get("aria-busy"), "false")
  assert.equal(page.status.textContent, "")
})

test("permission refusal never submits a clock event and permits retry", () => {
  const page = mount({geolocation: {getCurrentPosition(_success, failure) {failure({code: 1})}}})
  page.click()
  assert.deepEqual(page.events, [{name: "clock_location_error", params: {reason: "permission_denied"}}])
  page.reply()
  assert.ok(page.buttons.every(button => !button.disabled))
  page.click()
  assert.equal(page.events.length, 2)
})

for (const [label, options] of [
  ["unsupported browser", {}],
  ["insecure context", {secure: false}],
  ["sensor throws", {geolocation: {getCurrentPosition() {throw new Error("sensor unavailable")}}}],
  ["position unavailable", {geolocation: {getCurrentPosition(_success, failure) {failure({code: 2})}}}],
  ["position timeout", {geolocation: {getCurrentPosition(_success, failure) {failure({code: 3})}}}],
  ["missing coordinates", {geolocation: {getCurrentPosition(success) {success({coords: {latitude: 1.5}})}}}],
  ["invalid coordinates", {geolocation: {getCurrentPosition(success) {success({coords: {latitude: NaN, longitude: 103.7}})}}}]
]) {
  test(`${label} reports unavailable and writes no clock`, () => {
    const page = mount(options)
    page.click()
    assert.deepEqual(page.events, [{name: "clock_location_error", params: {reason: "unavailable"}}])
    page.reply()
    assert.ok(page.buttons.every(button => !button.disabled))
  })
}

test("policy without location records without asking for permission", () => {
  const page = mount({required: false, geolocation: {getCurrentPosition() {assert.fail("unnecessary location prompt")}}})
  page.click("out")
  assert.deepEqual(page.events, [{name: "clock", params: {type: "out"}}])
})

test("disconnect or navigation discards late coordinates", () => {
  for (const action of ["disconnected", "destroyed"]) {
    let locate
    const page = mount({geolocation: {getCurrentPosition(success) {locate = success}}})
    page.click()
    page.mounted[action]()
    locate({coords: {latitude: 1.5, longitude: 103.7}})
    assert.deepEqual(page.events, [])
    if (action === "disconnected") {
      page.click()
      assert.deepEqual(page.events, [])
      page.mounted.reconnected()
      page.click()
      locate({coords: {latitude: 1.5, longitude: 103.7}})
      assert.equal(page.events.length, 1)
    }
  }
})

test("authority withheld during a patch remains withheld after acknowledgement", () => {
  const page = mount({required: false})
  page.click()
  page.mounted.el.dataset.authorized = "false"
  page.mounted.updated()
  page.reply()
  assert.ok(page.buttons.every(button => button.disabled))
  page.click()
  assert.equal(page.events.length, 1)
})
