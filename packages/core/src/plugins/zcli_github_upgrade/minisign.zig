//! Minimal, dependency-free verification of minisign detached signatures.
//!
//! minisign signatures are Ed25519, so the whole verifier is a thin parser over
//! two base64 blobs plus one `std.crypto.sign.Ed25519` call — no external tool,
//! no C library, nothing that would compromise the libc-free static release
//! build. This is why the in-binary upgrade path can enforce signatures
//! fail-closed where the POSIX `install.sh` cannot (see ADR-0023).
//!
//! It verifies exactly what matters for release integrity: the signature over
//! the signed file (here, `checksums.txt`) under a pinned public key. That
//! primary signature is the core guarantee — a tampered `checksums.txt` cannot
//! survive it.
//!
//! The primary signature alone is version-agnostic, though: `checksums.txt`
//! names the artifacts but not the release they belong to, so a compromised
//! publisher could replay an *older*, genuinely-signed release under a newer
//! tag (a downgrade / rollback attack — CWE-294). To close that, this module
//! also verifies minisign's second, "global" signature, which covers the
//! trusted comment. The signing ceremony embeds the release tag in that comment
//! (`scripts/sign-release.sh`: `-t "zcli <tag> — signed release checksums"`),
//! so `verifyTrustedComment` authenticates the comment under the same pinned
//! key and asserts it binds the tag being installed. The comment is only
//! trusted once its global signature checks out — reading it unverified would
//! defeat the point.
//!
//! Both minisign signature algorithms are accepted so verification never depends
//! on which minisign version cut the release:
//!   - "ED" — prehashed: Ed25519 over BLAKE2b-512(file). minisign's default.
//!   - "Ed" — legacy:    Ed25519 over the raw file bytes (`minisign -S -l`).

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const base64 = std.base64.standard;

/// Public-key blob length: 2-byte algorithm id + 8-byte key id + 32-byte key.
const public_key_blob_len = 2 + 8 + 32;
/// Signature-line blob length: 2-byte algorithm id + 8-byte key id + 64-byte sig.
const signature_blob_len = 2 + 8 + 64;
/// The fixed prefix minisign writes before the trusted-comment text on line 3.
const trusted_comment_prefix = "trusted comment: ";

/// The two-byte algorithm markers minisign writes into its blobs.
const alg_pubkey = "Ed".*; // public keys are always tagged "Ed"
const alg_legacy = "Ed".*; // Ed25519 over the raw file
const alg_prehashed = "ED".*; // Ed25519 over BLAKE2b-512(file)

pub const ParseError = error{
    /// The base64 blob was malformed or the wrong decoded length.
    MalformedKey,
    /// The public key did not carry minisign's "Ed" algorithm marker.
    UnsupportedKeyAlgorithm,
};

pub const VerifyError = error{
    /// The `.minisig` body was malformed or the signature blob the wrong length.
    MalformedSignature,
    /// The signature's algorithm marker was neither "Ed" nor "ED".
    UnsupportedSignatureAlgorithm,
    /// The signature was made by a different key than the one pinned. Caught
    /// early to give a clearer error than a bare cryptographic failure.
    KeyMismatch,
    /// The signature is not valid for this data under this key. The load-bearing
    /// check — this is what a tampered `checksums.txt` fails on.
    SignatureMismatch,
    /// The trusted-comment line (line 3) or its global-signature line (line 4)
    /// was missing or the wrong shape — e.g. no `trusted comment: ` prefix or a
    /// global signature that isn't 64 base64-decoded bytes.
    MalformedTrustedComment,
    /// The trusted comment is present but its global signature does not verify
    /// under the pinned key. The comment's contents cannot be trusted, so the
    /// version binding it carries is worthless — fail closed.
    TrustedCommentSignatureMismatch,
    /// The trusted comment verified, but it does not bind the release tag being
    /// installed. This is the downgrade/rollback guard: an older but genuinely
    /// signed release replayed under a newer tag is rejected here.
    VersionMismatch,
};

/// A parsed, pinned minisign public key.
pub const PublicKey = struct {
    key_id: [8]u8,
    key: Ed25519.PublicKey,

    /// Parse the base64 line of a minisign `.pub` file (its second line, or the
    /// argument to `minisign -P`). The leading "untrusted comment:" line is not
    /// part of this — pass only the base64 blob.
    pub fn parse(blob_base64: []const u8) ParseError!PublicKey {
        const trimmed = std.mem.trim(u8, blob_base64, " \t\r\n");

        var blob: [public_key_blob_len]u8 = undefined;
        decodeExact(&blob, trimmed) catch return ParseError.MalformedKey;

        if (!std.mem.eql(u8, blob[0..2], &alg_pubkey)) return ParseError.UnsupportedKeyAlgorithm;

        const key = Ed25519.PublicKey.fromBytes(blob[10..42].*) catch return ParseError.MalformedKey;
        return .{ .key_id = blob[2..10].*, .key = key };
    }
};

