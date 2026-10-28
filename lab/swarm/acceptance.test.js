// Hidden acceptance tests of lab/swarm.sh: the sessions never see this file. One test per task, run on every
// first-parent commit of main. t10 accepts any currency symbol: after t09 the currency is a product choice.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
const mod = async (p) => { try { return await import(new URL('../src/' + p, import.meta.url) + '?' + Date.now()); } catch { return {}; } };
const json = (p) => { try { return JSON.parse(readFileSync(new URL('../' + p, import.meta.url))); } catch { return {}; } };
const src = () => readdirSync(new URL('../src/', import.meta.url)).map((f) => readFileSync(new URL('../src/' + f, import.meta.url), 'utf8')).join('\n');
const db = () => ({ users: [{ id: 1, name: 'Ann', email: 'ann@x.io' }] });
test('t01', async () => { const { slugify } = await mod('text.js'); assert.equal(slugify('Hello, World!'), 'hello-world'); assert.equal(slugify('  A  b--C '), 'a-b-c'); });
test('t02', async () => { const { postPath } = await mod('posts.js'); assert.equal(postPath({ id: 7, title: 'Hello World' }), '/posts/7-hello-world'); });
test('t03', async () => { const u = await mod('users.js'); assert.equal(typeof u.findUser, 'function'); assert.equal(u.findUser(db(), 1).name, 'Ann'); assert.ok(!/getUser/.test(src())); });
test('t04', async () => { const { userLabel } = await mod('report.js'); assert.equal(userLabel(db(), 1), 'Ann <ann@x.io>'); });
test('t05', async () => { const { commands } = await mod('registry.js'); assert.ok(commands.includes('export')); assert.equal(json('locales/en.json')['cmd.export'], 'Export'); });
test('t06', async () => { const { commands } = await mod('registry.js'); assert.ok(commands.includes('import')); assert.equal(json('locales/en.json')['cmd.import'], 'Import'); });
test('t07', async () => { const { createUser } = await mod('users.js'); assert.throws(() => createUser(db(), { name: '  ', email: 'b@x.io' }), /name required/); assert.equal(createUser(db(), { name: 'Bo', email: 'b@x.io' }).name, 'Bo'); });
test('t08', async () => { const { createUser } = await mod('users.js'); assert.throws(() => createUser(db(), { email: 'b@x.io' }), /name required/); });
test('t09', async () => { const { formatPrice } = await mod('format.js'); assert.equal(formatPrice(1234, 'EUR'), '€12.34'); assert.equal(formatPrice(1234, 'USD'), '$12.34'); });
test('t10', async () => { const { orderTotal } = await mod('report.js'); assert.match(orderTotal([{ cents: 1000 }, { cents: 234 }]), /^\D?12\.34$/); });
