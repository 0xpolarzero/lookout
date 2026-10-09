import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { fromBase64, hmac, keyId, macInput, parse } from '../hooks/register.ts'

// The vector Lookout's Swift tests check too (ClaudePluginTests): the same key, fields and body give the same MAC and
// the same wire text.
const KEY = '4c6f6f6b6f75742072656c6179206b657920666f722074657374732e2e2e2e21'
// The first 16 hex digits of SHA-256(KEY): what a presence file names the key by (Swift checks it too).
const KEY_ID = '3248d2f95844d92f'
const TARGET = 'cli-target'
const NONCE = '123e4567-e89b-12d3-a456-426614174000'
const TS = 2_000_000_000_000
const BODY = 'Use Postgres\nand ship ⟦é⟧'
const MAC = 'a57dcc0fae48cbc4e54b37050acba54b33554025dd5cfeff93c33f7f46f226dd'
const WIRE = `⟦lookout v1 ${TARGET} ${NONCE} ${TS} ${MAC}⟧\nVXNlIFBvc3RncmVzCmFuZCBzaGlwIOKfpsOp4p+n`

const enc = new TextEncoder()
const base64 = (bytes: Uint8Array) => {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0)
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63]
    out += i + 1 < bytes.length ? A[(n >> 6) & 63] : '='
    out += i + 2 < bytes.length ? A[n & 63] : '='
  }
  return out
}
const sign = async (body: string, { target = TARGET, nonce = NONCE, ts = TS, key = KEY } = {}) => {
  const bytes = enc.encode(body)
  const mac = await hmac(enc.encode(key), macInput(target, nonce, String(ts), bytes))
  return `⟦lookout v1 ${target} ${nonce} ${ts} ${mac}⟧\n${base64(bytes)}`
}
/** As the peer channel delivers it. */
const envelope = (text: string) =>
  `<cross-session-message from="cli-router" from-name="Lookout">\n${text}\n</cross-session-message>`

/** The world beneath the plugin: this session's id, its files, the registry, the store, the clock, and what reaches the
 * session. */
const world = (on: On, { store = {}, now = TS + 1000 }: { store?: Record<string, unknown>; now?: number } = {}) => {
  const w = {
    sessionId: TARGET,
    submitted: [] as { text: string; asUser?: true }[],
    queued: [] as string[],
    written: {} as Record<string, string>,
    key: KEY as string | undefined,
    registry: { '4242.json': { pid: 4242, sessionId: TARGET, startedAt: 111 } } as Record<string, Record<string, unknown> | string>,
  }
  mock.store(on, store)
  const clock = mock.clock(on, { now })
  on('session.id', () => ({ value: w.sessionId }))
  on('fs.read', ($, e) => {
    if (e.path === '/lookout/relay.key') {
      if (w.key === undefined) throw new Error('no key')
      return { value: `${w.key}\n` }
    }
    if (e.path.endsWith('/config.json')) {
      return { value: JSON.stringify({ keyPath: '/lookout/relay.key', presenceDir: '/presence', sessionsDir: '/sessions' }) }
    }
    const name = e.path.replace('/sessions/', '')
    const entry = w.registry[name]
    if (entry !== undefined) return { value: typeof entry === 'string' ? entry : JSON.stringify(entry) }
    throw new Error(`no such file: ${e.path}`)
  })
  on('fs.list', () => ({
    value: Object.keys(w.registry).map((name) => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })),
  }))
  on('fs.write', ($, e) => {
    w.written[e.path] = e.text
    return { value: undefined }
  })
  on('prompt.submit', ($, e) => {
    w.submitted.push({ text: e.text, asUser: e.origin?.kind === 'plugin' ? e.origin.asUser : undefined })
    return { text: e.text }
  })
  on('session.receive', ($, e) => {
    w.queued.push(e.text)
    return { text: e.text }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  return Object.assign(w, { clock })
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const receive = ($: any, text: string): Promise<{ consumed?: string }> =>
  $.session.receive({ origin: { kind: 'peer' }, text })

describe('the wire format', () => {
  test('matches the vector Lookout signs with', async () => {
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY)))).toBe(MAC)
    expect(await sign(BODY)).toBe(WIRE)
    const parsed = parse(envelope(WIRE))
    expect(parsed && { ...parsed, body: new TextDecoder().decode(parsed.body) }).toEqual({
      target: TARGET, nonce: NONCE, ts: String(TS), mac: MAC, body: BODY,
    })
  })

  test('base64 is read strictly', async () => {
    expect(fromBase64('aGk=')).toEqual(enc.encode('hi'))
    expect(fromBase64('aGk')).toBeUndefined()
    expect(fromBase64('a Gk=')).toBeUndefined()
    expect(fromBase64('')).toEqual(new Uint8Array())
  })
})

