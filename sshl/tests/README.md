# sshl tests

Run `bats sshl/tests/` from the repo root. CI pins fzf 0.54.3. The popup tests need fzf 0.46.0 or newer and skip with a message on an older one.

The minimums in the README were checked by running this suite and the lab with tmux 3.0a, 3.2a, 3.3a and 3.4, bash 4.3, 4.4, 5.0 and 5.2, and fzf 0.45.0, 0.46.0 and 0.54.3. On tmux 3.2a and 3.3a only the `↻` click test fails. The terminals listed in the README were each run against the lab hosts. wezterm was not.

The suite never touches a real host, the real config or the real `homelab` session:

- Each test gets its own temp directory and tmux socket. `SSHL_DATA_DIR_OVERRIDE` moves the config and caches into the temp directory, and `HOME` and `XDG_RUNTIME_DIR` point there too. The scripts, `homelab.tmux.conf` and `host-info.sh` are the real ones.
- `tests/bin/` puts stub `ssh` and `nmap` first on PATH.
- The launcher, conf, host-info and host-picker tests also put a `tmux` shim first on PATH. It refuses the `homelab` socket and any bare `tmux` call outside the test's server, and the test fails if it refused anything.
- Tests that need to see the screen attach a real client through `script -qfc` inside a second test tmux server, then read it with `capture-pane`. Keystrokes wait for screen content rather than sleeping.

A new test that sources `sshl-lib.sh` must go through `sshl_setup` in `test_helper.bash`, which checks that `mktemp -d` worked before anything is exported. With empty overrides the library falls back to the real directory and socket.
