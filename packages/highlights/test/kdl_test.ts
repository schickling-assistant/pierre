import assert from 'node:assert';
import t from 'node:test';

import { codeToTokens } from '../lib/index';
import { samples } from './_samples';
import {
  assertLineFedParity,
  checkInvariants,
  distinctTheme,
  initFullModule,
  kindOfColor,
  loadLang,
  type TestLang,
} from './_util';

let kdl: TestLang;
t.before(() => {
  kdl = loadLang('kdl', '$hlKdl');
});

/** Check source ranges, independent of merging adjacent same-kind tokens. */
function assertKind(
  code: string,
  text: string,
  expected: string | readonly string[]
) {
  initFullModule();
  const start = code.indexOf(text);
  assert.ok(start >= 0, `missing fixture text ${JSON.stringify(text)}`);
  const end = start + text.length;
  const allowed = typeof expected === 'string' ? [expected] : expected;
  let covered = 0;
  for (const token of codeToTokens(code, {
    lang: 'kdl',
    theme: distinctTheme,
  }).tokens.flat()) {
    const from = Math.max(start, token.offset);
    const to = Math.min(end, token.offset + token.content.length);
    if (from >= to) continue;
    // Newlines and indentation are not required to carry a syntax scope.
    const content = code.slice(from, to).replace(/\s/g, '');
    if (content.length === 0) continue;
    assert.ok(
      allowed.includes(kindOfColor(token.color) ?? ''),
      `${JSON.stringify(text)}: ${JSON.stringify(content)} is ${kindOfColor(token.color)}, expected ${allowed.join(' or ')}`
    );
    covered += content.length;
  }
  assert.equal(
    covered,
    text.replace(/\s/g, '').length,
    'entire range classified'
  );
}

void t.test(
  'kdl: node, argument, property and child positions have distinct scopes',
  () => {
    const code =
      'root bare key=value 42 { child #true; sibling; }\nafter #null\n';
    checkInvariants(kdl.hl, code);
    for (const name of ['root', 'child', 'sibling', 'after']) {
      assertKind(code, name, 'tag');
    }
    assertKind(code, 'bare', 'string');
    assertKind(code, 'key', 'attribute');
    assertKind(code, 'value', 'string');
    assertKind(code, '42', 'number');
    assertKind(code, '#true', 'boolean');
    assertKind(code, '#null', 'constant.builtin');
  }
);

void t.test(
  'kdl: quoted and raw strings retain the role of names and keys',
  () => {
    const code =
      '"quoted node" "quoted key"="value"\n#"raw node"# ##"raw key"##=bare\nr#"v1 node"# r##"v1 key"##="legacy"\n';
    checkInvariants(kdl.hl, code);
    for (const name of ['"quoted node"', '#"raw node"#', 'r#"v1 node"#']) {
      assertKind(code, name, 'tag');
    }
    for (const key of ['"quoted key"', '##"raw key"##', 'r##"v1 key"##']) {
      assertKind(code, key, 'attribute');
    }
    for (const value of ['"value"', 'bare', '"legacy"']) {
      assertKind(code, value, 'string');
    }
  }
);

void t.test('kdl: types annotate nodes, arguments and property values', () => {
  const code =
    '(document)root (i64)-42 key=("custom type")"value" {\n  ( #"child type"# ) leaf ( u8 ) 255\n}\n';
  checkInvariants(kdl.hl, code);
  for (const type of [
    'document',
    'i64',
    '"custom type"',
    '#"child type"#',
    'u8',
  ]) {
    assertKind(code, type, 'type');
  }
  assertKind(code, 'root', 'tag');
  assertKind(code, 'leaf', 'tag');
  assertKind(code, 'key', 'attribute');
  assertKind(code, '-42', 'number');
  assertKind(code, '255', 'number');
  assertKind(code, '"value"', 'string');
});

