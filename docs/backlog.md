# Follow-up work

## Completed: macOS shutdown from the login screen

Implemented on 11 October 2026 with optional, installable MacVM Guest Tools.
Two macOS 27.0.1 restart-to-login tests shut down normally from one host toolbar
click, exited the runner, and returned the library to zero active machines.
The second included pause/resume. Desktop shutdown and guest restart also passed.
Guest logs confirm the normal pre-login system shutdown path. Force Stop was
not used; the existing timeout recovery remains available.

Evidence and implementation: [shutdown validation](macos-shutdown-fix.md).

## Guest Tools broader compatibility validation

Test cold boot while remaining at the login screen, fast user switching, locked user
sessions, SSH sessions, and unsaved-document cancellation. The session policy
already fails closed and is unit tested; these cases need additional live tests.
Verify older supported macOS guest versions separately from macOS 27.0.1.