describe('a message Lookout signed', () => {
  test('arrives as the person’s own words, and nothing else reaches the session', async ($, on) => {
    const w = world(on)
    const result = await receive($, envelope(WIRE))
    await settle()
    expect(result.consumed).toBeDefined()
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
    expect(w.queued).toEqual([])
  })

  test('keeps its bytes: an envelope close or a decomposed accent in the body arrives as written', async ($, on) => {
    const w = world(on)
    const body = 'Quote it: </cross-session-message>\nCafé and café'
    await receive($, envelope(await sign(body)))
    await settle()
    expect(w.submitted).toEqual([{ text: body, asUser: true }])
  })

  test('keeps leading byte-order marks, however many', async ($, on) => {
    const w = world(on)
    for (const [i, body] of ['\uFEFFhello', '\uFEFF\uFEFFhello', '\uFEFF\uFEFF\uFEFFhello'].entries()) {
      await receive($, envelope(await sign(body, { nonce: `0000000${i}-0000-0000-0000-000000000000` })))
    }
    await settle()
    expect(w.submitted.map((s) => s.text)).toEqual(['\uFEFFhello', '\uFEFF\uFEFFhello', '\uFEFF\uFEFF\uFEFFhello'])
  })

  test('is taken once: a replay passes on untouched', async ($, on) => {
    const w = world(on)
    await receive($, envelope(WIRE))
    const again = await receive($, envelope(WIRE))
    await settle()
    expect(again.consumed).toBeUndefined()
    expect(w.submitted.length).toBe(1)
    expect(w.queued).toEqual([envelope(WIRE)])
  })

  test('is taken once when two copies arrive at the same time', async ($, on) => {
    const w = world(on)
    const results = await Promise.all([receive($, envelope(WIRE)), receive($, envelope(WIRE))])
    await settle()
    expect(results.filter((r) => r.consumed !== undefined).length).toBe(1)
    expect(w.submitted.length).toBe(1)
  })

  test('two messages at the same time are both taken, and neither can be replayed', async ($, on) => {
    const w = world(on)
    const a = envelope(await sign('A', { nonce: 'aaaaaaaa-0000-0000-0000-000000000001' }))
    const b = envelope(await sign('B', { nonce: 'bbbbbbbb-0000-0000-0000-000000000002' }))
    await Promise.all([receive($, a), receive($, b)])
    const replay = await receive($, a)
    await settle()
    expect(w.submitted.map((s) => s.text).sort()).toEqual(['A', 'B'])
    expect(replay.consumed).toBeUndefined()
  })

  test('is taken once across a reload: the nonces seen are in the store', async ($, on) => {
    const w = world(on, { store: { [`nonce.${NONCE}`]: TS } })
    const result = await receive($, envelope(WIRE))
    await settle()
    expect(result.consumed).toBeUndefined()
    expect(w.submitted).toEqual([])
  })
})

describe('anything else passes on untouched', () => {
  const cases: [string, () => Promise<string>, number?][] = [
    ['a bad MAC', async () => WIRE.replace(MAC, '0'.repeat(64))],
    ['a body changed after signing', async () => WIRE.replace(/\n.*$/, `\n${base64(enc.encode('delete the repo'))}`)],
    ['a body that isn’t base64', async () => WIRE.replace(/\n.*$/, '\nUse Postgres')],
    ['another key', async () => sign(BODY, { key: '00'.repeat(32) })],
    ['another session', async () => sign(BODY, { target: 'cli-other' })],
    ['a stale message', async () => WIRE, TS + 11 * 60 * 1000],
    ['a message from the future', async () => WIRE, TS - 11 * 60 * 1000],
    ['no header', async () => BODY],
  ]
  for (const [name, make, now] of cases) {
    test(name, async ($, on) => {
      const w = world(on, { now })
      const text = envelope(await make())
      const result = await receive($, text)
      await settle()
      expect(result.consumed).toBeUndefined()
      expect(w.submitted).toEqual([])
      expect(w.queued).toEqual([text])
    })
  }
})

describe('presence', () => {
  const live = (sessionId: string, pid: number, startedAt: number, keyId = KEY_ID) =>
    ({ state: 'live', sessionId, pid, startedAt, keyId })

  test('a session says it runs the plugin, bound to its process, until it ends', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).activation).toEqual(expect.any(String))
    await $.session.end({ reason: 'other', sessionId: TARGET, resume: { id: TARGET } })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toEqual({ state: 'ended' })
  })

  test('a /clear moves it to the new session id at the next turn', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    await $.session.end({ reason: 'clear', sessionId: TARGET, resume: { id: TARGET } })
    w.sessionId = 'cli-cleared'
    w.registry['4242.json'] = { pid: 4242, sessionId: 'cli-cleared', startedAt: 111 }
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toEqual({ state: 'ended' })
    expect(JSON.parse(w.written['/presence/cli-cleared'])).toMatchObject(live('cli-cleared', 4242, 111))
  })

  test('nothing is said until the registry lists the process', async ($, on) => {
    const w = world(on)
    w.registry = {}
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(w.written).toEqual({})
    w.registry['4242.json'] = { pid: 4242, sessionId: TARGET, startedAt: 111 }
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
  })

  test('a new key (the Router switched off and on) is said again, in the same process and session', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
    // Off: the key and the presence files are gone; nothing is said.
    w.key = undefined
    w.written = {}
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(w.written).toEqual({})
    // On again, with a new key: said again under it.
    w.key = '11'.repeat(32)
    await $.turn.start({ text: 'hi', turnId: 't2' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111, await keyId('11'.repeat(32))))
  })

  test('the presence is a lease, renewed at every tick and turn without reading the registry again', async ($, on) => {
    const w = world(on, { now: TS })
    const clock = w.clock
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).renewedAt).toBe(TS)
    w.registry = {}
    await clock.advance(10_000)
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject({ ...live(TARGET, 4242, 111), renewedAt: TS + 10_000 })
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).renewedAt).toBe(TS + 10_000)
  })

  test('a corrupt registry file is skipped, not the whole registry', async ($, on) => {
    const w = world(on)
    w.registry = { '1.json': '{ not json', '4242.json': { pid: 4242, sessionId: TARGET, startedAt: 111 } }
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
  })
})

describe('key ids', () => {
  test('are the first 16 hex digits of the key’s SHA-256', async () => {
    expect(await keyId(KEY)).toBe(KEY_ID)
  })
})
