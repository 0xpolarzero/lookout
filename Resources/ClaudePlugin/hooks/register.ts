import type { EngineInterface, Register } from 'claude-code'

// Lookout's Router relays what the person writes to this session. The message arrives on the peer channel, signed by
// the Lookout app with a key only it holds (a file of Lookout's own, readable by the person alone, never in this
// folder: Claude Code copies an installed plugin's folder into its cache). A valid one, addressed to this session, fresh
// and never seen before, is taken off the peer channel and submitted as the person's own words. Anything else passes
// on untouched, as the peer message it is.
//
// The wire format: a header line, then the body's UTF-8 bytes in base64 on one line (so the peer channel's escaping and
// any Unicode normalization can't touch them):
//   ⟦lookout v1 <target session id> <nonce> <ms since 1970> <hex HMAC-SHA256>⟧\n<base64 body>
// The MAC covers the UTF-8 bytes of "v1\n<target>\n<nonce>\n<ms>\n" followed by the body's own UTF-8 bytes.
//
// Lookout writes this file; edits are overwritten.

const HEADER = /(?:^|\n)⟦lookout v1 (\S+) (\S+) (\d+) ([0-9a-f]{64})⟧\n/
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/
const CLOSE = '</cross-session-message>'
const WINDOW_MS = 10 * 60 * 1000
const NONCE = 'nonce.'
const ACTIVATION = crypto.randomUUID()

const enc = new TextEncoder()
const hex = (bytes: Uint8Array) => [...bytes].map((x) => x.toString(16).padStart(2, '0')).join('')
const join = (...parts: Uint8Array[]) => {
  const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let at = 0
  for (const p of parts) {
    all.set(p, at)
    at += p.length
  }
  return all
}
const sha256 = async (...parts: Uint8Array[]) => new Uint8Array(await crypto.subtle.digest('SHA-256', join(...parts)))

/** HMAC-SHA256 (RFC 2104) on the environment's SHA-256, the one digest it has. */
export const hmac = async (key: Uint8Array, message: Uint8Array) => {
  const block = new Uint8Array(64)
  block.set(key.length > 64 ? await sha256(key) : key)
  const inner = block.map((x) => x ^ 0x36)
  const outer = block.map((x) => x ^ 0x5c)
  return hex(await sha256(outer, await sha256(inner, message)))
}

/** What the MAC covers: the version, the target, the nonce and the time, one per line, then the body's bytes. */
export const macInput = (target: string, nonce: string, ts: string, body: Uint8Array) =>
  join(enc.encode(`v1\n${target}\n${nonce}\n${ts}\n`), body)

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

/** Standard base64 (padded) to bytes; undefined for anything else. */
export const fromBase64 = (text: string) => {
  if (!BASE64.test(text) || text.length % 4 !== 0) return undefined
  const clean = text.replace(/=+$/, '')
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4))
  let bits = 0
  let value = 0
  let at = 0
  for (const c of clean) {
    value = (value << 6) | ALPHABET.indexOf(c)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[at++] = (value >> bits) & 0xff
    }
  }
  return out
}

/** The signed message in a delivery: its header's fields and the body's bytes (the peer envelope's close left out). */
export const parse = (text: string) => {
  const m = HEADER.exec(text)
  if (!m) return undefined
  const [header, target, nonce, ts, mac] = m
  let rest = text.slice(m.index + header.length)
  const close = rest.indexOf(CLOSE)
  if (close >= 0) rest = rest.slice(0, close)
  const body = fromBase64(rest.trim())
  if (!body) return undefined
  return { target, nonce, ts, mac, body }
}

