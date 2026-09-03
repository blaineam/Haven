//! The one binary cursor every wire parser in this crate reads through.
//!
//! `device`, `treekem`, `friend_invite`, `enroll` and `selfsync` each carried a private
//! `Reader` that was byte-identical apart from its error strings. That duplication was not
//! free: when the cursor-overflow guard went in, it had to be written five times, and a fix
//! applied to four of them would have left the fifth quietly wrong with nothing to catch it.
//! One copy, one place to audit, one place to regress.
//!
//! **Error messages stay per-module.** `CoreError::Encoding` holds a `&'static str`, so the
//! message cannot be formatted at runtime without leaking; each module passes a [`WireTag`]
//! of its exact previous strings instead. A rejection still names *which* wire format refused
//! the bytes, which is most of a parse error's diagnostic value.
//!
//! Everything here fails closed and cannot panic on hostile input — the property
//! `tests/fuzz_wire_parsers.rs` exercises across all fifteen public parsers.

use crate::{CoreError, Result};

/// The `&'static str` messages one wire format reports, held as a const per module so the
/// text is identical to what each parser emitted before consolidation.
#[derive(Clone, Copy)]
pub(crate) struct WireTag {
    /// Ran off the end of the buffer.
    pub(crate) eoi: &'static str,
    /// A length would overflow the cursor (see [`Reader::take`]).
    pub(crate) overflow: &'static str,
    /// A length-prefixed string was not valid UTF-8.
    pub(crate) utf8: &'static str,
}

impl WireTag {
    pub(crate) const fn new(eoi: &'static str, overflow: &'static str, utf8: &'static str) -> Self {
        Self { eoi, overflow, utf8 }
    }
}

/// A forward-only, bounds-checked cursor over a byte buffer. Reads never panic: every one
/// returns `Err` rather than slicing out of range, because these buffers arrive from peers
/// and relays and a panic on attacker-supplied bytes is a remote DoS.
pub(crate) struct Reader<'a> {
    b: &'a [u8],
    i: usize,
    tag: WireTag,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(b: &'a [u8], tag: WireTag) -> Self {
        Self { b, i: 0, tag }
    }

    /// Consume exactly `n` bytes, or fail without moving the cursor.
    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        // `checked_add`, NOT `self.i + n`. DEFENSIVE, not a live bug: `n` comes from an
        // untrusted u32 length prefix, so on a 32-bit `usize` the sum would WRAP, the bounds
        // check below would pass, and the slice would panic with start > end. Every target
        // Haven ships is 64-bit, where that cannot happen — so this is unreachable, and is kept
        // because it costs one instruction and the failure mode it guards would be a SILENT
        // wrap in release. Do not read the wasm32 block in Cargo.toml as a live target: the web
        // client was abandoned 2026-06-22 and `core/haven-wasm` deleted (docs/WEB-PARITY.md).
        let end = self.i.checked_add(n).ok_or(CoreError::Encoding(self.tag.overflow))?;
        if end > self.b.len() {
            return Err(CoreError::Encoding(self.tag.eoi));
        }
        let s = &self.b[self.i..end];
        self.i = end;
        Ok(s)
    }

    pub(crate) fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    pub(crate) fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub(crate) fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    /// A fixed-size array read. `N` is a compile-time constant, so the `try_into` cannot fail.
    pub(crate) fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().unwrap())
    }

    pub(crate) fn array32(&mut self) -> Result<[u8; 32]> {
        self.array::<32>()
    }

    /// A `u32` length prefix followed by that many bytes — the crate's one length-prefix shape,
    /// written by [`lp`]. The count is untrusted, and `take` bounds it.
    pub(crate) fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }

    pub(crate) fn str_lp(&mut self) -> Result<String> {
        let utf8 = self.tag.utf8;
        let b = self.bytes_lp()?;
        String::from_utf8(b.to_vec()).map_err(|_| CoreError::Encoding(utf8))
    }

    /// The unread remainder, without consuming it. Used where a trailing variable-length field
    /// (a hybrid signature) runs to the end of the buffer.
    pub(crate) fn rest(&self) -> &'a [u8] {
        &self.b[self.i..]
    }

    /// Has the buffer been consumed EXACTLY? `treekem`'s formats are terminal, so a parse that
    /// leaves trailing bytes is rejected rather than ignoring them.
    pub(crate) fn done(&self) -> bool {
        self.i == self.b.len()
    }
}

