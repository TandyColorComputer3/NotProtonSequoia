// Strips DYLD_INSERT_LIBRARIES and the SDL block list from child processes
#include "hooks.h"
#include "../util/log.h"

#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int   DobbyHook(void *address, void *replace_call, void **origin_call);
extern void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

typedef int (*fn_execve)(const char *path, char *const argv[], char *const envp[]);
typedef int (*fn_posix_spawn)(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]);

static fn_execve      orig_execve;
static fn_posix_spawn orig_posix_spawn;
static fn_posix_spawn orig_posix_spawnp;

// The SDL block list stops Steam from seeing a second, generic copy of the Steam Controller.
// This solves double input issues.
static const char *const np_steam_only_keys[] = {
    "DYLD_INSERT_LIBRARIES=",
    "SDL_JOYSTICK_BLACKLIST_DEVICES=",
};

static int np_is_steam_only(const char *entry) {
    for (size_t k = 0; k < sizeof(np_steam_only_keys) / sizeof(np_steam_only_keys[0]); k++) {
        if (strncmp(entry, np_steam_only_keys[k], strlen(np_steam_only_keys[k])) == 0)
            return 1;
    }
    return 0;
}

// steam_osx re-execs itself and needs the insert for hooks. Steam Helper runs
// CEF and needs it for the webpatch fopen interpose, strips elsewhere
static int np_target_keeps_insert(const char *path) {
    if (!path)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "steam_osx") == 0
        || strcmp(base, "Steam Helper") == 0;
}

static char **np_without_insert(char *const envp[]) {
    if (!envp)
        return NULL;

    int count = 0;
    int found = 0;
    for (int i = 0; envp[i]; i++) {
        if (np_is_steam_only(envp[i]))
            found = 1;
        count++;
    }
    if (!found)
        return NULL;

    char **clean = malloc(sizeof(char *) * (size_t)(count + 1));
    if (!clean) {
        NP_WARN("[spawn] cannot allocate a stripped environment, insert passed through");
        return NULL;
    }

    int j = 0;
    for (int i = 0; envp[i]; i++) {
        if (!np_is_steam_only(envp[i]))
            clean[j++] = envp[i];
    }
    clean[j] = NULL;
    return clean;
}

static int np_hook_execve(const char *path, char *const argv[], char *const envp[]) {
    if (np_target_keeps_insert(path))
        return orig_execve(path, argv, envp);

    char **clean = np_without_insert(envp);
    if (!clean)
        return orig_execve(path, argv, envp);

    NP_DBG("[spawn] execve '%s' without the insert", path);
    int rc = orig_execve(path, argv, (char *const *)clean);
    // Only reached when the exec failed, since a successful one replaced this image.
    free(clean);
    return rc;
}

static int np_spawn_without_insert(fn_posix_spawn orig, const char *api,
                                   pid_t *pid, const char *path,
                                   const posix_spawn_file_actions_t *fa,
                                   const posix_spawnattr_t *attr,
                                   char *const argv[], char *const envp[]) {
    if (np_target_keeps_insert(path))
        return orig(pid, path, fa, attr, argv, envp);

    char **clean = np_without_insert(envp);
    if (!clean)
        return orig(pid, path, fa, attr, argv, envp);

    NP_DBG("[spawn] %s '%s' without the insert", api, path);
    int rc = orig(pid, path, fa, attr, argv, (char *const *)clean);
    free(clean);
    return rc;
}

static int np_hook_posix_spawn(pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr,
                               char *const argv[], char *const envp[]) {
    return np_spawn_without_insert(orig_posix_spawn, "posix_spawn",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_posix_spawnp(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[]) {
    return np_spawn_without_insert(orig_posix_spawnp, "posix_spawnp",
                                   pid, path, fa, attr, argv, envp);
}

static void np_hook_symbol(const char *sym, void *repl, void **orig) {
    void *addr = DobbySymbolResolver("libsystem_kernel.dylib", sym);
    if (!addr)
        addr = DobbySymbolResolver(NULL, sym);
    if (!addr) {
        NP_WARN("[spawn] %s: unresolved, children keep the insert", sym);
        return;
    }

    int rc = DobbyHook(addr, repl, orig);
    if (rc == 0)
        NP_LOG("[spawn] %s: hooked @ %p", sym, addr);
    else
        NP_WARN("[spawn] %s: DobbyHook failed rc=%d, children keep the insert", sym, rc);
}

void np_hooks_spawn_install(void) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "spawn")) {
        NP_WARN("[spawn] DISABLED via NOTPROTON_DISABLE, children keep the insert");
        return;
    }

    np_hook_symbol("execve",       (void *)np_hook_execve,       (void **)&orig_execve);
    np_hook_symbol("posix_spawn",  (void *)np_hook_posix_spawn,  (void **)&orig_posix_spawn);
    np_hook_symbol("posix_spawnp", (void *)np_hook_posix_spawnp, (void **)&orig_posix_spawnp);
}