/** Compares two MACs in time that doesn't depend on where they differ. */
const same = (a: string, b: string) => {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

/** One nonce check-and-claim at a time in this copy of the plugin: two deliveries of the same message can't both pass. */
let claims: Promise<unknown> = Promise.resolve()
const exclusive = <T>(work: () => Promise<T>): Promise<T> => {
  const run = claims.then(work, work)
  claims = run.catch(() => undefined)
  return run
}

/** Where Lookout keeps the key and the presence files, and Claude Code its registry of processes, as absolute paths (a
 * hooks module can't read the environment). */
type Config = { keyPath?: string; presenceDir?: string; sessionsDir?: string }

async function config($: EngineInterface) {
  return JSON.parse(await $.fs.read(`${$.plugin.root}/config.json`)) as Config
}

/** Which key a presence file was written under: the first 16 hex digits of the key's SHA-256, never the key. */
export const keyId = async (key: string) => hex(await sha256(enc.encode(key))).slice(0, 16)

/** The session this copy last said it runs in, under which key, where it said so, and the process it found for it. */
let marked: { sessionId: string; presenceDir: string; keyId: string; pid: number; startedAt: number } | undefined

/** Says which session this plugin runs in, bound to its process (Claude Code's registry entry for the session: its pid
 * and start time) and to the key Lookout holds now, so Lookout can tell a live session from one that crashed, was resumed
 * without the plugin, or unloaded it while the Router was off. It is a lease: renewed at every turn and every 10 s
 * (`renewedAt`), so a plugin disabled and reloaded away, which says nothing as it goes, stops counting within 30 s.
 * The registry is read again when the session id changes (a /clear starts a new one with no session.start) or the key
 * does (the Router was switched off and on: its old presence files are gone). */
async function mark($: EngineInterface) {
  const { presenceDir, sessionsDir, keyPath } = await config($)
  if (!presenceDir || !sessionsDir || !keyPath) return
  const key = (await $.fs.read(keyPath).catch(() => '')).trim()
  if (!key) {
    // The Router is off: nothing to say until there's a key again.
    marked = undefined
    return
  }
  const id = await keyId(key)
  const sessionId = await $.session.id()
  let own: { pid: number; startedAt: number } | undefined =
    marked?.sessionId === sessionId && marked.keyId === id ? { pid: marked.pid, startedAt: marked.startedAt } : undefined
  if (!own) for (const entry of await $.fs.list(sessionsDir)) {
    if (!entry.name.endsWith('.json')) continue
    let found: { sessionId?: unknown; pid?: unknown; startedAt?: unknown }
    try {
      found = JSON.parse(await $.fs.read(`${sessionsDir}/${entry.name}`))
    } catch {
      continue
    }
    if (found?.sessionId === sessionId && typeof found.pid === 'number') {
      const startedAt = typeof found.startedAt === 'number' ? found.startedAt : 0
      if (!own || startedAt > own.startedAt) own = { pid: found.pid, startedAt }
    }
  }
  if (!own) return
  if (marked && marked.sessionId !== sessionId) {
    await $.fs.write(`${marked.presenceDir}/${marked.sessionId}`, `${JSON.stringify({ state: 'ended' })}\n`)
  }
  const renewedAt = await $.clock.now()
  const presence = { state: 'live', sessionId, pid: own.pid, startedAt: own.startedAt, keyId: id, renewedAt, activation: ACTIVATION }
  await $.fs.write(`${presenceDir}/${sessionId}`, `${JSON.stringify(presence)}\n`)
  marked = { sessionId, presenceDir, keyId: id, pid: own.pid, startedAt: own.startedAt }
}

async function unmark($: EngineInterface) {
  if (!marked) return
  await $.fs.write(`${marked.presenceDir}/${marked.sessionId}`, `${JSON.stringify({ state: 'ended' })}\n`)
  marked = undefined
}

export const register: Register = (on) => {
  on('session.receive', async ($, e, next) => {
    const signed = parse(e.text)
    if (!signed) return next(e)
    const { keyPath } = await config($)
    if (!keyPath) return next(e)
    const key = (await $.fs.read(keyPath)).trim()
    const expected = await hmac(enc.encode(key), macInput(signed.target, signed.nonce, signed.ts, signed.body))
    const now = await $.clock.now()
    const ts = Number(signed.ts)
    if (!same(expected, signed.mac) || signed.target !== (await $.session.id()) || !(Math.abs(now - ts) < WINDOW_MS)) {
      return next(e)
    }
    // A leading byte-order mark is part of what was written: the decoder drops one, so exactly one is put back.
    const decoded = new TextDecoder('utf-8', { fatal: true }).decode(signed.body)
    const bom = signed.body[0] === 0xef && signed.body[1] === 0xbb && signed.body[2] === 0xbf
    const text = bom ? `\uFEFF${decoded}` : decoded
    // Each nonce is a key of its own in the store (it outlives reloads and restarts), kept while its message's time is
    // inside the window: past it the message is refused as stale anyway.
    const claimed = await exclusive(async () => {
      if ((await $.store.get(NONCE + signed.nonce)) !== undefined) return false
      await $.store.set(NONCE + signed.nonce, ts)
      for (const name of await $.store.keys()) {
        if (!name.startsWith(NONCE)) continue
        const at = Number(await $.store.get(name))
        if (!(Math.abs(now - at) < WINDOW_MS)) await $.store.delete(name)
      }
      return true
    })
    if (!claimed) return next(e)
    void $.prompt.submit({ text, asUser: true })
    return { consumed: 'relayed by Lookout as the person’s own message' }
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    await mark($).catch(() => undefined)
    // The registry may not list the process yet, and a /clear changes the session's id: looked at again now and then.
    $.clock.every(10_000, () => void mark($).catch(() => undefined))
    return next(e)
  })
  on('turn.start', async ($, e, next) => {
    await mark($).catch(() => undefined)
    return next(e)
  })
  on('session.end', async ($, e, next) => {
    await unmark($).catch(() => undefined)
    return next(e)
  })
}
