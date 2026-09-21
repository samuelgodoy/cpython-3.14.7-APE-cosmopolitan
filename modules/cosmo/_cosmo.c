/*
 * _cosmo: exposes Cosmopolitan's runtime host-OS detection to Python.
 *
 * Why this exists: `sys.platform` is permanently "linux" in this build and
 * `os.name` is permanently "posix", deliberately and unavoidably - they are
 * compile-time facts that select which OS-personality module set CPython
 * built (see docs/BUILD.md, "sys.platform is stuck as linux"). Making them
 * report the real host breaks the interpreter outright. The consequence is
 * that portable scripts running on this binary have had *no* way to answer
 * "which OS am I actually on right now?", even though the APE runtime knows
 * perfectly well.
 *
 * Cosmopolitan answers it via __hostos, resolved at startup (libc/dce.h).
 * This module is a handful of lines of glue over that, registered as a
 * static built-in exactly like the other modules/ entries.
 *
 * Use `cosmo` (the pure-Python wrapper) rather than this module directly.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

/* All of libc/dce.h sits behind #ifdef _COSMO_SOURCE - without this the
 * header is found but every Is*() macro silently isn't defined, which
 * surfaces as -Wimplicit-function-declaration rather than as a missing
 * include. It also declares __hostos, which the macros read. */
#define _COSMO_SOURCE
#include <libc/dce.h>
#include <libc/nt/runtime.h>     /* ExitProcess() */
#include <stdio.h>               /* fflush() */
#include <unistd.h>              /* _exit() */

/* Note on the aarch64 half: dce.h's SUPPORT_VECTOR excludes _HOSTWINDOWS
 * on non-x86_64, so IsWindows() there is a compile-time 0. That is
 * correct rather than a gap - Windows loads the x86_64 half of the fat
 * binary even on ARM64 hardware (via its own x86 emulation), so the
 * aarch64 half genuinely never runs on Windows. */

PyDoc_STRVAR(host_os_doc,
"host_os() -> str\n\
\n\
Return the OS this process is actually running on right now, as one of\n\
'windows', 'linux', 'macos', 'freebsd', 'openbsd', 'netbsd', or 'unknown'.\n\
Unlike sys.platform, this reflects the real host rather than the\n\
personality CPython was compiled for.");

static PyObject *
cosmo_host_os(PyObject *self, PyObject *Py_UNUSED(ignored))
{
    const char *name;
    if (IsWindows()) {
        name = "windows";
    } else if (IsLinux()) {
        name = "linux";
    } else if (IsXnu()) {
        name = "macos";
    } else if (IsFreebsd()) {
        name = "freebsd";
    } else if (IsOpenbsd()) {
        name = "openbsd";
    } else if (IsNetbsd()) {
        name = "netbsd";
    } else {
        name = "unknown";
    }
    return PyUnicode_FromString(name);
}

PyDoc_STRVAR(arch_doc,
"arch() -> str\n\
\n\
Return the CPU architecture of the half of the fat binary that is\n\
executing: 'x86_64' or 'aarch64'. Resolved at compile time, which is\n\
correct here precisely because cosmocc compiles each architecture\n\
separately and apelinks the results together.");

static PyObject *
cosmo_arch(PyObject *self, PyObject *Py_UNUSED(ignored))
{
#if defined(__x86_64__)
    return PyUnicode_FromString("x86_64");
#elif defined(__aarch64__)
    return PyUnicode_FromString("aarch64");
#else
    return PyUnicode_FromString("unknown");
#endif
}

PyDoc_STRVAR(exit_process_doc,
"exit_process(code)\n\
\n\
Exit immediately with `code` as the process's real exit status, bypassing\n\
the wait-status encoding that otherwise makes a Windows shell see the\n\
code shifted left by 8. Does not return, and runs no cleanup.\n\
\n\
Use `cosmo.exit()` rather than calling this directly.");

static PyObject *
cosmo_exit_process(PyObject *self, PyObject *arg)
{
    long code = PyLong_AsLong(arg);
    if (code == -1 && PyErr_Occurred()) {
        return NULL;
    }
    /* Neither ExitProcess() nor _exit() runs atexit handlers or drains
     * buffers, so anything written just before exiting would be lost.
     * This covers C stdio; Python's own io buffers are flushed by the
     * cosmo.exit() wrapper before it calls in here. */
    fflush(NULL);
    if (IsWindows()) {
        ExitProcess((unsigned int)code);
    }
    _exit((int)code);
    Py_UNREACHABLE();
}

static PyMethodDef cosmo_methods[] = {
    {"host_os", cosmo_host_os, METH_NOARGS, host_os_doc},
    {"arch", cosmo_arch, METH_NOARGS, arch_doc},
    {"exit_process", cosmo_exit_process, METH_O, exit_process_doc},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef cosmo_module = {
    PyModuleDef_HEAD_INIT,
    "_cosmo",
    "Runtime host detection for Cosmopolitan APE builds (see `cosmo`).",
    -1,
    cosmo_methods,
    NULL, NULL, NULL, NULL
};

PyMODINIT_FUNC
PyInit__cosmo(void)
{
    return PyModule_Create(&cosmo_module);
}
