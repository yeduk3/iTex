# NativeTerminal

`NativeTerminal` is a small SwiftUI wrapper around SwiftTerm's local-process terminal for macOS.

```swift
import NativeTerminal

NativeTerminalView(
    configuration: NativeTerminalConfiguration(
        workingDirectory: projectDirectory
    ),
    onCloseRequest: { showTerminal = false },
    focusRequest: terminalFocusRequest
)
```

The default configuration starts the user's login shell in `workingDirectory`. An executable,
arguments, and environment overrides can also be supplied for a purpose-specific terminal. The
configuration is fixed for the lifetime of a view; assign a new SwiftUI identity to create a fresh
session after changing it. Increment `focusRequest` when the host wants the terminal to become first
responder; unchanged values do not reclaim focus during ordinary SwiftUI updates. Keeping the view
in the hierarchy preserves its PTY and shell even when its frame is collapsed. Removing the view
terminates the process. `onCloseRequest` is invoked for Cmd+W while the terminal owns keyboard focus;
the host should remove the view to close that session.

## App Sandbox

SwiftTerm's local process terminal launches a shell and pseudo-terminal on the host. A sandboxed
macOS app cannot generally provide a normal unrestricted shell or filesystem access. Use this
module in a non-sandboxed app, or design and document narrowly scoped sandbox permissions and
expect shell functionality to remain limited.
