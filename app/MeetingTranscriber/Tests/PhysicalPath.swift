import Foundation

/// `path` with every symlink resolved, as `pwd -P` reports it
/// (`/var` → `/private/var`). Foundation's `resolvingSymlinksInPath`
/// strips `/private` instead, so it cannot be compared with the shell.
func physicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