/// Verify a minisign detached signature over `signed_data` under `public_key`.
///
/// `signature_file` is the full contents of the `.minisig` file. `signed_data`
/// is the exact bytes that were signed (the `checksums.txt` body). Returns
/// normally only when the signature is valid; every other outcome is an error,
/// so callers get fail-closed behavior for free.
pub fn verify(public_key: PublicKey, signature_file: []const u8, signed_data: []const u8) VerifyError!void {
    // minisign's format is fixed: line 1 is an untrusted comment, line 2 is the
    // base64 signature blob (lines 3-4 are the trusted comment and its global
    // signature, which we do not use).
    var lines = std.mem.splitScalar(u8, signature_file, '\n');
    _ = lines.next() orelse return VerifyError.MalformedSignature; // comment
    const sig_line = lines.next() orelse return VerifyError.MalformedSignature;

    var blob: [signature_blob_len]u8 = undefined;
    decodeExact(&blob, std.mem.trim(u8, sig_line, " \t\r\n")) catch return VerifyError.MalformedSignature;

    const algorithm = blob[0..2];
    const key_id = blob[2..10];
    const signature = Ed25519.Signature.fromBytes(blob[10..74].*);

    if (!std.mem.eql(u8, key_id, &public_key.key_id)) return VerifyError.KeyMismatch;

    if (std.mem.eql(u8, algorithm, &alg_prehashed)) {
        var digest: [Blake2b512.digest_length]u8 = undefined;
        Blake2b512.hash(signed_data, &digest, .{});
        signature.verify(&digest, public_key.key) catch return VerifyError.SignatureMismatch;
    } else if (std.mem.eql(u8, algorithm, &alg_legacy)) {
        signature.verify(signed_data, public_key.key) catch return VerifyError.SignatureMismatch;
    } else {
        return VerifyError.UnsupportedSignatureAlgorithm;
    }
}

/// Verify minisign's global signature over the trusted comment and assert the
/// comment binds `expected_tag`.
///
/// The primary `verify` above proves `checksums.txt` is authentic, but that file
/// carries no version — so a compromised publisher can replay an older, validly
/// signed release under a newer tag and pass `verify` (CWE-294 downgrade). The
/// signing ceremony defends against this by putting the release tag in minisign's
/// trusted comment, which is covered by a *second* ("global") Ed25519 signature
/// on line 4 of the `.minisig`. minisign computes that global signature over the
/// 64-byte primary signature concatenated with the raw trusted-comment text, so
/// we reconstruct exactly those bytes and verify them under the same pinned key.
///
/// Only after the comment is authenticated do we trust its contents: we require
/// `expected_tag` to appear as a whole whitespace-delimited token (so `-v0.2`
/// cannot masquerade as `-v0.20.0`). `signature_file` is the full `.minisig`
/// body; `expected_tag` is the release tag being installed, e.g. `zcli-v0.20.0`.
/// Returns normally only on a match; every other outcome is an error, so callers
/// get fail-closed version binding for free.
pub fn verifyTrustedComment(
    public_key: PublicKey,
    signature_file: []const u8,
    expected_tag: []const u8,
) VerifyError!void {
    var lines = std.mem.splitScalar(u8, signature_file, '\n');
    _ = lines.next() orelse return VerifyError.MalformedSignature; // untrusted comment
    const sig_line = lines.next() orelse return VerifyError.MalformedSignature;
    const comment_line = lines.next() orelse return VerifyError.MalformedTrustedComment;
    const global_sig_line = lines.next() orelse return VerifyError.MalformedTrustedComment;

    // Line 2 again: the global signature commits to its raw 64-byte signature,
    // not the algorithm/key-id header, so extract just that tail.
    var blob: [signature_blob_len]u8 = undefined;
    decodeExact(&blob, std.mem.trim(u8, sig_line, " \t\r\n")) catch return VerifyError.MalformedSignature;
    const primary_signature = blob[10..74];

    // Line 3: `trusted comment: <text>`. The signed message is <text> exactly —
    // no prefix, no trailing newline. Only a stray CR is stripped (\n was the
    // line split); interior bytes are part of what minisign signed.
    const comment = std.mem.trimEnd(u8, comment_line, "\r");
    if (!std.mem.startsWith(u8, comment, trusted_comment_prefix)) return VerifyError.MalformedTrustedComment;
    const trusted_comment = comment[trusted_comment_prefix.len..];

    // Line 4: base64 of the 64-byte global Ed25519 signature.
    var global_sig_bytes: [64]u8 = undefined;
    decodeExact(&global_sig_bytes, std.mem.trim(u8, global_sig_line, " \t\r\n")) catch return VerifyError.MalformedTrustedComment;
    const global_sig = Ed25519.Signature.fromBytes(global_sig_bytes);

    // Verify Ed25519(primary_signature || trusted_comment) under the pinned key,
    // streaming the two segments so no concatenation buffer is needed.
    var verifier = global_sig.verifier(public_key.key) catch return VerifyError.TrustedCommentSignatureMismatch;
    verifier.update(primary_signature);
    verifier.update(trusted_comment);
    verifier.verify() catch return VerifyError.TrustedCommentSignatureMismatch;

    // The comment is now authentic; bind the version it carries.
    if (!trustedCommentHasTag(trusted_comment, expected_tag)) return VerifyError.VersionMismatch;
}

