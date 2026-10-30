/* Relocatable, isolated CPython host. Never reads user Python/site configuration. */
#include <Python.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void checked(PyStatus status) { if (PyStatus_Exception(status)) Py_ExitStatusException(status); }
int main(int argc, char **argv) {
    char executable[PATH_MAX], resolved[PATH_MAX], home[PATH_MAX], path[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, resolved)) { perror("Nightwing media runtime location"); return 70; }
    char *slash = strrchr(resolved, '/'); if (!slash) return 70; *slash = 0;
    snprintf(home, sizeof(home), "%s/../../Resources/MediaTools/python", resolved);
    PyConfig config; PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0; config.write_bytecode = 0; config.parse_argv = 0;
    checked(PyConfig_SetBytesString(&config, &config.home, home));
    checked(PyConfig_SetBytesArgv(&config, argc, argv));
    config.module_search_paths_set = 1;
    const char *parts[] = {"", "/../../../Frameworks"};
    for (int i = 0; i < 2; i++) {
        snprintf(path, sizeof(path), "%s%s", home, parts[i]);
        wchar_t *wide = Py_DecodeLocale(path, NULL); if (!wide) return 71;
        checked(PyWideStringList_Append(&config.module_search_paths, wide)); PyMem_RawFree(wide);
    }
    snprintf(path, sizeof(path), "%s/../../Resources/MediaTools/site-packages", resolved);
    wchar_t *wide = Py_DecodeLocale(path, NULL); if (!wide) return 71;
    checked(PyWideStringList_Append(&config.module_search_paths, wide)); PyMem_RawFree(wide);
    checked(PyConfig_SetString(&config, &config.run_module, L"yt_dlp"));
    checked(Py_InitializeFromConfig(&config)); PyConfig_Clear(&config);
    return Py_RunMain();
}
