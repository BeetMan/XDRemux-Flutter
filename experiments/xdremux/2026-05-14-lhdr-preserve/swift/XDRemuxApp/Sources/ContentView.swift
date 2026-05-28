import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = XDRemuxViewModel()
    @State private var isTargeted: Bool = false
    
    var body: some View {
        ZStack {
            // Standard window translucent material
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            Group {
                switch viewModel.state {
                case .idle:
                    idleView
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 1.05))
                        ))
                case .processing:
                    processingView
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 1.05))
                        ))
                case .completed:
                    completedView
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity.combined(with: .scale(scale: 1.05))
                        ))
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: viewModel.state)
        }
        .frame(minWidth: 540, minHeight: 380)
        .background(Color.clear)
    }
    
    private var idleView: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [8, 4])
                    )
                
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isTargeted)
                    
                    VStack(spacing: 6) {
                        Text("将图片拖拽至此")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.primary)
                        
                        Text("支持 LHDR / UHDR 自动转换为 ISO HDR")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
            .scaleEffect(isTargeted ? 1.03 : 1.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isTargeted)
            .dropDestination(for: URL.self) { items, location in
                handleDrop(items: items)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            
            Button(action: selectFiles) {
                Label("选择文件…", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
    
    private var processingView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse.byLayer)
                
                Text("正在转换")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
            }
            
            VStack(spacing: 16) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        
                        let progress = viewModel.totalFiles > 0 ? CGFloat(viewModel.processedCount) / CGFloat(viewModel.totalFiles) : 0
                        
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(geo.size.width * progress, 0))
                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
                    }
                }
                .frame(height: 8)
                .frame(maxWidth: 320)
                
                HStack(spacing: 0) {
                    Text("\(viewModel.processedCount)")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(" / \(viewModel.totalFiles)")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                
                Text(viewModel.currentFileName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 32)
            
            if viewModel.failedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(viewModel.failedCount) 个文件转换失败")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1), in: Capsule())
            }
            
            Button("取消任务") {
                withAnimation {
                    viewModel.cancelTask()
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .keyboardShortcut(.cancelAction)
        }
        .padding(40)
    }
    
    private var completedView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: viewModel.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(viewModel.failedCount == 0 ? Color.green : Color.orange)
                    .symbolEffect(.bounce, value: viewModel.state == .completed)
                
                Text("转换完成")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
            }
            
            VStack(spacing: 8) {
                Text("成功处理了 \(viewModel.processedCount) 个文件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if viewModel.failedCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(viewModel.failedCount) 个文件转换失败")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 32)
            
            Button("完成") {
                withAnimation {
                    viewModel.acknowledgeCompletion()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
    
    private func handleDrop(items: [URL]) -> Bool {
        guard !items.isEmpty else { return false }
        viewModel.processFiles(from: items)
        return true
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.heic]
        
        if panel.runModal() == .OK {
            viewModel.processFiles(from: panel.urls)
        }
    }
}
