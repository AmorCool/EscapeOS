// Apple ID 登录 + IPA 签名 — C interface.
// Implemented in rust/idevice-ffi/src/sideload_auth.rs (isideload sign-only path).
#ifndef SIDELOAD_AUTH_H
#define SIDELOAD_AUTH_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque session returned by si_apple_signin; freed with si_sign_session_free.
typedef struct SignSession SignSession;

// Fills out_buf (NUL-terminated) with a 2FA code and returns 1; return 0 to cancel.
typedef int (*SITwoFactorCb)(void *ctx, char *out_buf, size_t buf_len);

// Logs in, opens a developer session, and builds a signer. Blocks; twofa_cb is
// invoked when a 2FA code is needed. Returns 0 on success (out_session/summary/
// out_dsid/out_auth_token valid), 1 on error (out_error set), 2 if out pointers
// invalid.
//
// out_dsid / out_auth_token (v0.2.111): the dsid and the
// `com.apple.gs.xcode.auth` token for this login. Persist them and later pass
// them to si_signin_with_session to restore the session without logging in or
// doing 2FA again. Free with si_string_free.
int si_apple_signin(const char *apple_id, const char *password,
                    const char *anisette_url, const char *machine_name,
                    const char *storage_dir, SITwoFactorCb twofa_cb, void *ctx,
                    SignSession **out_session, char **out_summary,
                    char **out_dsid, char **out_auth_token,
                    char **out_error);

// Signs the IPA at ipa_path, writing the signed .app bundle's path to
// out_signed_path. Blocks. udid is registered with the team first; pass NULL to
// skip that (may fail with developer error 8220). Returns 0 on success.
int si_sign_ipa(SignSession *session, const char *ipa_path, const char *udid,
                const char *device_name, char **out_signed_path, char **out_error);

// Restores a signing session from an existing dsid + xcode.auth token (from the
// app's Settings sign-in) — no login or 2FA needed. Returns 0 on success.
int si_signin_with_session(const char *email, const char *dsid,
                           const char *auth_token, const char *anisette_url,
                           const char *storage_dir, const char *machine_name,
                           SignSession **out_session, char **out_summary,
                           char **out_error);

// Frees a SignSession (NULL is a no-op).
void si_sign_session_free(SignSession *session);

// Frees a heap C string previously returned by si_apple_signin / si_sign_ipa.
void si_string_free(char *p);

#ifdef __cplusplus
}
#endif

#endif /* SIDELOAD_AUTH_H */
