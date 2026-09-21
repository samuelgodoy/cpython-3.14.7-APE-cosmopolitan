"""
psycopg_c: thin shim package.

The real C code (pq.c, _psycopg.c - unmodified upstream Cython output from
the psycopg-c 3.2.3 sdist, plus one cosmocc portability fix, see docs/BUILD.md)
is compiled as flat, statically-linked built-in modules named "pq" and
"_psycopg" (see Modules/Setup.local machinery in docs/BUILD.md - a Setup module
name must be a plain identifier, no dots, so the extensions can't be
registered directly under this package's own dotted name). This package
just re-exports them under the names psycopg's pure-Python layer expects
(`from psycopg_c import pq`, `from psycopg_c import _psycopg`).
"""

import pq as pq
import _psycopg as _psycopg

__version__ = "3.2.3"
