#!/usr/bin/env swift
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let processIdentifier = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: assert-menu-popover.swift <pid>\n".utf8))
    exit(2)
}

let deadline = Date().addingTimeInterval(8)
while Date() < deadline {
    let windows =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let hasVisiblePopover = windows.contains { window in
        guard
            let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
            let layer = window[kCGWindowLayer as String] as? Int,
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
        else {
            return false
        }

        return ownerPID == processIdentifier
            && layer >= 0
            && layer <= 30
            && (bounds["Width"] ?? 0) >= 400
            && (bounds["Width"] ?? 0) <= 560
            && (bounds["Height"] ?? 0) >= 500
            && (bounds["Height"] ?? 0) <= 760
    }

    if hasVisiblePopover {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

FileHandle.standardError.write(Data("No visible Glass Dock status popover was found for process \(processIdentifier).\n".utf8))
exit(1)
