#include "CBackground.h"
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>

int hatebu_exec_isolated(const char *executable, char *const arguments[]) {
    // Codex and its tool processes get their own group so Stop can cancel all of them.
    if (setsid() < 0 && getpgrp() != getpid()) return -1;
    execv(executable, arguments);
    return -1;
}

// Only async-signal-safe POSIX operations between fork and exec. The double fork
// separates sync from Alfred's search process group and avoids leaving zombies.
int hatebu_spawn_detached(const char *executable, char *const arguments[]) {
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        if (setsid() < 0) _exit(1);
        pid_t worker = fork();
        if (worker < 0) _exit(1);
        if (worker > 0) _exit(0);
        int nullfd = open("/dev/null", O_RDWR);
        if (nullfd < 0) _exit(1);
        dup2(nullfd, STDIN_FILENO); dup2(nullfd, STDOUT_FILENO); dup2(nullfd, STDERR_FILENO);
        if (nullfd > STDERR_FILENO) close(nullfd);
        execv(executable, arguments);
        _exit(127);
    }
    int status;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return -1; }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}
