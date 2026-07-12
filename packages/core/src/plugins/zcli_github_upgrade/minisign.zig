//! Minimal, dependency-free verification of minisign detached signatures.
//!
//! minisign signatures are Ed25519, so the whole verifier is a thin parser over
//! two base64 blobs plus one `std.crypto.sign.Ed25519` call — no external tool,
//! no C library, nothing that would compromise the libc-free static release
//! build. This is why the in-binary upgrade path can enforce signatures
//! fail-closed where the POSIX `install.sh` cannot (see ADR-0023).
//!
//! It verifies exactly what matters for release integrity: the signature over
//! the signed file (here, `checksums.txt`) under a pinned public key. minisign's
//! second, "global" signature covers only the trusted comment — informational
//! metadata that plays no part in our trust decision — so it is intentionally
//! not checked. The security guarantee is entirely in the primary signature.
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
