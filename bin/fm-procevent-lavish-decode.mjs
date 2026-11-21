import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolveInstalledToon } from './fm-procevent-lavish-codec.mjs';

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
    if ((overflow > 0 && field === index) || value.includes('\\') ||
        (fields.length === 1 && value.includes(':'))) {
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

function hasEndFrame(decode, lines, lifecycle) {
  try {
    if (lifecycle === 'missing') {
      const response = decode(lines.join('\n'), { strict: true });
      return response.code === 'NOT_FOUND' && typeof response.error === 'string';
    }
    const footer = lines.at(-1);
    if (!footer?.startsWith('next_step: ')) return false;
    return typeof decode(footer, { strict: true }).next_step === 'string';
  } catch {
    return false;
  }
}

function capturePrompts(toon, raw, tail, lifecycle, projection, result) {
  if (tail.startsWith('n')) {
    raw += '\n';
    tail = tail.slice(1);
  }
  const lines = raw.split(/\r?\n/);
  let partial = lines.pop();
  const framed = !result.truncated && partial === '' && hasEndFrame(toon.decode, lines, lifecycle);
  if (!result.truncated && /^prompts(?:\[0\]:|: \[\]) *$/.test(partial)) {
    lines.push(partial);
    partial = '';
  }

  const header = /^(?:(prompts|feedback)\[(\d+)\](\{[^}]+\})?:|prompts: \[\]) *$/;
  const topLevelField = /^[A-Za-z_][\w.-]*(?:\[\d+\](?:\{[^}]+\})?)?:/;
  let seen = 0;
  let terminated = false;
  for (const [index, line] of lines.entries()) {
    const match = header.exec(line);
    if (match && (match[1] !== 'feedback' || match[3])) {
      const count = Number(match[2] ?? 0);
      if (!Number.isSafeInteger(count)) break;
      result.kind = match[1] ?? 'prompts';
      result.declared = count;
      const fields = match[3]?.slice(1, -1).split(',');
      const single = `prompts[1]${match[3] ?? ''}:`;
      let item = [];
      const record = () => {
        if (!item.length) return;
        const withinCount = ++seen <= count;
        const row = withinCount ? decodePrompt(toon.decode, single, item) : null;
        if (!row) result.malformed++;
        let displayed = row;
        if (withinCount && fields && projection === 'read') {
          const recovered = recoverLegacyProse(item[0], fields, toon.encode);
          if (recovered !== item[0]) displayed = decodePrompt(toon.decode, single, [recovered]) ?? row;
        }
        if (displayed) result.rows.push(displayed);
        item = [];
      };

      let outerBoundary = false;
      for (let i = index + 1; i < lines.length; i++) {
        const body = lines[i];
        if (/^ *$/.test(body)) continue;
        if (!body.startsWith(' ')) {
          record();
          outerBoundary = true;
          terminated = topLevelField.test(body);
          break;
        }
        if (!fields && /^  -(?: |$)/.test(body)) record();
        item.push(body);
        if (fields) record();
      }
      if (outerBoundary) break;
      terminated = /^\S/.test(partial) || (partial === '' && tail.startsWith('x'));
      if (fields) {
        if (!result.truncated && /(?:^  |,)"(?:[^"\\]|\\.)*"$/.test(partial)) {
          item = [partial];
          record();
        }
      } else {
        const spaces = /^ */.exec(partial)[0].length;
        const boundary = 's'.repeat(Math.min(spaces, 3)) + (partial.length > spaces ? 'x' : tail);
        if (terminated || /^  -(?: |$)/.test(partial) ||
            (result.truncated && /^(?:ssx|$)/.test(boundary))) record();
      }
      break;
    }
  }
  if (result.declared === null && !result.truncated &&
      ['ended', 'waiting', 'missing'].includes(lifecycle) &&
      ![...lines, partial].some(line => /^(?:prompts|feedback)/.test(line))) result.declared = 0;
  const rowsComplete = seen === result.declared && !result.malformed;
  result.prompts_complete = result.kind !== null && terminated && rowsComplete;
  result.complete = framed && (result.kind === null ? rowsComplete : result.prompts_complete);
}

const [lavish, path, tail, lifecycle, projection] = process.argv.slice(2);
const result = { kind: null, declared: null, rows: [], malformed: 0, complete: false, truncated: !!tail };
let toon;
try {
  const modulePath = resolveInstalledToon(lavish);
  const codec = await import(pathToFileURL(modulePath).href);
  if (typeof codec.decode !== 'function' || typeof codec.encode !== 'function') throw new Error('Missing TOON codec');
  toon = codec;
} catch {
  result.error = 'cannot resolve @toon-format/toon from lavish-axi on PATH';
}
if (toon) capturePrompts(toon, readFileSync(path, 'utf8'), tail, lifecycle, projection, result);
process.stdout.write(JSON.stringify(result));
