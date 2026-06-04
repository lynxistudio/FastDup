import SwiftUI
import AppKit
import Quartz

// MARK: - App Entry Point

@main
struct FastDupApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands { SidebarCommands() }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            ResultsPanelView()
        }
    }
}

// ============================================================================
// MARK: - Sidebar
// ============================================================================

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: .constant("")) {
            Section {
                ForEach(appState.monitoredDirectories, id: \.self) { dir in
                    SidebarFolderRow(path: dir)
                        .contextMenu {
                            Button("Rescan") { appState.rescanDirectory(dir) }
                            Divider()
                            Button("Remove") { appState.removeDirectory(dir) }
                        }
                }

                HStack(spacing: 6) {
                    Button(action: { appState.addDirectory() }) {
                        Label("Add Folder", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .disabled(appState.isScanning || appState.isPaused)

                    Spacer()

                    if !appState.monitoredDirectories.isEmpty {
                        Button(action: { appState.clearAllDirectories() }) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Clear all directories")
                        .disabled(appState.isScanning || appState.isPaused)
                    }
                }
            } header: {
                Text("FOLDERS")
            }

            Section {
                RuleConfigPanelView()
            } header: {
                Text("COMPARE RULES")
            }

            Section {
                ScanControlView()
            } header: {
                Text("SCAN CONTROL")
            }

            if !appState.duplicateGroups.isEmpty && !appState.isScanning {
                Section {
                    QuickActionsView()
                } header: {
                    Text("QUICK ACTIONS")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Sidebar Folder Row (Finder-style)

struct SidebarFolderRow: View {
    let path: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Rule Config Panel

struct RuleConfigPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Preset", selection: Binding<SearchRule>(
                get: { appState.selectedRule },
                set: { appState.selectedRule = $0 }
            )) {
                ForEach(SearchRule.presets) { preset in
                    Text(preset.name).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(appState.isScanning || appState.isPaused)

            Text(appState.selectedRule.displayName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                dimensionToggle("File Size", type: .sameSize)
                dimensionToggle("File Extension", type: .sameExtension)
                dimensionToggle("Exact Hash (MD5)", type: .exactHash)
                dimensionToggle("Exact Hash (SHA)", type: .exactHashSHA)
                dimensionToggle("File Name Exact", type: .sameName)
                dimensionToggle("Resolution", type: .sameResolution)
                dimensionToggle("Duration", type: .sameDuration)
            }
        }
    }

    func dimensionToggle(_ label: String, type: SearchRule.RuleType) -> some View {
        Toggle(isOn: binding(for: type)) {
            Text(label)
                .font(.system(size: 11))
        }
        .toggleStyle(.checkbox)
        .disabled(appState.isScanning || appState.isPaused)
    }

    func binding(for type: SearchRule.RuleType) -> Binding<Bool> {
        Binding<Bool>(
            get: { appState.selectedRule.ruleTypes.contains(type) },
            set: { checked in
                if checked {
                    if !appState.selectedRule.ruleTypes.contains(type) {
                        appState.selectedRule.ruleTypes.append(type)
                    }
                } else {
                    appState.selectedRule.ruleTypes.removeAll { $0 == type }
                }
            }
        )
    }
}

// MARK: - Scan Control

struct ScanControlView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: appState.scanStatus.systemImage)
                    .foregroundColor(statusColor)
                    .font(.system(size: 11))
                Text(appState.scanStatus.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 4) {
                if appState.canStartScan {
                    scanButton("Scan", systemImage: "play.fill") {
                        Task { await appState.startScan() }
                    }
                }
                if appState.canResume {
                    scanButton("Resume", systemImage: "play.fill") {
                        appState.resumeScan()
                    }
                }
                if appState.canPause {
                    scanButton("Pause", systemImage: "pause.fill") {
                        appState.pauseScan()
                    }
                }
                if appState.canStop {
                    scanButton("Stop", systemImage: "stop.fill") {
                        appState.stopScan()
                    }
                }
            }

            if appState.scanStatus == .scanning || appState.scanStatus == .paused {
                VStack(spacing: 3) {
                    ProgressView(value: appState.scanProgress)
                        .progressViewStyle(.linear)
                    Text(appState.currentFile)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Text("\(appState.totalFilesScanned) files")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(appState.totalDuplicateGroups) groups")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if appState.scanStatus == .stopped || appState.scanStatus == .completed {
                HStack {
                    Text("Files:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(appState.totalFilesScanned)")
                        .font(.system(size: 10, weight: .medium))
                }
                HStack {
                    Text("Groups:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(appState.totalDuplicateGroups)")
                        .font(.system(size: 10, weight: .medium))
                }
            }
        }
    }

    var statusColor: Color {
        switch appState.scanStatus {
        case .idle: return .secondary
        case .scanning: return .accentColor
        case .paused: return .orange
        case .stopped: return .red
        case .completed: return .green
        }
    }

    func scanButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
}

