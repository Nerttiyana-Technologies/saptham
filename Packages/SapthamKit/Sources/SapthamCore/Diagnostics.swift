import os

/// Unified-log channel for the engine. Read with:
///   log stream --predicate 'subsystem == "com.nerttiyana.saptham"'
/// Never logs caption text or audio content.
public enum Diagnostics {
    public static let engine = Logger(subsystem: "com.nerttiyana.saptham", category: "engine")
}
