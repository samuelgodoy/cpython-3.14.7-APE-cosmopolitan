/*
 * libpq.a's own objects (fe-connect.c, fe-exec.c, fe-misc.c) expect plain
 * pg_char_to_encoding()/pg_encoding_to_char() symbols. Our separately
 * built libpgcommon.a (see deps/07-libpq.sh) ended up compiled with
 * USE_PRIVATE_ENCODING_FUNCS defined (postgres's own src/interfaces/libpq
 * build sets this for its bundled copy of src/common - see
 * src/include/mb/pg_wchar.h), which renames these to
 * pg_char_to_encoding_private()/pg_encoding_to_char_private() instead.
 * Bridge the mismatch directly rather than fight postgres's build system
 * for exact flag parity between the two.
 */
extern int pg_char_to_encoding_private(const char *name);
extern const char *pg_encoding_to_char_private(int encoding);

int
pg_char_to_encoding(const char *name)
{
    return pg_char_to_encoding_private(name);
}

const char *
pg_encoding_to_char(int encoding)
{
    return pg_encoding_to_char_private(encoding);
}
