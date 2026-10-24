#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include "RunbarProcess.h"
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

int rb_spawn(const char *shell, const char *command, const char *directory,
             const char *path, pid_t *pid, int *output_fd) {
    int output[2];
    if (pipe(output) < 0) return errno;
    // GUI processes can inherit closed standard descriptors. Keep pipes above 2
    // so subsequent dup/close actions cannot accidentally close redirected I/O.
    for (int i = 0; i < 2; ++i) {
        if (output[i] <= STDERR_FILENO) {
            int replacement = fcntl(output[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) { int e = errno; close(output[0]); close(output[1]); return e; }
            close(output[i]); output[i] = replacement;
        } else if (fcntl(output[i], F_SETFD, FD_CLOEXEC) < 0) {
            int e = errno; close(output[0]); close(output[1]); return e;
        }
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(output[0]); close(output[1]); return error; }
    error = posix_spawnattr_init(&attributes);
    if (error) { posix_spawn_file_actions_destroy(&actions); close(output[0]); close(output[1]); return error; }
#define CHECK(call) do { if (!error) error = (call); } while (0)
    CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
    CHECK(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO));
    CHECK(posix_spawn_file_actions_addclose(&actions, output[0]));
    CHECK(posix_spawn_file_actions_addclose(&actions, output[1]));
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    sigset_t defaults, mask;
    sigemptyset(&mask); sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE);
    CHECK(posix_spawnattr_setsigmask(&attributes, &mask));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    // The user's command and PATH are positional arguments, never interpolated.
    char *argv[] = {(char *)shell, "-l", "-c", "export PATH=\"$1:$PATH\"; eval \"$2\"", "runbar", (char *)path, (char *)command, NULL};
    if (!error) error = posix_spawn(pid, shell, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    close(output[1]);
    if (error) { close(output[0]); return error; }
    *output_fd = output[0]; return 0;
}
int rb_signal(pid_t pid, int sig) {
    if (pid <= 1) return EINVAL;
    return kill(-pid, sig) == 0 ? 0 : errno;
}
int rb_wait(pid_t pid, int *exit_code) {
    int status; pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 0;
}
int rb_poll(pid_t pid, int *exit_code) {
    int status; pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) return 0;
    if (result < 0) return errno == EINTR ? 0 : -errno;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}