/// True when `expected_tag` appears in `comment` as a whole whitespace-delimited
/// token. Token-exact (not substring) so a shorter tag like `zcli-v0.2` can't be
/// satisfied by a longer one like `zcli-v0.20.0`.
fn trustedCommentHasTag(comment: []const u8, expected_tag: []const u8) bool {
    if (expected_tag.len == 0) return false;
    var tokens = std.mem.tokenizeAny(u8, comment, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, expected_tag)) return true;
    }
    return false;
}

/// Base64-decode `src` into `dst`, requiring the decoded length to be exactly
/// `dst.len`. minisign blobs are fixed-size, so any other length is malformed.
fn decodeExact(dst: []u8, src: []const u8) !void {
    if ((try base64.Decoder.calcSizeForSlice(src)) != dst.len) return error.WrongLength;
    try base64.Decoder.decode(dst, src);
}

// ============================================================================
// Tests
//
// Fixtures were produced by minisign 0.12 over this exact `checksums.txt`:
//     abc123  zcli-x86_64-linux
//     def456  zcli-aarch64-macos
// with a throwaway keypair. The signatures are real minisign output — these
// tests prove the pure-Zig verifier accepts genuine minisign artifacts, in both
// the default prehashed ("ED") and legacy ("Ed") formats.
// ============================================================================

const test_pubkey = "RWRvG5gVNm3fQ3kUZ7+0v2CyupuxrdqlPP+E2DAbYqVi5Msnb7ITBah+";

const test_checksums = "abc123  zcli-x86_64-linux\ndef456  zcli-aarch64-macos\n";

const test_sig_prehashed =
    "untrusted comment: signature from minisign secret key\n" ++
    "RURvG5gVNm3fQ3x/RKJBNezC4n+PUTp5CY87HNpU6vDZVxVDtOcF3mSeqIneSiPfKQmwk1czB+nTwXY/55JyUjO5p6SKvmebIQs=\n" ++
    "trusted comment: zcli test release 0.0.0\n" ++
    "XVcRgBG5hS8H1mckUiHcmeFr2u6lmzBKu3qFKDDLzPLrlKq9I4KRRkF6GNw9WhY5NHa02h86n1NbCIK8PjV7Dw==\n";

const test_sig_legacy =
    "untrusted comment: signature from minisign secret key\n" ++
    "RWRvG5gVNm3fQ5boMg3KOe7wdgyRenr9DLlPMNJgUCfGX0Dz0jZPEnwR4mpGh+S5VorDwEciRo2omodWF6VqpK8EJNjK55BWygw=\n" ++
    "trusted comment: zcli legacy test\n" ++
    "trusted-comment-global-sig-unused-by-verifier==\n";

test "parse - a real minisign public key" {
    const pk = try PublicKey.parse(test_pubkey);
    // Key id 6f1b9815366ddf43, stored little-endian in the blob.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x6f, 0x1b, 0x98, 0x15, 0x36, 0x6d, 0xdf, 0x43 }, &pk.key_id);
}

test "parse - tolerates surrounding whitespace" {
    const pk = try PublicKey.parse("  " ++ test_pubkey ++ " \n");
    try std.testing.expect(pk.key_id.len == 8);
}

