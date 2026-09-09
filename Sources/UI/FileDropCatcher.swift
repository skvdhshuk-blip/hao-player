import AppKit
import SwiftUI

enum FileDropHit {
    static func intercepts(eventType: NSEvent.EventType?, dropActive: Bool, hasFilePasteboard: Bool) -> Bool {
        if dropActive {
            return true
        }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return false
        default:
            return hasFilePasteboard
        }
    }
}

struct FileDropCatcher: NSViewRepresentable {
    var onOpen: (OpenedDrop) -> Void
    var onFail: (String) -> Void

    func makeNSView(context: Context) -> FileDropView {
        let view = FileDropView()
        view.onOpen = onOpen
        view.onFail = onFail
        return view
    }

    func updateNSView(_ nsView: FileDropView, context: Context) {
        nsView.onOpen = onOpen
        nsView.onFail = onFail
    }
}

final class FileDropView: NSView {
    var onOpen: ((OpenedDrop) -> Void)?
    var onFail: ((String) -> Void)?

    private var dropActive = false

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hasFiles = NSPasteboard(name: .drag).canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        if FileDropHit.intercepts(
            eventType: NSApp.currentEvent?.type,
            dropActive: dropActive,
            hasFilePasteboard: hasFiles
        ) {
            return self
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropActive = canAccept(sender)
        return dropActive ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropActive = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropActive = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropActive = false
        do {
            onOpen?(try FileOpening.ingestPasteboard(sender.draggingPasteboard))
            return true
        } catch {
            onFail?(error.localizedDescription)
            return false
        }
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }
}
