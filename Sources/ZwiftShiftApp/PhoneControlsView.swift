import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import ZwiftShiftCore

struct PhoneControlsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var qr: NSImage?
  @State private var error: String?
  @State private var copied = false
  private var status: PhoneStatus? { model.status.phone }
  private var base: String? { status?.publicURL ?? status?.localURLs.first }
  private var link: URL? { base.flatMap { model.service?.phone?.link(for: $0) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Phone controls").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      VStack(spacing: 12) {
        if let qr {
          Image(nsImage: qr).interpolation(.none).resizable()
            .frame(width: 180, height: 180).padding(12).background(.white)
            .accessibilityLabel("QR code for your private phone controls")
        } else { ProgressView().frame(width: 180, height: 180) }
        Text(base ?? "Starting phone controls…")
          .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          .lineLimit(2).multilineTextAlignment(.center)
          .accessibilityIdentifier("phone-url")
        HStack {
          Button(copied ? "Copied" : "Copy private link") {
            if let link { copy(link); copied = true }
          }
          .accessibilityIdentifier("copy-phone-link")
          Button("Open") { if let link { NSWorkspace.shared.open(link) } }
            .accessibilityIdentifier("open-phone-link")
        }.disabled(link == nil)
        Text(status?.publicURL != nil
          ? "Scan with your phone. Keep this app open on your Mac."
          : "Scan with your phone on the same Wi-Fi as this Mac.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity)
      Divider()
      Toggle("Internet access via ngrok", isOn: Binding(
        get: { status?.internetEnabled ?? true },
        set: { value in
          do { try model.service?.phone?.setInternetEnabled(value) }
          catch { self.error = error.localizedDescription }
        }))
      if status?.tunnelState == "starting" {
        Text("Connecting ngrok…").foregroundStyle(.secondary)
      }
      if let failure = error ?? status?.error {
        Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry Internet") { model.service?.phone?.retryInternet() }
      }
      if status?.publicURL != nil, let local = status?.localURLs.first {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Same Wi-Fi").foregroundStyle(.secondary)
            Text(local).font(.system(size: 11, design: .monospaced))
          }
          Spacer()
          Button("Copy") {
            if let url = model.service?.phone?.link(for: local) { copy(url) }
          }.help("Copy the private local link")
        }
      }
      HStack {
        Text("Anyone with your private link can shift.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        Button("Reset links") {
          do { try model.service?.phone?.resetAccess(); copied = false }
          catch { self.error = error.localizedDescription }
        }.font(.system(size: 11))
      }
    }
    .font(.system(size: 13)).padding(24).frame(width: 440)
    .onAppear { updateQR() }
    .onChange(of: link) { _, _ in updateQR(); copied = false }
  }
  private func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
  private func updateQR() {
    guard let link else { qr = nil; return }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(link.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { qr = nil; return }
    qr = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
