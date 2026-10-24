#include "PythonBridge.h"

#include <Python/Python.h>
#include <stdlib.h>
#include <string.h>

static int g_initialized = 0;

static char *dup_cstr(const char *s) {
    if (!s) s = "(null)";
    size_t n = strlen(s) + 1;
    char *out = malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

/// Format the pending Python exception as "Type: message" and clear it.
static char *take_python_error(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return dup_cstr("unknown Python error");
    PyObject *s = PyObject_Str(exc);
    const char *type = Py_TYPE(exc)->tp_name;
    const char *msg = s ? PyUnicode_AsUTF8(s) : NULL;
    size_t n = strlen(type) + (msg ? strlen(msg) : 0) + 4;
    char *out = malloc(n);
    if (out) snprintf(out, n, "%s: %s", type, msg ? msg : "");
    Py_XDECREF(s);
    Py_DECREF(exc);
    return out;
}

int fs_python_initialize(const char *python_home, const char *app_packages, char **error) {
    if (g_initialized) return 0;

    PyPreConfig preconfig;
    PyConfig config;
    PyStatus status;

    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) { *error = dup_cstr(status.err_msg); return 1; }

    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;          // the signed bundle is read-only
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0; // the host app owns signals

    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) goto fail;
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) goto fail;
    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto fail;
    PyConfig_Clear(&config);

    // app_packages holds fengshui_engine and tzdata.
    PyObject *site = PyImport_ImportModule("site");
    PyObject *res = site ? PyObject_CallMethod(site, "addsitedir", "s", app_packages) : NULL;
    Py_XDECREF(res);
    Py_XDECREF(site);
    if (!res) { *error = take_python_error(); return 1; }

    g_initialized = 1;
    // Release the GIL so any thread can call in via PyGILState_Ensure.
    PyEval_SaveThread();
    return 0;

fail:
    *error = dup_cstr(status.err_msg ? status.err_msg : "Python initialization failed");
    PyConfig_Clear(&config);
    return 1;
}

char *fs_python_call(const char *function, const char *args_json, char **error) {
    if (!g_initialized) { *error = dup_cstr("Python not initialized"); return NULL; }

    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;
    PyObject *bridge = PyImport_ImportModule("fengshui_engine.bridge");
    PyObject *result = bridge ? PyObject_CallMethod(bridge, "call", "ss", function, args_json) : NULL;
    if (result && PyUnicode_Check(result)) {
        out = dup_cstr(PyUnicode_AsUTF8(result));
    } else if (result) {
        *error = dup_cstr("bridge.call did not return str");
    } else {
        *error = take_python_error();
    }
    Py_XDECREF(result);
    Py_XDECREF(bridge);
    PyGILState_Release(gil);
    return out;
}

void fs_python_free(void *ptr) { free(ptr); }

int fs_python_is_initialized(void) { return g_initialized; }
