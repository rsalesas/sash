import Foundation

/// One web view and everything that belongs to it. Fleshed out in Session.swift
/// as the milestone progresses; declared here so requests can carry it.
@MainActor
public final class Session: Identifiable {
    public let id: String

    init(id: String) { self.id = id }
}
