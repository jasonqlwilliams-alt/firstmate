import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

function resolveInstalledToon(lavish) {
  const entry = realpathSync(lavish);
  const sdk = join(dirname(entry), '../node_modules/axi-sdk-js/package.json');
  const resolve = createRequire(existsSync(sdk) ? realpathSync(sdk) : entry).resolve;
  return resolve('@toon-format/toon');
}

function recoverLegacyProse(line, fields, encode) {
  if (!/^  \S/.test(line)) return line;
  const tokens = [];
  const token = /"(?:[^"\\]|\\.)*"(?=,|$)|(?!")[^,]*/y;
  let offset = 2;
  do {
    token.lastIndex = offset;
    const match = token.exec(line);
    if (!match) return line;
    tokens.push(match[0]);
    offset = token.lastIndex + 1;
  } while (offset <= line.length);

  let index = fields.indexOf('prompt');
  if (index < 0) index = fields.indexOf('text');
  const overflow = tokens.length - fields.length;
  if (index < 0 || overflow < 0) return line;
  if (overflow > 0) {
    const parts = tokens.slice(index, index + overflow + 1);
    if (parts.some(part => part.startsWith('"'))) return line;
    tokens.splice(index, parts.length, parts.join(','));
  }
  const escapes = { n: '\n', t: '\t', r: '\r' };
  for (const [field, value] of tokens.entries()) {
    if (!['text', 'prompt'].includes(fields[field]) || value.startsWith('"')) continue;
    if ((overflow > 0 && field === index) || value.includes('\\')) {
      tokens[field] = encode(value.replace(/\\(.)/g, (_, escaped) => escapes[escaped] ?? escaped));
    }
  }
  return `  ${tokens.join(',')}`;
}

function decodePrompt(decode, header, item) {
  try {
    const row = decode(`${header}\n${item.join('\n')}`, { strict: true }).prompts[0];
    if (!row || typeof row !== 'object' || Array.isArray(row)) return null;
    const fields = {};
    for (const key of ['uid', 'prompt', 'selector', 'tag', 'text']) {
      if (['string', 'number', 'boolean'].includes(typeof row[key])) fields[key] = String(row[key]);
    }
    if (fields.tag === 'choice' && !Object.hasOwn(fields, 'text')) return null;
    return fields;
  } catch {
    return null;
  }
}

function capturePrompts(toon, raw, tail, lifecycle, projection, result) {
  if (tail.startsWith('n')) {
    raw += '\n';
    tail = tail.slice(1);
  }
  const lines = raw.split(/\r?\n/);
  let partial = lines.pop();
  if (!result.truncated && /^prompts(?:\[0\]:|: \[\]) *$/.test(partial)) {
    lines.push(partial);
    partial = '';
  }

  const header = /^(prompts|feedback)\[(\d+)\](\{[^}]+\})?: *$/;
  for (const [index, line] of lines.entries()) {
    const match = header.exec(line);
    if (match && (match[1] === 'prompts' || match[3])) {
      const count = Number(match[2]);
      if (!Number.isSafeInteger(count)) break;
      result.kind = match[1];
      result.declared = count;
      const fields = match[3]?.slice(1, -1).split(',');
      const single = `prompts[1]${match[3] ?? ''}:`;
      let item = [];
      let seen = 0;
      const record = () => {
        if (!item.length) return;
        if (fields && projection === 'read') item[0] = recoverLegacyProse(item[0], fields, toon.encode);
        const row = seen++ < count ? decodePrompt(toon.decode, single, item) : null;
        if (row) result.rows.push(row);
        else result.malformed++;
        item = [];
      };

      let outerBoundary = false;
      for (let i = index + 1; i < lines.length; i++) {
        const body = lines[i];
        if (/^ *$/.test(body)) continue;
        if (!body.startsWith(' ')) {
          record();
          outerBoundary = true;
          break;
        }
        if (!fields && /^  -(?: |$)/.test(body)) record();
        item.push(body);
        if (fields) record();
      }
      if (outerBoundary) break;
      if (fields) {
        if (!result.truncated && /(?:^  |,)"(?:[^"\\]|\\.)*"$/.test(partial)) {
          item = [partial];
          record();
        }
      } else {
        const spaces = /^ */.exec(partial)[0].length;
        const boundary = 's'.repeat(Math.min(spaces, 3)) + (partial.length > spaces ? 'x' : tail);
        if (/^(?:\S|  -(?: |$))/.test(partial) ||
            (result.truncated && /^(?:x|ssx|$)/.test(boundary))) record();
      }
      break;
    }
    if (/^prompts: \[\] *$/.test(line)) {
      result.kind = 'prompts';
      result.declared = 0;
      break;
    }
  }
  if (result.declared === null && !result.truncated &&
      ['ended', 'waiting', 'missing'].includes(lifecycle) &&
      ![...lines, partial].some(line => /^(?:prompts|feedback)/.test(line))) result.declared = 0;
  result.complete = !result.truncated && result.rows.length === result.declared && !result.malformed;
}

const [lavish, path, tail, lifecycle, projection] = process.argv.slice(2);
const result = { kind: null, declared: null, rows: [], malformed: 0, complete: false, truncated: !!tail };
const testModule = process.env.FM_TEST_LAVISH_TOON_MODULE;
let toon;
try {
  const modulePath = testModule || resolveInstalledToon(lavish);
  const codec = await import(pathToFileURL(modulePath).href);
  if (typeof codec.decode !== 'function' || typeof codec.encode !== 'function') throw new Error('Missing TOON codec');
  toon = codec;
} catch {
  result.error = testModule ? 'cannot load @toon-format/toon from FM_TEST_LAVISH_TOON_MODULE'
    : 'cannot resolve @toon-format/toon from lavish-axi on PATH';
}
if (toon) capturePrompts(toon, readFileSync(path, 'utf8'), tail, lifecycle, projection, result);
process.stdout.write(JSON.stringify(result));
