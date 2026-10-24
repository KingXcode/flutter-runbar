#include "RunbarProcess.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

static size_t drain(int fd, char *capture, size_t capacity) {
    char bytes[4096]; size_t total = 0; ssize_t count;
    while ((count = read(fd, bytes, sizeof(bytes))) > 0) {
        if (capture && total + (size_t)count < capacity) memcpy(capture + total, bytes, (size_t)count);
        total += (size_t)count;
    }
    assert(count == 0); close(fd);
    if (capture && total < capacity) capture[total] = 0;
    return total;
}
int main(void) {
    char directory[] = "/tmp/runbar test.XXXXXX"; assert(mkdtemp(directory));
    pid_t pid; int fd, code; char output[8192];
    assert(rb_spawn("/bin/sh", "printf 'stdout\\n'; printf 'stderr\\n' >&2; pwd; exit 7", directory, "/usr/bin:/bin", &pid, &fd) == 0);
    assert(getpgid(pid) == pid && getpgrp() != pid);
    drain(fd, output, sizeof(output)); assert(rb_wait(pid, &code) == 0 && code == 7);
    assert(strstr(output, "stdout\nstderr\n") && strstr(output, directory));
    puts("PASS spaces, merged streams, exit code, isolated group");
    assert(rb_spawn("/does/not/exist", "true", directory, "", &pid, &fd) != 0);
    assert(rb_spawn("/bin/sh", "true", "/does/not/exist", "", &pid, &fd) != 0);
    puts("PASS launch and working directory failure");
    assert(rb_spawn("/bin/sh", "head -c 2097152 /dev/zero", directory, "/usr/bin:/bin", &pid, &fd) == 0);
    assert(drain(fd, NULL, 0) == 2097152); assert(rb_wait(pid, &code) == 0 && code == 0);
    puts("PASS 2 MiB lossless pipe output");
    pid_t unrelated; int unrelated_fd;
    assert(rb_spawn("/bin/sh", "sleep 30", directory, "/usr/bin:/bin", &unrelated, &unrelated_fd) == 0);
    assert(rb_spawn("/bin/sh", "trap '' INT TERM; sleep 30 & wait", directory, "/usr/bin:/bin", &pid, &fd) == 0);
    usleep(200000);
    assert(rb_signal(pid, SIGINT) == 0); usleep(100000);
    assert(rb_signal(pid, SIGTERM) == 0); usleep(100000);
    assert(rb_signal(pid, SIGKILL) == 0);
    drain(fd, NULL, 0); assert(rb_wait(pid, &code) == 0 && code == 137);
    assert(kill(unrelated, 0) == 0);
    rb_signal(unrelated, SIGKILL); drain(unrelated_fd, NULL, 0); rb_wait(unrelated, &code);
    puts("PASS escalation stops owned child tree, unrelated group survives");
    assert(rb_spawn("/bin/sh", "exit 0", directory, "/usr/bin:/bin", &pid, &fd) == 0);
    drain(fd, NULL, 0);
    siginfo_t info = {0};
    assert(waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0);
    int signal_error = rb_signal(pid, SIGTERM);
    assert(signal_error == 0 || signal_error == ESRCH);
    signal_error = rb_signal(pid, SIGKILL);
    assert(signal_error == 0 || signal_error == ESRCH);
    assert(rb_wait(pid, &code) == 0 && code == 0);
    puts("PASS repeated stop signals after exit do not report permission errors");
    assert(rb_spawn("/bin/sh", "trap '' INT TERM; sleep 30 >/dev/null 2>&1 & exit 0", directory, "/usr/bin:/bin", &pid, &fd) == 0);
    drain(fd, NULL, 0);
    assert(waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0);
    assert(rb_signal(pid, SIGINT) == 0);
    assert(rb_signal(pid, SIGTERM) == 0);
    assert(rb_signal(pid, SIGKILL) == 0);
    assert(rb_wait(pid, &code) == 0 && code == 0);
    puts("PASS exited leader still permits escalation for redirected descendants");
    pid_t closed_stdio_test = fork(); assert(closed_stdio_test >= 0);
    if (closed_stdio_test == 0) {
        close(0); close(1); close(2);
        pid_t nested; int nested_fd, nested_code;
        if (rb_spawn("/bin/sh", "printf OK", directory, "/bin:/usr/bin", &nested, &nested_fd) != 0) _exit(1);
        char bytes[32]; size_t count = drain(nested_fd, bytes, sizeof(bytes));
        if (rb_wait(nested, &nested_code) != 0 || nested_code != 0 || count != 2 || strcmp(bytes, "OK") != 0) _exit(2);
        _exit(0);
    }
    int closed_status; assert(waitpid(closed_stdio_test, &closed_status, 0) == closed_stdio_test);
    assert(WIFEXITED(closed_status) && WEXITSTATUS(closed_status) == 0);
    puts("PASS launch with all inherited standard descriptors closed");
    assert(rb_signal(0, SIGKILL) == EINVAL);
    rmdir(directory); return 0;
}