test "parse - rejects garbage and wrong-length blobs" {
    try std.testing.expectError(ParseError.MalformedKey, PublicKey.parse("not base64 !!!"));
    try std.testing.expectError(ParseError.MalformedKey, PublicKey.parse("aGVsbG8=")); // valid b64, wrong length
    try std.testing.expectError(ParseError.MalformedKey, PublicKey.parse(""));
}

test "verify - accepts a genuine prehashed (default) signature" {
    const pk = try PublicKey.parse(test_pubkey);
    try verify(pk, test_sig_prehashed, test_checksums);
}

test "verify - accepts a genuine legacy signature" {
    const pk = try PublicKey.parse(test_pubkey);
    try verify(pk, test_sig_legacy, test_checksums);
}

test "verify - rejects tampered content" {
    const pk = try PublicKey.parse(test_pubkey);
    const tampered = "abc123  zcli-x86_64-linux\nBADBAD  zcli-aarch64-macos\n";
    try std.testing.expectError(VerifyError.SignatureMismatch, verify(pk, test_sig_prehashed, tampered));
    try std.testing.expectError(VerifyError.SignatureMismatch, verify(pk, test_sig_legacy, tampered));
    // A single flipped byte, and truncation, both fail closed.
    try std.testing.expectError(VerifyError.SignatureMismatch, verify(pk, test_sig_prehashed, test_checksums[0 .. test_checksums.len - 1]));
}

test "verify - rejects a signature from a different key (key id mismatch)" {
    // Flip the pinned key id so it no longer matches the signature's.
    var pk = try PublicKey.parse(test_pubkey);
    pk.key_id[0] ^= 0xff;
    try std.testing.expectError(VerifyError.KeyMismatch, verify(pk, test_sig_prehashed, test_checksums));
}

test "verify - a valid signature but wrong pinned key fails closed" {
    // Same key id, different public key bytes: a signature that verified against
    // the real key must not verify against an imposter with a colliding id.
    var pk = try PublicKey.parse(test_pubkey);
    pk.key.bytes[0] ^= 0xff;
    try std.testing.expectError(VerifyError.SignatureMismatch, verify(pk, test_sig_prehashed, test_checksums));
}

test "verify - malformed signature files" {
    const pk = try PublicKey.parse(test_pubkey);
    try std.testing.expectError(VerifyError.MalformedSignature, verify(pk, "", test_checksums));
    try std.testing.expectError(VerifyError.MalformedSignature, verify(pk, "only one line\n", test_checksums));
    try std.testing.expectError(VerifyError.MalformedSignature, verify(pk, "comment\nnot-valid-base64!\n", test_checksums));
}

test "verify - rejects an unknown signature algorithm" {
    const pk = try PublicKey.parse(test_pubkey);
    // Re-encode the prehashed blob with its algorithm bytes clobbered to "Xx".
    var blob: [signature_blob_len]u8 = undefined;
    var lines = std.mem.splitScalar(u8, test_sig_prehashed, '\n');
    _ = lines.next();
    try decodeExact(&blob, lines.next().?);
    blob[0] = 'X';
    blob[1] = 'x';
    var encoded: [base64.Encoder.calcSize(signature_blob_len)]u8 = undefined;
    _ = base64.Encoder.encode(&encoded, &blob);
    var buf: [512]u8 = undefined;
    const forged = try std.fmt.bufPrint(&buf, "comment\n{s}\n", .{encoded});
    try std.testing.expectError(VerifyError.UnsupportedSignatureAlgorithm, verify(pk, forged, test_checksums));
}

// ----------------------------------------------------------------------------
// Trusted-comment / version-binding tests.
//
// `test_sig_prehashed` carries a REAL minisign global signature over its trusted
// comment ("zcli test release 0.0.0"), so these tests exercise the genuine
// global-signature path — not a mock. The production signing ceremony writes the
// release tag as a token in that comment (`zcli zcli-vX.Y.Z — signed ...`), so a
// token match against the comment is exactly the version binding we enforce.
// ----------------------------------------------------------------------------

// The three body lines of `test_sig_prehashed`, split out so tamper tests can
// rebuild the file with one line changed.
const tc_sig_line = "RURvG5gVNm3fQ3x/RKJBNezC4n+PUTp5CY87HNpU6vDZVxVDtOcF3mSeqIneSiPfKQmwk1czB+nTwXY/55JyUjO5p6SKvmebIQs=";
const tc_comment_line = "trusted comment: zcli test release 0.0.0";
const tc_global_sig_line = "XVcRgBG5hS8H1mckUiHcmeFr2u6lmzBKu3qFKDDLzPLrlKq9I4KRRkF6GNw9WhY5NHa02h86n1NbCIK8PjV7Dw==";

