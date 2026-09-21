/*
 * _cosmocrypto: a small, hand-written CPython extension exposing symmetric
 * encryption (AES) via OpenSSL's EVP API.
 *
 * Why this exists: pycryptodome's C accelerators are architecturally
 * incompatible with this project (they dlopen() their own compiled pieces
 * at runtime - see docs/BUILD.md), and `cryptography` (pyca) needs a Rust
 * toolchain we don't have. But we already build OpenSSL's libcrypto.a from
 * source with cosmocc for the `ssl` module - this module is a thin,
 * from-scratch Python<->EVP glue layer over that *same* already-working
 * library, registered as a normal static built-in module exactly like
 * `_sqlite3`/`_ssl`/`zlib` (see Modules/Setup.local machinery in
 * docs/BUILD.md). No new C crypto code, no dlopen, no Rust - just bindings.
 *
 * API (intentionally small - AES-GCM covers the vast majority of "I need
 * to encrypt something" use cases with authentication built in; AES-CBC
 * is offered for interop with systems that specifically require it):
 *
 *   encrypt_gcm(key: bytes, nonce: bytes, plaintext: bytes,
 *               aad: bytes = b"") -> (ciphertext: bytes, tag: bytes)
 *   decrypt_gcm(key: bytes, nonce: bytes, ciphertext: bytes, tag: bytes,
 *               aad: bytes = b"") -> plaintext: bytes            (raises
 *               ValueError on authentication failure)
 *   encrypt_cbc(key: bytes, iv: bytes, plaintext: bytes) -> ciphertext: bytes
 *   decrypt_cbc(key: bytes, iv: bytes, ciphertext: bytes) -> plaintext: bytes
 *
 * Key length selects AES-128/192/256 (16/24/32 bytes). CBC uses PKCS#7
 * padding (handled by OpenSSL). GCM nonce is normally 12 bytes; tag is
 * 16 bytes.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <openssl/evp.h>
#include <openssl/err.h>

static void
raise_openssl_error(void)
{
    unsigned long code = ERR_get_error();
    char buf[256];
    if (code) {
        ERR_error_string_n(code, buf, sizeof(buf));
        PyErr_SetString(PyExc_ValueError, buf);
    } else {
        PyErr_SetString(PyExc_ValueError, "unknown OpenSSL error");
    }
}

static const EVP_CIPHER *
cipher_for_keylen(Py_ssize_t keylen, int gcm)
{
    if (gcm) {
        switch (keylen) {
            case 16: return EVP_aes_128_gcm();
            case 24: return EVP_aes_192_gcm();
            case 32: return EVP_aes_256_gcm();
        }
    } else {
        switch (keylen) {
            case 16: return EVP_aes_128_cbc();
            case 24: return EVP_aes_192_cbc();
            case 32: return EVP_aes_256_cbc();
        }
    }
    return NULL;
}

static PyObject *
cosmocrypto_encrypt_gcm(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *kwlist[] = {"key", "nonce", "plaintext", "aad", NULL};
    Py_buffer key, nonce, plaintext, aad = {0};
    aad.buf = NULL; aad.len = 0;
    PyObject *result = NULL;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*y*y*|y*", kwlist,
                                      &key, &nonce, &plaintext, &aad))
        return NULL;

    const EVP_CIPHER *cipher = cipher_for_keylen(key.len, 1);
    if (!cipher) {
        PyErr_SetString(PyExc_ValueError, "key must be 16, 24 or 32 bytes");
        goto cleanup;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { raise_openssl_error(); goto cleanup; }

    unsigned char *ciphertext = NULL;
    int outlen = 0, tmplen = 0;
    unsigned char tag[16];

    if (EVP_EncryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) goto ossl_err;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)nonce.len, NULL) != 1) goto ossl_err;
    if (EVP_EncryptInit_ex(ctx, NULL, NULL, (unsigned char *)key.buf, (unsigned char *)nonce.buf) != 1) goto ossl_err;

    if (aad.buf && aad.len > 0) {
        if (EVP_EncryptUpdate(ctx, NULL, &tmplen, (unsigned char *)aad.buf, (int)aad.len) != 1)
            goto ossl_err;
    }

    ciphertext = PyMem_Malloc((size_t)plaintext.len > 0 ? (size_t)plaintext.len : 1);
    if (!ciphertext) { PyErr_NoMemory(); goto cleanup_ctx; }

    if (EVP_EncryptUpdate(ctx, ciphertext, &outlen,
                           (unsigned char *)plaintext.buf, (int)plaintext.len) != 1)
        goto ossl_err;
    if (EVP_EncryptFinal_ex(ctx, ciphertext + outlen, &tmplen) != 1)
        goto ossl_err;
    outlen += tmplen;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1)
        goto ossl_err;

    result = Py_BuildValue("y#y#", ciphertext, (Py_ssize_t)outlen, tag, (Py_ssize_t)16);
    goto cleanup_ctx;

ossl_err:
    raise_openssl_error();
cleanup_ctx:
    if (ciphertext) PyMem_Free(ciphertext);
    EVP_CIPHER_CTX_free(ctx);
cleanup:
    PyBuffer_Release(&key);
    PyBuffer_Release(&nonce);
    PyBuffer_Release(&plaintext);
    if (aad.buf) PyBuffer_Release(&aad);
    return result;
}

static PyObject *
cosmocrypto_decrypt_gcm(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *kwlist[] = {"key", "nonce", "ciphertext", "tag", "aad", NULL};
    Py_buffer key, nonce, ciphertext, tag, aad = {0};
    aad.buf = NULL; aad.len = 0;
    PyObject *result = NULL;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*y*y*y*|y*", kwlist,
                                      &key, &nonce, &ciphertext, &tag, &aad))
        return NULL;

    const EVP_CIPHER *cipher = cipher_for_keylen(key.len, 1);
    if (!cipher) {
        PyErr_SetString(PyExc_ValueError, "key must be 16, 24 or 32 bytes");
        goto cleanup;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { raise_openssl_error(); goto cleanup; }

    unsigned char *plaintext = NULL;
    int outlen = 0, tmplen = 0;

    if (EVP_DecryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) goto ossl_err;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)nonce.len, NULL) != 1) goto ossl_err;
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, (unsigned char *)key.buf, (unsigned char *)nonce.buf) != 1) goto ossl_err;

    if (aad.buf && aad.len > 0) {
        if (EVP_DecryptUpdate(ctx, NULL, &tmplen, (unsigned char *)aad.buf, (int)aad.len) != 1)
            goto ossl_err;
    }

    plaintext = PyMem_Malloc((size_t)ciphertext.len > 0 ? (size_t)ciphertext.len : 1);
    if (!plaintext) { PyErr_NoMemory(); goto cleanup_ctx; }

    if (EVP_DecryptUpdate(ctx, plaintext, &outlen,
                           (unsigned char *)ciphertext.buf, (int)ciphertext.len) != 1)
        goto ossl_err;

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)tag.len, (void *)tag.buf) != 1)
        goto ossl_err;

    if (EVP_DecryptFinal_ex(ctx, plaintext + outlen, &tmplen) != 1) {
        PyErr_SetString(PyExc_ValueError, "authentication failed (bad tag/key/nonce/aad)");
        goto cleanup_ctx;
    }
    outlen += tmplen;

    result = Py_BuildValue("y#", plaintext, (Py_ssize_t)outlen);
    goto cleanup_ctx;

ossl_err:
    raise_openssl_error();
cleanup_ctx:
    if (plaintext) PyMem_Free(plaintext);
    EVP_CIPHER_CTX_free(ctx);
cleanup:
    PyBuffer_Release(&key);
    PyBuffer_Release(&nonce);
    PyBuffer_Release(&ciphertext);
    PyBuffer_Release(&tag);
    if (aad.buf) PyBuffer_Release(&aad);
    return result;
}

static PyObject *
do_cbc(PyObject *args, int encrypt)
{
    Py_buffer key, iv, data;
    PyObject *result = NULL;

    if (!PyArg_ParseTuple(args, "y*y*y*", &key, &iv, &data))
        return NULL;

    const EVP_CIPHER *cipher = cipher_for_keylen(key.len, 0);
    if (!cipher) {
        PyErr_SetString(PyExc_ValueError, "key must be 16, 24 or 32 bytes");
        goto cleanup;
    }
    if (iv.len != 16) {
        PyErr_SetString(PyExc_ValueError, "iv must be 16 bytes");
        goto cleanup;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { raise_openssl_error(); goto cleanup; }

    unsigned char *out = NULL;
    int outlen = 0, tmplen = 0;
    /* PKCS#7 padding can add up to one full block. */
    size_t outbuf_size = (size_t)data.len + 32;

    int ok = encrypt
        ? EVP_EncryptInit_ex(ctx, cipher, NULL, (unsigned char *)key.buf, (unsigned char *)iv.buf)
        : EVP_DecryptInit_ex(ctx, cipher, NULL, (unsigned char *)key.buf, (unsigned char *)iv.buf);
    if (ok != 1) goto ossl_err;

    out = PyMem_Malloc(outbuf_size);
    if (!out) { PyErr_NoMemory(); goto cleanup_ctx; }

    ok = encrypt
        ? EVP_EncryptUpdate(ctx, out, &outlen, (unsigned char *)data.buf, (int)data.len)
        : EVP_DecryptUpdate(ctx, out, &outlen, (unsigned char *)data.buf, (int)data.len);
    if (ok != 1) goto ossl_err;

    ok = encrypt
        ? EVP_EncryptFinal_ex(ctx, out + outlen, &tmplen)
        : EVP_DecryptFinal_ex(ctx, out + outlen, &tmplen);
    if (ok != 1) {
        PyErr_SetString(PyExc_ValueError,
            encrypt ? "encryption failed" : "decryption failed (bad key/iv/padding)");
        goto cleanup_ctx;
    }
    outlen += tmplen;

    result = Py_BuildValue("y#", out, (Py_ssize_t)outlen);
    goto cleanup_ctx;

