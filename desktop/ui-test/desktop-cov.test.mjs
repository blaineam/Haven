// The coverage script's one non-trivial piece of logic: finding `#[cfg(test)]` items in Rust source
// so an inline test module never counts as the product's own code.
import test from 'node:test';
import assert from 'node:assert/strict';
import { cfgTestRanges } from '../../Scripts/desktop-cov.mjs';

test('a cfg(test) module is found by its braces', () => {
  const src = ['fn a() {}', '', '#[cfg(test)]', 'mod tests {', '    fn t() { let x = 1; }', '}', 'fn b() {}'].join('\n');
  assert.deepEqual(cfgTestRanges(src), [[3, 6]]);
});

test('braces inside strings, chars, raw strings and comments do not end the module early', () => {
  const src = [
    '#[cfg(test)]',
    'mod tests {',
    '    const A: &str = "}";',
    "    const B: char = '}';",
    '    const C: &str = r#"} "quoted" {"#;',
    '    // } in a comment',
    '    /* } in a block */',
    "    fn lt<'a>(x: &'a str) -> &'a str { x }",
    '}',
    'fn after() {}',
  ].join('\n');
  assert.deepEqual(cfgTestRanges(src), [[1, 9]]);
});

test('out-of-line modules, single items and several blocks are all found', () => {
  const src = ['#[cfg(test)]', '#[path = "x.rs"]', 'mod x;', 'fn keep() {}', '#[cfg(test)]', 'use foo::bar;', '#[cfg(test)]', 'impl A {', '  fn f() {}', '}'].join('\n');
  assert.deepEqual(cfgTestRanges(src), [[1, 3], [5, 6], [7, 10]]);
});

test('source with no test code yields nothing', () => {
  assert.deepEqual(cfgTestRanges('fn main() { println!("{}", 1); }\n'), []);
});
