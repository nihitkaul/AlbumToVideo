import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .navigationTitle("Album to Video")
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List {
            Section("Google Photos") {
                if let err = model.oauthConfigError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.tokens == nil {
                    Button("Sign in with Google") {
                        model.signIn()
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                } else {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Sign out") { model.signOut() }
                }
                Button("Pick photos in Google Photos…") {
                    model.startGooglePhotosPicker()
                }
                .disabled(model.tokens == nil || model.phase == .downloading || model.phase == .exporting)
            }

            Section("Or use files") {
                Button("Import folder of images…") {
                    model.importLocalFolder()
                }
                .disabled(model.phase == .downloading || model.phase == .exporting)
            }

            Section("Audio (optional)") {
                if let a = model.audioURL {
                    Text(a.lastPathComponent)
                        .lineLimit(2)
                        .font(.caption)
                    Button("Clear audio") { model.clearAudio() }
                } else {
                    Button("Choose audio file…") {
                        model.chooseAudioFile()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBanner

                GroupBox("Slideshow settings") {
                    Form {
                        HStack {
                            Text("Seconds per slide")
                            Spacer()
                            TextField("", value: $model.exportSettings.secondsPerSlide, format: .number)
                                .labelsHidden()
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Frame rate (fps)")
                            Spacer()
                            TextField("", value: $model.exportSettings.frameRate, format: .number)
                                .labelsHidden()
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Output width")
                            Spacer()
                            TextField("", value: $model.exportSettings.outputWidth, format: .number)
                                .labelsHidden()
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Output height")
                            Spacer()
                            TextField("", value: $model.exportSettings.outputHeight, format: .number)
                                .labelsHidden()
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("Ken Burns (slow zoom)", isOn: $model.exportSettings.kenBurnsEnabled)
                        HStack {
                            Text("Crossfade (seconds)")
                            Spacer()
                            TextField("", value: $model.exportSettings.crossfadeSeconds, format: .number)
                                .labelsHidden()
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Audio volume")
                            Spacer()
                            Slider(value: Binding(
                                get: { Double(model.exportSettings.audioVolume) },
                                set: { model.exportSettings.audioVolume = Float($0) }
                            ), in: 0 ... 1)
                                .frame(maxWidth: 200)
                        }
                    }
                    .formStyle(.grouped)
                    .padding(.vertical, 4)
                }

                GroupBox("Images") {
                    if model.imageURLs.isEmpty {
                        Text("No images yet. Use Google Photos picker or import a folder.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(model.imageURLs.count) images ready.")
                            .font(.headline)
                        if let p = model.downloadProgress {
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                                Text("Downloading \(p.done) / \(p.total)")
                            }
                        }
                    }
                }

                Button {
                    model.exportVideo()
                } label: {
                    Label("Export MP4…", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.imageURLs.isEmpty || model.phase == .exporting || model.phase == .downloading)

                if model.phase == .exporting, let ep = model.exportProgress {
                    ProgressView(value: ep) {
                        Text("Encoding…")
                    }
                }

                Text(googleNotice)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var statusBanner: some View {
        Group {
            if !model.statusMessage.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: phaseIcon)
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text(model.statusMessage)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var phaseIcon: String {
        switch model.phase {
        case .waitingForPicks: return "photo.on.rectangle.angled"
        case .downloading: return "arrow.down.circle"
        case .exporting: return "waveform.circle"
        default: return "info.circle"
        }
    }

    private var googleNotice: String {
        """
        Google sign-in uses the official Photos Picker API. In the browser, open any album and select the photos you want (you can select many at once). \
        Programmatic listing of every album in your library is no longer supported by Google for new apps after March 2025—this flow matches current policy.
        """
    }
}

#Preview {
    ContentView()
        .environmentObject(AppViewModel())
}