ossl_err:
    raise_openssl_error();
cleanup_ctx:
    if (out) PyMem_Free(out);
    EVP_CIPHER_CTX_free(ctx);
cleanup:
    PyBuffer_Release(&key);
    PyBuffer_Release(&iv);
    PyBuffer_Release(&data);
    return result;
}

static PyObject *
cosmocrypto_encrypt_cbc(PyObject *self, PyObject *args)
{
    return do_cbc(args, 1);
}

static PyObject *
cosmocrypto_decrypt_cbc(PyObject *self, PyObject *args)
{
    return do_cbc(args, 0);
}

static PyMethodDef cosmocrypto_methods[] = {
    {"encrypt_gcm", (PyCFunction)cosmocrypto_encrypt_gcm, METH_VARARGS | METH_KEYWORDS,
     "encrypt_gcm(key, nonce, plaintext, aad=b'') -> (ciphertext, tag)"},
    {"decrypt_gcm", (PyCFunction)cosmocrypto_decrypt_gcm, METH_VARARGS | METH_KEYWORDS,
     "decrypt_gcm(key, nonce, ciphertext, tag, aad=b'') -> plaintext"},
    {"encrypt_cbc", cosmocrypto_encrypt_cbc, METH_VARARGS,
     "encrypt_cbc(key, iv, plaintext) -> ciphertext (PKCS#7 padded)"},
    {"decrypt_cbc", cosmocrypto_decrypt_cbc, METH_VARARGS,
     "decrypt_cbc(key, iv, ciphertext) -> plaintext"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef cosmocrypto_module = {
    PyModuleDef_HEAD_INIT,
    "_cosmocrypto",
    "AES-GCM/AES-CBC via this build's OpenSSL libcrypto (see docs/BUILD.md).",
    -1,
    cosmocrypto_methods
};

PyMODINIT_FUNC
PyInit__cosmocrypto(void)
{
    return PyModule_Create(&cosmocrypto_module);
}