test "verifyTrustedComment - accepts a genuine comment binding the expected token" {
    const pk = try PublicKey.parse(test_pubkey);
    // The tag token the ceremony would embed; here the version token in the
    // real fixture comment ("zcli test release 0.0.0").
    try verifyTrustedComment(pk, test_sig_prehashed, "0.0.0");
    // Any whole token matches (the real ceremony's token is `zcli-vX.Y.Z`).
    try verifyTrustedComment(pk, test_sig_prehashed, "zcli");
}

test "verifyTrustedComment - rejects a version mismatch (downgrade guard)" {
    const pk = try PublicKey.parse(test_pubkey);
    // A different version than the (authentic) comment binds -> reject.
    try std.testing.expectError(VerifyError.VersionMismatch, verifyTrustedComment(pk, test_sig_prehashed, "1.0.0"));
    // Token-exact, so a substring of a real token is NOT a match.
    try std.testing.expectError(VerifyError.VersionMismatch, verifyTrustedComment(pk, test_sig_prehashed, "0.0"));
    try std.testing.expectError(VerifyError.VersionMismatch, verifyTrustedComment(pk, test_sig_prehashed, ""));
}

test "verifyTrustedComment - rejects a rewritten trusted comment (global sig fails)" {
    const pk = try PublicKey.parse(test_pubkey);
    // Swap the comment for an attacker-chosen newer version while keeping the
    // genuine global signature. Because the global sig covers the comment, it no
    // longer verifies — the version cannot be forged by editing the text.
    var buf: [512]u8 = undefined;
    const forged = try std.fmt.bufPrint(&buf, "untrusted comment: x\n{s}\ntrusted comment: zcli test release 9.9.9\n{s}\n", .{ tc_sig_line, tc_global_sig_line });
    try std.testing.expectError(VerifyError.TrustedCommentSignatureMismatch, verifyTrustedComment(pk, forged, "9.9.9"));
}

test "verifyTrustedComment - rejects a wrong-but-well-formed global signature" {
    const pk = try PublicKey.parse(test_pubkey);
    // Genuine comment, but the global signature is a valid-length 64-byte blob of
    // the wrong bytes -> fails closed as a signature mismatch, not accepted.
    var zero_sig: [64]u8 = @splat(0);
    var encoded: [base64.Encoder.calcSize(64)]u8 = undefined;
    _ = base64.Encoder.encode(&encoded, &zero_sig);
    var buf: [512]u8 = undefined;
    const forged = try std.fmt.bufPrint(&buf, "untrusted comment: x\n{s}\n{s}\n{s}\n", .{ tc_sig_line, tc_comment_line, encoded });
    try std.testing.expectError(VerifyError.TrustedCommentSignatureMismatch, verifyTrustedComment(pk, forged, "0.0.0"));
}

test "verifyTrustedComment - rejects malformed / missing comment lines" {
    const pk = try PublicKey.parse(test_pubkey);
    // Missing the trusted-comment line entirely (only 2 lines).
    var buf: [512]u8 = undefined;
    const two_line = try std.fmt.bufPrint(&buf, "untrusted comment: x\n{s}\n", .{tc_sig_line});
    try std.testing.expectError(VerifyError.MalformedTrustedComment, verifyTrustedComment(pk, two_line, "0.0.0"));
    // Line 3 present but lacking the `trusted comment: ` prefix.
    var buf2: [512]u8 = undefined;
    const no_prefix = try std.fmt.bufPrint(&buf2, "untrusted comment: x\n{s}\nzcli test release 0.0.0\n{s}\n", .{ tc_sig_line, tc_global_sig_line });
    try std.testing.expectError(VerifyError.MalformedTrustedComment, verifyTrustedComment(pk, no_prefix, "0.0.0"));
    // Global-signature line is not valid base64 of 64 bytes (legacy fixture's
    // placeholder). Real body lines, garbage global sig.
    var buf3: [512]u8 = undefined;
    const bad_global = try std.fmt.bufPrint(&buf3, "untrusted comment: x\n{s}\n{s}\nnot-valid-base64!\n", .{ tc_sig_line, tc_comment_line });
    try std.testing.expectError(VerifyError.MalformedTrustedComment, verifyTrustedComment(pk, bad_global, "0.0.0"));
}
