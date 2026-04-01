const fle_aead = @import("fle_lib").aead;

pub const Alg = fle_aead.Alg;
pub const Error = fle_aead.Error;
pub const EnvelopeV1 = fle_aead.EnvelopeV1;
pub const max_plaintext_size = fle_aead.max_plaintext_size;
pub const makeAAD = fle_aead.makeAAD;
pub const encryptField = fle_aead.encryptField;
pub const decryptField = fle_aead.decryptField;
pub const wrapKey32 = fle_aead.wrapKey32;
pub const unwrapKey32 = fle_aead.unwrapKey32;
pub const wrapped_key_size = fle_aead.wrapped_key_size;
