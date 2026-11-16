import SwiftUI
import MosaicAppCore

struct ScanView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(model.scan.titleKey).font(.title2.bold())
            ProgressView(value: model.scan.progress.fraction).padding(.horizontal, 40)
            Text(model.scan.progressLine).font(.footnote).monospacedDigit()
            if model.scan.isFirstScan { Text(L10nKey.scanFirstTimeHint).font(.footnote).foregroundStyle(.secondary) }
            if let ready = model.scan.progressiveReadyLine {
                Text(ready)
                Text(L10nKey.scanProgressiveHint).font(.footnote).foregroundStyle(.secondary)
                Button { dismiss(); model.generateTapped() } label: { Text(L10nKey.scanProgressiveCTA) }
                    .buttonStyle(.borderedProminent)
            }
            if model.scan.phase == .stopped {
                Text(L10nKey.miscScanStopped).multilineTextAlignment(.center)
                Button { model.startScan() } label: { Text(L10nKey.commonRetry) }
                if model.scan.canUsePartialAfterStop {
                    Button { dismiss(); model.generateTapped() } label: { Text(L10nKey.generateCTA) }
                }
            } else if model.scan.phase == .completed {
                Button { dismiss(); model.generateTapped() } label: { Text(L10nKey.generateCTA) }.buttonStyle(.borderedProminent)
            } else {
                Button(role: .cancel) { model.scanCancelTapped() } label: { Text(L10nKey.scanCancel) }
            }
        }
        .padding(32)
        .alert(Text(L10nKey.scanCancelConfirmTitle), isPresented: .constant(model.scan.phase == .confirmingCancel)) {
            Button(role: .destructive) { model.scanCancelConfirmed() } label: { Text(L10nKey.scanCancelConfirmStop) }
            Button(role: .cancel) { model.scanCancelDismissed() } label: { Text(L10nKey.scanCancelConfirmContinue) }
        } message: { Text(L10nKey.scanCancelConfirmBody) }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let state: LibraryEmptyState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: state == .noPhotos ? "photo" : "icloud.and.arrow.down").font(.system(size: 48))
            Text(state.titleKey).font(.title3.bold())
            Text(state.bodyKey).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                if state == .notDownloaded { model.startScan() }   // 「重新检查」：全量 diff 会重试未下载的
                dismiss()
            } label: { Text(state.buttonKey) }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
