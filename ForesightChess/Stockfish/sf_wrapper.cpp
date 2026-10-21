// Stockfish iOS wrapper implementation.
//
// Redirects stdin/stdout through pipes, then runs Stockfish's UCI loop
// on a background thread. Swift talks to the engine via sf_send/sf_read.

#include "sf_wrapper.h"

#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <sys/select.h>
#include <atomic>

#include "attacks.h"
#include "position.h"
#include "uci.h"
#include "tune.h"
#include "misc.h"

using namespace Stockfish;

static int stdin_pipe[2];   // Swift writes -> engine reads (as stdin)
static int stdout_pipe[2];  // engine writes (as stdout) -> Swift reads
static std::atomic<bool> g_running{false};
static pthread_t g_thread;

// Stockfish entry point (mirrors main.cpp without command-line handling).
static void* engine_thread(void*) {
    // Redirect stdin/stdout to our pipes.
    dup2(stdin_pipe[0], STDIN_FILENO);
    dup2(stdout_pipe[1], STDOUT_FILENO);
    // Close unused ends in this thread.
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    std::cout << engine_info() << std::endl;

    Attacks::init();
    Position::init();

    CommandLine cli(0, nullptr);
    auto uci = std::make_unique<UCIEngine>(std::move(cli));
    Tune::init(uci->engine_options());

    g_running = true;
    uci->loop();  // blocks reading stdin until "quit"
    g_running = false;
    return nullptr;
}

extern "C" {

void sf_init(void) {
    if (g_running) return;

    // Create pipes.
    if (pipe(stdin_pipe) != 0) return;
    if (pipe(stdout_pipe) != 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        return;
    }

    // Launch engine thread.
    pthread_create(&g_thread, nullptr, engine_thread, nullptr);
    pthread_detach(g_thread);

    // Close the ends we don't use in the main thread.
    // (engine_thread closes its copies after dup2)
}

void sf_send(const char* cmd) {
    if (!cmd) return;
    size_t len = strlen(cmd);
    // Write to the engine's stdin.
    ssize_t n = write(stdin_pipe[1], cmd, len);
    (void)n;
}

int sf_read(char* buf, int len, int timeout_ms) {
    if (!buf || len <= 1) return 0;

    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(stdout_pipe[0], &rfds);

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    int r = select(stdout_pipe[0] + 1, &rfds, nullptr, nullptr, &tv);
    if (r <= 0) return 0;  // timeout or error

    ssize_t n = read(stdout_pipe[0], buf, len - 1);
    if (n <= 0) return 0;
    buf[n] = '\0';
    return (int)n;
}

int sf_is_running(void) {
    return g_running ? 1 : 0;
}

}  // extern "C"