void t.test(
  'kdl: v2 keywords and v1 literals use the documented scopes',
  () => {
    for (const literal of ['#true', '#false', 'true', 'false']) {
      assertKind(`node ${literal}\n`, literal, 'boolean');
    }
    for (const literal of ['#null', '#inf', '#-inf', '#nan', 'null']) {
      assertKind(`node ${literal}\n`, literal, 'constant.builtin');
    }
    // Literal recognition must not consume a prefix of a string or a name.
    const code =
      'true-node trueish falsehood nullish infinity\nfalse-node null-key=nanosecond\n';
    for (const name of ['true-node', 'false-node'])
      assertKind(code, name, 'tag');
    assertKind(code, 'null-key', 'attribute');
    for (const value of [
      'trueish',
      'falsehood',
      'nullish',
      'infinity',
      'nanosecond',
    ]) {
      assertKind(code, value, 'string');
    }
  }
);

void t.test(
  'kdl: signed integers, bases, separators, fractions and exponents',
  () => {
    for (const number of [
      '0',
      '-0',
      '+42',
      '-123',
      '1_000_000',
      '0xCA_FE',
      '-0xFF',
      '+0x10',
      '0o7_55',
      '-0o10',
      '+0o17',
      '0b1010_0101',
      '-0b10',
      '+0b11',
      '1.25',
      '-0.5',
      '+1.0',
      '1e10',
      '1E+10',
      '-1.25e-3',
      '1_000.25_0e+1_0',
    ]) {
      const code = `node ${number}\n`;
      checkInvariants(kdl.hl, code);
      assertKind(code, number, 'number');
    }
  }
);

void t.test('kdl: escaped strings do not expose embedded KDL syntax', () => {
  const value =
    '"quote: \\" slash: \\\\ newline: \\n tab: \\t unicode: \\u{1F600} /- /* { key=1 }"';
  const code = `node ${value} live=#false\nnext\n`;
  checkInvariants(kdl.hl, code);
  assertKind(code, value, ['string', 'string.escape']);
  assertKind(code, 'live', 'attribute');
  assertKind(code, '#false', 'boolean');
  assertKind(code, 'next', 'tag');
});

void t.test(
  'kdl: v2 and v1 raw strings close only at their matching hash count',
  () => {
    for (const value of [
      '#"literal \\n \\" /* /- {}"#',
      '##"inside "# is not the close; \\u{41}"##',
      'r#"legacy \\n \\" // text"#',
      'r###"inside "## still raw"###',
    ]) {
      const code = `node ${value} live=42\nnext\n`;
      checkInvariants(kdl.hl, code);
      assertKind(code, value, 'string');
      assertKind(code, 'live', 'attribute');
      assertKind(code, '42', 'number');
      assertKind(code, 'next', 'tag');
    }
  }
);

void t.test(
  'kdl: multiline and raw multiline strings preserve state across lines',
  () => {
    for (const value of [
      '"""\n  first \\n\n  second "quote" /* text */\n  """',
      '##"""\n  raw \\n """# does not close\n  /- literal { child; }\n  """##',
      'r#"first\nsecond // legacy raw multiline"#',
    ]) {
      const code = `node ${value} live=#true\nnext\n`;
      checkInvariants(kdl.hl, code);
      assertKind(code, value, ['string', 'string.escape']);
      assertKind(code, 'live', 'attribute');
      assertKind(code, 'next', 'tag');
      assertLineFedParity('kdl', code);
    }
  }
);

void t.test(
  'kdl: nested block comments and line comments do not leak syntax',
  () => {
    const comment = '/* outer\n /* inner { /- fake key=42; } */\n tail */';
    const code = `${comment}\nroot /* entry /* nested */ tail */ 7 // line { /-\nnext\n`;
    checkInvariants(kdl.hl, code);
    assertKind(code, comment, 'comment');
    assertKind(code, '/* entry /* nested */ tail */', 'comment');
    assertKind(code, '// line { /-', 'comment');
    assertKind(code, 'root', 'tag');
    assertKind(code, '7', 'number');
    assertKind(code, 'next', 'tag');
    assertLineFedParity('kdl', code);
  }
);