// MARK: - Quick Actions

struct QuickActionsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            Button {
                appState.selectAllDuplicatesExceptOnePerGroup()
            } label: {
                Label("Select Duplicates", systemImage: "checkmark.rectangle.stack")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                appState.deselectAll()
            } label: {
                Label("Deselect All", systemImage: "rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)

            if appState.totalSelectedCount > 0 {
                Divider()
                HStack {
                    Text("\(appState.totalSelectedCount) selected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Button(role: .destructive) {
                    appState.requestDeleteConfirmation()
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            }

            if appState.canUndo {
                Button {
                    appState.undoLastDelete()
                } label: {
                    Label("Undo Delete", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// ============================================================================
// MARK: - Results Panel
// ============================================================================

struct ResultsPanelView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var qlCoordinator = QuickLookCoordinator()

    var body: some View {
        ZStack {
            if appState.duplicateGroups.isEmpty && appState.scanStatus == .idle {
                idleView
            } else if appState.isScanning && appState.duplicateGroups.isEmpty {
                scanningView
            } else if appState.duplicateGroups.isEmpty && (appState.scanStatus == .completed || appState.scanStatus == .stopped) {
                noDupsView
            } else {
                resultsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $appState.showDeleteConfirmation) {
            DeleteConfirmationView().environmentObject(appState)
        }
        .alert("Delete failed", isPresented: Binding(
            get: { appState.deleteError != nil },
            set: { if !$0 { appState.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.deleteError = nil }
        } message: {
            Text(appState.deleteError ?? "")
        }
        .onAppear {
            qlCoordinator.installEventMonitor { [weak qlCoordinator] in
                guard let coordinator = qlCoordinator else { return }
                if QLPreviewPanel.shared().isVisible {
                    QLPreviewPanel.shared().orderOut(nil)
                } else {
                    // Spacebar: preview the focused file
                    if let file = appState.focusedFileForPreview() {
                        coordinator.files = [file]
                        coordinator.currentIndex = 0
                        coordinator.showPreview()
                    }
                }
            }
        }
        .onChange(of: appState.previewRequestCounter) { _, _ in
            guard let file = appState.previewFile else { return }
            qlCoordinator.files = [file]
            qlCoordinator.currentIndex = 0
            qlCoordinator.showPreview()
        }
        .onDisappear { qlCoordinator.uninstallEventMonitor() }
    }

    // MARK: Idle

    var idleView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Add folders and start scanning")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: Scanning

    var scanningView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("Scanning...")
                .font(.system(size: 14, weight: .medium))
            VStack(spacing: 4) {
                ProgressView(value: appState.scanProgress).frame(width: 260)
                Text(appState.currentFile)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 260)
            }
            Spacer()
        }
    }

    // MARK: No duplicates

    var noDupsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.green.opacity(0.5))
            Text("No duplicates found")
                .font(.system(size: 16, weight: .medium))
            Text("\(appState.totalFilesScanned) files scanned")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: Results

    var resultsView: some View {
        VStack(spacing: 0) {
            // Toolbar
            ResultsToolbar()

            Divider()

            // Content
            if appState.resultsViewMode == .list {
                ResultsListView()
            } else {
                ResultsThumbnailView()
            }
        }
    }
}

// MARK: - Results Toolbar

struct ResultsToolbar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text("\(appState.duplicateGroups.count) groups · \(appState.totalDuplicateFileCount) files")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            if appState.totalSelectedCount > 0 {
                Text("\(appState.totalSelectedCount) selected")
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(.blue)
            }

            // View mode toggle
            Picker("View", selection: $appState.resultsViewMode) {
                Image(systemName: "list.bullet").tag(ResultsViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ResultsViewMode.thumbnail)
            }
            .pickerStyle(.segmented)
            .frame(width: 60)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// ============================================================================
// MARK: - Results List View (Finder / Xcode style)
// ============================================================================

struct ResultsListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appState.duplicateGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeaderView(group: group)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .background(Color(nsColor: .windowBackgroundColor))

                        ForEach(group.files) { file in
                            FileRowView(file: file, group: group)
                                .padding(.horizontal, 8)
                        }
                    }
                    .id(group.id)

                    Divider()
                        .padding(.horizontal, 12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Results Thumbnail View

struct ResultsThumbnailView: View {
    @EnvironmentObject var appState: AppState

    let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)]

    var body: some View {
        ScrollView {
            ForEach(appState.duplicateGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    GroupHeaderView(group: group)
                        .padding(.horizontal, 12)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(group.files) { file in
                            ThumbnailCell(file: file, group: group)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 12)
            }
        }
    }
}

// MARK: - Group Header

struct GroupHeaderView: View {
    let group: DuplicateGroup
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))

            Text("\(group.files.count) duplicates")
                .font(.system(size: 12, weight: .semibold))

            Text("~\(appState.savingsFormatted(for: group))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            ConfidenceBadge(confidence: group.confidence)

            Button {
                appState.selectAllInGroup(group.id)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Select duplicates in group")

            Button {
                appState.deselectAllInGroup(group.id)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Deselect all in group")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - File Row View (Finder-style compact)

struct FileRowView: View {
    let file: FileItem
    let group: DuplicateGroup
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false
    @State private var showRenameSheet = false

    var isSelected: Bool { appState.selectedFileIDs.contains(file.id) }
    var isFocused: Bool { appState.focusedFileID == file.id }
    var isPreserved: Bool { appState.isPreserved(file, in: group) }

    var body: some View {
        HStack(spacing: 6) {
            // Checkbox for selection only
            selectionCheckbox

            // File icon
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(file.url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Size & metadata
            HStack(spacing: 6) {
                keepButton

                Text(file.sizeFormatted)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)

                if let res = file.resolution {
                    Text(res.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Text(file.fileExtension.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            // Hover actions
            if isHovering {
                HStack(spacing: 2) {
                    actionButton("eye", "Preview (Space)") { quickLook(file) }
                    actionButton("play.fill", "Open") { NSWorkspace.shared.open(file.url) }
                    actionButton("folder.fill", "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                    actionButton("doc.on.doc", "Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.path, forType: .string)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .onTapGesture {
            // Click = focus, not selection
            appState.setFocus(file.id)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.url) }
            Button("Quick Look") { quickLook(file) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Divider()
            Button("Keep This File") {
                appState.setFileToPreserve(file.id, in: group.id)
            }
            .disabled(isPreserved)
            Divider()
            Button("Rename...") { showRenameSheet = true }
            Divider()
            Button("Move to Trash") {
                appState.deleteSingleFile(file)
            }
            .disabled(isPreserved)
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheetView(originalName: file.name, fileURL: file.url, isPresented: $showRenameSheet)
        }
    }

    var selectionCheckbox: some View {
        ZStack {
            if isPreserved {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 14))
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary.opacity(0.35))
                    .font(.system(size: 14))
            }
        }
        .onTapGesture { appState.toggleSelection(file.id) }
        .help(isPreserved ? "Kept file. Choose another Keep file before deleting this one." : "Select for deletion")
    }

    var keepButton: some View {
        Button {
            appState.setFileToPreserve(file.id, in: group.id)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isPreserved ? "checkmark.shield.fill" : "shield")
                    .font(.system(size: 9, weight: .medium))
                Text("Keep")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(keepBackground)
            .foregroundColor(isPreserved ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(isPreserved)
        .help(isPreserved ? "This file will be kept" : "Keep this file and select the others in this group")
    }

    var keepBackground: some ShapeStyle {
        isPreserved ? .green.opacity(0.12) : .secondary.opacity(0.08)
    }

    var rowBackground: some View {
        Group {
            if isFocused {
                Color.accentColor.opacity(0.1)
            } else if isSelected {
                Color.accentColor.opacity(0.06)
            } else if isHovering {
                Color.primary.opacity(0.03)
            } else {
                Color.clear
            }
        }
    }

    func actionButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    func quickLook(_ file: FileItem) {
        appState.requestPreview(file)
    }

}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let file: FileItem
    let group: DuplicateGroup
    @EnvironmentObject var appState: AppState

    var isSelected: Bool { appState.selectedFileIDs.contains(file.id) }
    var isFocused: Bool { appState.focusedFileID == file.id }
    var isPreserved: Bool { appState.isPreserved(file, in: group) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                if isPreserved {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                        .background(Circle().fill(.white).frame(width: 12, height: 12))
                        .offset(x: 4, y: -4)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 14))
                        .background(Circle().fill(.white).frame(width: 12, height: 12))
                        .offset(x: 4, y: -4)
                }
            }

            Text(file.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(file.sizeFormatted)
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Button {
                appState.setFileToPreserve(file.id, in: group.id)
            } label: {
                Label("Keep", systemImage: isPreserved ? "checkmark.shield.fill" : "shield")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundColor(isPreserved ? .green : .secondary)
            .disabled(isPreserved)
            .help(isPreserved ? "This file will be kept" : "Keep this file and select the others in this group")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isFocused ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .onTapGesture {
            appState.setFocus(file.id)
            if !isPreserved {
                appState.toggleSelection(file.id)
            }
        }
    }
}

// ============================================================================
// MARK: - Delete Confirmation Sheet
// ============================================================================

struct DeleteConfirmationView: View {
    @EnvironmentObject var appState: AppState

    var filesToDelete: [FileItem] {
        appState.allFiles.filter { appState.selectedFileIDs.contains($0.id) }
    }

    var totalSize: Int64 {
        filesToDelete.reduce(0) { $0 + Int64($1.size) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.fill")
                .font(.system(size: 32))
                .foregroundColor(.red)
                .padding(.top, 12)

            Text("Move \(filesToDelete.count) files to Trash?")
                .font(.title3).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Files:").font(.system(size: 12))
                    Spacer()
                    Text("\(filesToDelete.count)").font(.system(size: 12, weight: .medium))
                }
                HStack {
                    Text("Size:").font(.system(size: 12))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(.blue)
                    Text("At least one file per group is preserved.").font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: 400)

            if !filesToDelete.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filesToDelete.prefix(15)) { file in
                            Text(file.name).font(.system(size: 10)).lineLimit(1)
                        }
                        if filesToDelete.count > 15 {
                            Text("...and \(filesToDelete.count - 15) more")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: 400)
                }
                .frame(maxHeight: 140)
            }

            HStack(spacing: 12) {
                Button("Cancel") { appState.showDeleteConfirmation = false }
                    .buttonStyle(.bordered).controlSize(.large)
                    .keyboardShortcut(.escape)
                Button(role: .destructive) { appState.deleteSelected() } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(.red)
                .keyboardShortcut(.return)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 460)
    }
}

// ============================================================================
// MARK: - Rename Sheet
// ============================================================================

struct RenameSheetView: View {
    let originalName: String
    let fileURL: URL
    @Binding var isPresented: Bool
    @State private var newName: String
    @State private var errorMessage: String?

    init(originalName: String, fileURL: URL, isPresented: Binding<Bool>) {
        self.originalName = originalName
        self.fileURL = fileURL
        self._isPresented = isPresented
        self._newName = State(initialValue: originalName)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Rename File").font(.headline)
            Text("Original: \(originalName)").font(.system(size: 11)).foregroundColor(.secondary)
            TextField("New name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
            if let err = errorMessage {
                Text(err).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack(spacing: 10) {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.escape)
                Button("Rename") { performRename() }.keyboardShortcut(.return)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == originalName)
            }
        }
        .padding(20).frame(width: 340, height: 160)
    }

    func performRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != originalName else { return }
        let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: newURL.path) {
            errorMessage = "A file with that name already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            isPresented = false
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }
}

// ============================================================================
// MARK: - Quick Look Coordinator
// ============================================================================

final class QuickLookCoordinator: NSObject, ObservableObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @Published var files: [FileItem] = []
    @Published var currentIndex = 0
    var onSpaceToggle: (() -> Void)?
    private var eventMonitor: Any?

    func installEventMonitor(onSpace: @escaping () -> Void) {
        onSpaceToggle = onSpace
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 {
                self?.onSpaceToggle?()
                return nil
            }
            return event
        }
    }

    func uninstallEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func showPreview() {
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        panel?.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { files.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < files.count else { return nil }
        return files[index].url as QLPreviewItem
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let confidence: DuplicateGroup.Confidence

    var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(confidence.rawValue)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
        .foregroundColor(color)
    }
}
