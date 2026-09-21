"""
cosmocrypto: a thin, convenient Python wrapper around the built-in
_cosmocrypto extension (AES-GCM / AES-CBC via this build's OpenSSL
libcrypto). See docs/BUILD.md ("Adding a package with a C extension") for why
this exists instead of pycryptodome/cryptography.

Example:
    >>> import cosmocrypto, os
    >>> key = os.urandom(32)                    # AES-256
    >>> ct, nonce = cosmocrypto.aes_gcm_encrypt(key, b"secret message")
    >>> cosmocrypto.aes_gcm_decrypt(key, ct, nonce)
    b'secret message'
"""

import os as _os
import _cosmocrypto

GCM_NONCE_SIZE = 12
GCM_TAG_SIZE = 16
CBC_IV_SIZE = 16


def aes_gcm_encrypt(key, plaintext, aad=b"", nonce=None):
    """Encrypt with AES-GCM. Returns (ciphertext_with_tag, nonce).

    key must be 16/24/32 bytes (AES-128/192/256). A random nonce is
    generated if not supplied - never reuse a (key, nonce) pair.
    """
    if nonce is None:
        nonce = _os.urandom(GCM_NONCE_SIZE)
    ciphertext, tag = _cosmocrypto.encrypt_gcm(key, nonce, plaintext, aad)
    return ciphertext + tag, nonce


def aes_gcm_decrypt(key, ciphertext_with_tag, nonce, aad=b""):
    """Decrypt data produced by aes_gcm_encrypt(). Raises ValueError if the
    key/nonce/aad are wrong or the data was tampered with."""
    if len(ciphertext_with_tag) < GCM_TAG_SIZE:
        raise ValueError("ciphertext too short to contain a tag")
    ciphertext = ciphertext_with_tag[:-GCM_TAG_SIZE]
    tag = ciphertext_with_tag[-GCM_TAG_SIZE:]
    return _cosmocrypto.decrypt_gcm(key, nonce, ciphertext, tag, aad)


def aes_cbc_encrypt(key, plaintext, iv=None):
    """Encrypt with AES-CBC (PKCS#7 padded). Returns (ciphertext, iv)."""
    if iv is None:
        iv = _os.urandom(CBC_IV_SIZE)
    return _cosmocrypto.encrypt_cbc(key, iv, plaintext), iv


def aes_cbc_decrypt(key, ciphertext, iv):
    """Decrypt data produced by aes_cbc_encrypt()."""
    return _cosmocrypto.decrypt_cbc(key, iv, ciphertext)