void t.test(
  'kdl: slashdash suppresses an entire typed node and its descendants',
  () => {
    const suppressed =
      '/- (hidden)gone key="};" {\n  child #true { grandchild; }\n  /- nested "ignored"\n}';
    const code = `${suppressed}\nlive value=42\n`;
    checkInvariants(kdl.hl, code);
    assertKind(code, suppressed, 'comment');
    assertKind(code, 'live', 'tag');
    assertKind(code, 'value', 'attribute');
    assertKind(code, '42', 'number');
    assertLineFedParity('kdl', code);
  }
);

void t.test(
  'kdl: slashdash suppresses exactly one argument or whole property',
  () => {
    for (const suppressed of [
      '/- (i64)-42',
      '/- #"raw } ; /-"#',
      '/- gone=(kind)"value"',
      '/- "quoted key"=##"raw "# text"##',
      '/- gone="""\n  hidden\n  """',
    ]) {
      const code = `root ${suppressed} live=#true 7\nnext\n`;
      checkInvariants(kdl.hl, code);
      assertKind(code, suppressed, 'comment');
      assertKind(code, 'root', 'tag');
      assertKind(code, 'live', 'attribute');
      assertKind(code, '#true', 'boolean');
      assertKind(code, '7', 'number');
      assertKind(code, 'next', 'tag');
      assertLineFedParity('kdl', code);
    }
  }
);

void t.test(
  'kdl: slashdash children block preserves the following live children block',
  () => {
    const suppressed = '/- { gone "}"; nested { deep; } }';
    const code = `root ${suppressed} { live #false; }\nnext\n`;
    checkInvariants(kdl.hl, code);
    assertKind(code, suppressed, 'comment');
    assertKind(code, 'root', 'tag');
    assertKind(code, 'live', 'tag');
    assertKind(code, '#false', 'boolean');
    assertKind(code, 'next', 'tag');
    assertLineFedParity('kdl', code);
  }
);

void t.test('kdl: line continuations retain the node entry context', () => {
  const code =
    'root first \\ // continuation\n  second key=(u8)42 \\ /* comment */\n  third\nnext\n';
  checkInvariants(kdl.hl, code);
  for (const value of ['first', 'second', 'third'])
    assertKind(code, value, 'string');
  assertKind(code, 'key', 'attribute');
  assertKind(code, 'u8', 'type');
  assertKind(code, '42', 'number');
  assertKind(code, 'next', 'tag');
  assertLineFedParity('kdl', code);
});

void t.test(
  'kdl: Unicode names, HTML specials and all source bytes stay lossless',
  () => {
    const code = '日本語 λ😀 clé="<tag>&amp; > 😀" { 子 "é"; }\n';
    checkInvariants(kdl.hl, code);
    assertKind(code, '日本語', 'tag');
    assertKind(code, 'λ😀', 'string');
    assertKind(code, 'clé', 'attribute');
    assertKind(code, '"<tag>&amp; > 😀"', 'string');
    assertKind(code, '子', 'tag');
    assertLineFedParity('kdl', code);
  }
);

void t.test(
  'kdl: malformed EOF is lossless and does not poison a later document',
  () => {
    const pristine = kdl.hl(samples.kdl.code);
    for (const code of [
      'node "unterminated\\',
      'node #"unterminated',
      'node r##"unterminated"#',
      'node """\n  unterminated',
      'node ##"""\n  unterminated"""#',
      '/* outer /* inner */',
      '/- gone { child { deep',
      'node /- key=(type)',
      'node key=',
      '(unfinished',
      'node \\',
    ]) {
      checkInvariants(kdl.hl, code);
      assert.equal(kdl.hl(samples.kdl.code), pristine, JSON.stringify(code));
      assertLineFedParity('kdl', code);
    }
  }
);
