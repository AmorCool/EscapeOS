#include "zip_crypto.h"
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonDigest.h>
#include <string.h>

int zip_pbkdf2_sha1(
    const uint8_t *password, size_t password_len,
    const uint8_t *salt, size_t salt_len,
    unsigned rounds,
    uint8_t *out, size_t out_len
) {
    int rc = CCKeyDerivationPBKDF(
        kCCPBKDF2,
        (const char *)password,
        password_len,
        salt,
        salt_len,
        kCCPRFHmacAlgSHA1,
        rounds,
        out,
        out_len
    );
    return rc == kCCSuccess ? 0 : -1;
}

int zip_aes_ecb_encrypt(
    const uint8_t *key, size_t key_len,
    const uint8_t in[16],
    uint8_t out[16]
) {
    size_t moved = 0;
    CCCryptorStatus rc = CCCrypt(
        kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionECBMode,
        key,
        key_len,
        NULL,
        in,
        16,
        out,
        16,
        &moved
    );
    return (rc == kCCSuccess && moved == 16) ? 0 : -1;
}

void zip_hmac_sha1(
    const uint8_t *key, size_t key_len,
    const uint8_t *data, size_t data_len,
    uint8_t out[20]
) {
    CCHmac(kCCHmacAlgSHA1, key, key_len, data, data_len, out);
}

/// 7-Zip CKeyInfo::CalcKey — SHA-256(salt || utf16le(password) || u64le(round)) for 2^NumCyclesPower rounds.
static int sevenz_derive_key(
    unsigned num_cycles_power,
    const uint8_t *salt, size_t salt_len,
    const uint8_t *password, size_t password_len,
    uint8_t key[32]
) {
    if (num_cycles_power == 0x3F) {
        memset(key, 0, 32);
        size_t pos = 0;
        if (salt_len > 32) {
            salt_len = 32;
        }
        memcpy(key, salt, salt_len);
        pos = salt_len;
        size_t remain = 32 - pos;
        if (password_len < remain) {
            remain = password_len;
        }
        memcpy(key + pos, password, remain);
        return 0;
    }
    /* 7-Zip supports up to 24; higher would lock the UI for minutes. */
    if (num_cycles_power > 24) {
        return -4;
    }

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t extra[8];
    memset(extra, 0, sizeof extra);
    uint64_t rounds = 1ULL << num_cycles_power;
    uint64_t i;
    for (i = 0; i < rounds; i++) {
        if (salt_len > 0) {
            CC_SHA256_Update(&ctx, salt, salt_len);
        }
        if (password_len > 0) {
            CC_SHA256_Update(&ctx, password, password_len);
        }
        CC_SHA256_Update(&ctx, extra, 8);
        unsigned k;
        for (k = 0; k < 8; k++) {
            extra[k] = (uint8_t)(extra[k] + 1);
            if (extra[k] != 0) {
                break;
            }
        }
    }
    CC_SHA256_Final(key, &ctx);
    return 0;
}

int sevenz_aes_decrypt(
    const uint8_t *properties, size_t properties_len,
    const uint8_t *password_utf16le, size_t password_len,
    const uint8_t *ciphertext, size_t ciphertext_len,
    uint8_t *out, size_t out_cap, size_t *out_len
) {
    if (out_len == NULL || out == NULL) {
        return -1;
    }
    *out_len = 0;
    if (password_utf16le == NULL || password_len == 0) {
        return -1;
    }
    if (ciphertext_len == 0) {
        return 0;
    }
    if ((ciphertext_len % 16) != 0 || out_cap < ciphertext_len) {
        return -2;
    }
    if (properties == NULL || properties_len == 0) {
        return -1;
    }

    unsigned b0 = properties[0];
    unsigned num_cycles_power = b0 & 0x3F;
    uint8_t salt[16];
    uint8_t iv[16];
    size_t salt_len = 0;
    memset(salt, 0, sizeof salt);
    memset(iv, 0, sizeof iv);

    if ((b0 & 0xC0) == 0) {
        if (properties_len != 1) {
            return -1;
        }
    } else {
        if (properties_len < 2) {
            return -1;
        }
        unsigned b1 = properties[1];
        salt_len = ((b0 >> 7) & 1) + (b1 >> 4);
        size_t iv_len = ((b0 >> 6) & 1) + (b1 & 0x0F);
        if (salt_len > 16 || iv_len > 16) {
            return -1;
        }
        if (properties_len != 2 + salt_len + iv_len) {
            return -1;
        }
        memcpy(salt, properties + 2, salt_len);
        memcpy(iv, properties + 2 + salt_len, iv_len);
    }

    uint8_t key[32];
    int krc = sevenz_derive_key(
        num_cycles_power,
        salt, salt_len,
        password_utf16le, password_len,
        key
    );
    if (krc != 0) {
        memset(key, 0, sizeof key);
        return krc;
    }

    size_t moved = 0;
    CCCryptorStatus rc = CCCrypt(
        kCCDecrypt,
        kCCAlgorithmAES,
        0, /* CBC, no PKCS7 — 7z pads with zeros and stores the real size */
        key,
        kCCKeySizeAES256,
        iv,
        ciphertext,
        ciphertext_len,
        out,
        out_cap,
        &moved
    );
    memset(key, 0, sizeof key);
    if (rc != kCCSuccess) {
        return -3;
    }
    *out_len = moved;
    return 0;
}
