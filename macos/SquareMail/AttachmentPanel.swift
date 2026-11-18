import AppKit
import ClassicKit

final class AttachmentPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var assets: [MediaAsset] = []
    private var preview: (String, NSImage)?
    var onPreview: ((MediaAsset) -> Void)?
    var onOpen: ((MediaAsset) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("attachment"))
        column.width = 500
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 70
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Attachments")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func show(_ assets: [MediaAsset]) {
        self.assets = assets.filter { $0.source.kind != .remote }
        preview = nil
        table.reloadData()
    }
    func showPreview(_ image: NSImage, asset: MediaAsset) {
        // Only the selected thumbnail is decoded in memory; previous previews stay on disk.
        preview = (asset.id, image)
        table.reloadData()
    }
    override func layout() { super.layout(); scroll.frame = bounds }
    func numberOfRows(in tableView: NSTableView) -> Int { assets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard assets.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AttachmentCell) ?? AttachmentCell()
        cell.identifier = id
        let asset = assets[row]
        cell.configure(asset, image: preview?.0 == asset.id ? preview?.1 : nil)
        cell.onPreview = { [weak self] in self?.onPreview?(asset) }
        cell.onOpen = { [weak self] in self?.onOpen?(asset) }
        return cell
    }
}

private final class AttachmentCell: NSTableCellView {
    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = ClassicButton("Load preview")
    private let open = ClassicButton("Open preview")
    var onPreview: (() -> Void)?
    var onOpen: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [picture, name, detail, button, open] { addSubview(view) }
        name.font = ClassicTheme.font(12, weight: .bold)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = ClassicTheme.font(10)
        detail.textColor = ClassicTheme.muted
        button.onPress = { [weak self] in self?.onPreview?() }
        open.onPress = { [weak self] in self?.onOpen?() }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(_ asset: MediaAsset, image: NSImage?) {
        picture.image = image
        name.stringValue = asset.name
        detail.stringValue = asset.mime + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: asset.size), countStyle: .file)
        button.isEnabled = asset.previewable
        open.isHidden = asset.documentType == nil
        open.isEnabled = asset.previewable
        button.toolTip = asset.previewable ? "Download up to 8 MiB and generate a thumbnail" : "Preview supports images, PDF, DOCX and XLSX up to 8 MiB"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 5, y: 4, width: 75, height: 62)
        let width = max(0, bounds.width - 205)
        name.frame = NSRect(x: 87, y: 12, width: width, height: 19)
        detail.frame = NSRect(x: 87, y: 36, width: width, height: 17)
        button.frame = NSRect(x: bounds.width - 111, y: open.isHidden ? 20 : 5, width: 104, height: 26)
        open.frame = NSRect(x: bounds.width - 111, y: 38, width: 104, height: 26)
    }
}
