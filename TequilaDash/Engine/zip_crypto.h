#ifndef ZIP_CRYPTO_H
#define ZIP_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

/// PBKDF2-HMAC-SHA1. Returns 0 on success.
int zip_pbkdf2_sha1(
    const uint8_t *password, size_t password_len,
    const uint8_t *salt, size_t salt_len,
    unsigned rounds,
    uint8_t *out, size_t out_len
);

/// AES-128/192/256 ECB encrypt of a single 16-byte block. Returns 0 on success.
int zip_aes_ecb_encrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t in[16],
    uint8_t out[16]
);

/// HMAC-SHA1 into 20-byte `out`.
void zip_hmac_sha1(
    const uint8_t *key, size_t key_len,
    const uint8_t *data, size_t data_len,
    uint8_t out[20]
);

/// 7-Zip AES-256-CBC (SHA-256 KDF). Password is UTF-16LE without BOM.
/// Returns 0 on success, negative on error.
int sevenz_aes_decrypt(
    const uint8_t *properties, size_t properties_len,
    const uint8_t *password_utf16le, size_t password_len,
    const uint8_t *ciphertext, size_t ciphertext_len,
    uint8_t *out, size_t out_cap, size_t *out_len
);

#endif
