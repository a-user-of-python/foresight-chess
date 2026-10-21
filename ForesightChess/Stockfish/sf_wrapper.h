// Stockfish iOS wrapper — C interface for Swift.
//
// Stockfish runs its UCI loop on a background thread with stdin/stdout
// redirected through pipes (iOS can't spawn subprocesses, so we link
// Stockfish in-process and talk to it via the pipes).
//
// Usage from Swift:
//   sf_init()              // start engine (call once)
//   sf_send("uci\n")        // send UCI command
//   sf_read(buf, len)      // read output (returns bytes read, 0 on timeout)
//   sf_is_ready()          // true once engine is initialized

#ifdef __cplusplus
extern "C" {
#endif

/// Start the Stockfish engine on a background thread. Call once.
void sf_init(void);

/// Send a UCI command to the engine (include trailing newline).
void sf_send(const char* cmd);

/// Read engine output into buf (up to len-1 bytes, null-terminated).
/// Blocks up to timeout_ms. Returns bytes read (0 on timeout).
int sf_read(char* buf, int len, int timeout_ms);

/// True if the engine thread is running.
int sf_is_running(void);

#ifdef __cplusplus
}
#endif
