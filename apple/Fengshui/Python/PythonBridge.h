#ifndef PYTHON_BRIDGE_H
#define PYTHON_BRIDGE_H

// Thin C wrapper around the embedded CPython runtime (spec §8).
// Swift never touches PyObject*: every call is JSON in, JSON out, through
// fengshui_engine.bridge.call(name, json).

/// Initialize the interpreter once. `python_home` = <App>/python, `app_packages` =
/// <App>/app_packages. Returns 0 on success; on failure *error is a malloc'd message.
int fs_python_initialize(const char *python_home, const char *app_packages, char **error);

/// Call fengshui_engine.bridge.call(function, args_json). Thread-safe (takes the GIL).
/// Returns a malloc'd JSON string (free with fs_python_free) or NULL with *error set.
char *fs_python_call(const char *function, const char *args_json, char **error);

void fs_python_free(void *ptr);

int fs_python_is_initialized(void);

#endif