/// Append `b` as a `u32` length prefix followed by its bytes — the encode half of
/// [`Reader::bytes_lp`]. Was a private copy in `treekem`, `friend_invite` and `enroll`.
pub(crate) fn lp(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: WireTag = WireTag::new("test: eoi", "test: overflow", "test: utf8");

    /// A length that would overflow the cursor must error, not wrap into a backwards slice.
    /// `usize::MAX` overflows at any word size, so this exercises the guard on a 64-bit host.
    #[test]
    fn take_rejects_a_length_that_would_overflow_the_cursor() {
        let buf = [0u8; 64];
        let mut r = Reader::new(&buf, T);
        r.take(8).expect("first read is in bounds");

        assert!(r.take(usize::MAX).is_err(), "overflowing length must error, not wrap");
        assert!(r.take(1000).is_err(), "over-long length must fail the bounds check");
        // Neither failure may consume: a partial take would desynchronise the parse and shift
        // every field after the rejected one.
        assert_eq!(r.rest().len(), 56, "a failed take must not advance the cursor");
    }

    /// The per-module tag must reach the error, or consolidating the readers would have cost
    /// every parse error its "which format rejected this" half.
    #[test]
    fn errors_carry_the_calling_modules_tag() {
        let buf = [0u8; 8];
        let mut r = Reader::new(&buf, T);
        match r.take(99) {
            Err(CoreError::Encoding(m)) => assert_eq!(m, "test: eoi"),
            other => panic!("expected the tagged eoi error, got {other:?}"),
        }
        // The cursor must be ADVANCED for `usize::MAX` to overflow the add — at i = 0 the sum is
        // simply `usize::MAX`, which fails the bounds check instead and reports eoi. Getting this
        // wrong is how the first version of this test asserted the wrong error.
        r.take(4).expect("advance the cursor so the add can overflow");
        match r.take(usize::MAX) {
            Err(CoreError::Encoding(m)) => assert_eq!(m, "test: overflow"),
            other => panic!("expected the tagged overflow error, got {other:?}"),
        }
        // A bad UTF-8 string must report the module's utf8 tag, not a generic one.
        let mut bad = Vec::new();
        lp(&mut bad, &[0xFF, 0xFE]);
        let mut r2 = Reader::new(&bad, T);
        match r2.str_lp() {
            Err(CoreError::Encoding(m)) => assert_eq!(m, "test: utf8"),
            other => panic!("expected the tagged utf8 error, got {other:?}"),
        }
    }

    /// `lp` and `bytes_lp` are inverses — the encode/decode pair the whole crate leans on.
    #[test]
    fn lp_and_bytes_lp_round_trip() {
        let mut out = Vec::new();
        lp(&mut out, b"hello");
        lp(&mut out, b"");
        let mut r = Reader::new(&out, T);
        assert_eq!(r.bytes_lp().unwrap(), b"hello");
        assert_eq!(r.bytes_lp().unwrap(), b"");
        assert!(r.done(), "both fields consumed exactly");
    }

    /// Every accessor is bounds-checked, fixed-size ones included — a 3-byte buffer must
    /// refuse all of them rather than reading past the end.
    #[test]
    fn short_buffers_fail_closed_on_every_accessor() {
        let short = [1u8, 2, 3];
        assert!(Reader::new(&short, T).u32().is_err(), "u32 needs 4 bytes");
        assert!(Reader::new(&short, T).u64().is_err(), "u64 needs 8 bytes");
        assert!(Reader::new(&short, T).array32().is_err(), "array32 needs 32 bytes");
        assert!(Reader::new(&short, T).bytes_lp().is_err(), "bytes_lp needs its 4-byte prefix");
        assert!(Reader::new(&short, T).str_lp().is_err(), "str_lp needs its 4-byte prefix");
        // u8 is the one read a 3-byte buffer can satisfy — proving the others fail for want of
        // length, not because every call errors unconditionally.
        assert_eq!(Reader::new(&short, T).u8().unwrap(), 1);
    }
}
