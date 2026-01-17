//
//  Compat.swift
//  ChatX509
//
//  Compatibility layers for iOS 15 support
//

import SwiftUI
import PhotosUI

// MARK: - Navigation

struct AnyNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension View {
    // Helper to present share sheet
    func shareSheet(isPresented: Binding<Bool>, items: [Any]) -> some View {
        self.sheet(isPresented: isPresented) {
            ShareSheet(activityItems: items)
        }
    }
}

// MARK: - Photo Picker

struct PhotoPickerCompat<Label: View>: View {
    @Binding var selection: Data?
    @Binding var isPresented: Bool
    let label: () -> Label
    
    var body: some View {
        if #available(iOS 16.0, *) {
            // iOS 16+ PhotosPicker
            // Note: We need a binding to PhotosPickerItem locally to bridge
            PhotosPickerWrapper(selection: $selection, label: label)
        } else {
            // iOS 15 PHPickerViewController
            Button(action: { isPresented = true }, label: label)
                .sheet(isPresented: $isPresented) {
                    PHPickerWrapper(selection: $selection)
                }
        }
    }
}

@available(iOS 16.0, *)
private struct PhotosPickerWrapper<Label: View>: View {
    @Binding var selection: Data?
    let label: () -> Label
    @State private var item: PhotosPickerItem?
    
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            label()
        }
        .onChange(of: item) { newItem in
            guard let newItem = newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                     await MainActor.run { selection = data }
                }
            }
        }
    }
}

private struct PHPickerWrapper: UIViewControllerRepresentable {
    @Binding var selection: Data?
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PHPickerWrapper
        
        init(parent: PHPickerWrapper) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            
            provider.loadObject(ofClass: UIImage.self) { image, error in
                guard let uiImage = image as? UIImage,
                      let data = uiImage.jpegData(compressionQuality: 0.8) else { return }
                
                DispatchQueue.main.async {
                    self.parent.selection = data
                }
            }
        }
    }
}

extension View {
    func photoPickerSheet(isPresented: Binding<Bool>, selection: Binding<Data?>) -> some View {
        self.modifier(PhotoPickerViewModifier(isPresented: isPresented, selection: selection))
    }
}

struct PhotoPickerViewModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selection: Data?
    
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            // Use a separate view to hold the state since ViewModifier cannot hold @State for availability constrained types easily without Any
            content.background(PhotosPickerBinder(isPresented: $isPresented, selection: $selection))
        } else {
             content
                .sheet(isPresented: $isPresented) {
                    PHPickerWrapper(selection: $selection)
                }
        }
    }
}

@available(iOS 16.0, *)
private struct PhotosPickerBinder: View {
    @Binding var isPresented: Bool
    @Binding var selection: Data?
    @State private var item: PhotosPickerItem?

    var body: some View {
        Color.clear
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images)
            .onChange(of: item) { newItem in
                guard let newItem = newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                         await MainActor.run { selection = data }
                    }
                }
            }
    }
}


// MARK: - Text Field

struct MultiLineTextField: View {
    var placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding? = nil
    
    var body: some View {
        if #available(iOS 16.0, *) {
            if let focused = focused {
                TextField(placeholder, text: $text, axis: .vertical)
                    .focused(focused)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
            }
        } else {
            // iOS 15 Fallback
            // Using a simple TextField for now as TextEditor is tricky with dynamic height
            if let focused = focused {
                 TextField(placeholder, text: $text)
                    .focused(focused)
            } else {
                 TextField(placeholder, text: $text)
            }
        }
    }
}


// MARK: - Toolbar Compatibility

/// Compatibility enum for ToolbarPlacement which is only available on iOS 16+
public enum CompatToolbarPlacement {
    case automatic
    case bottomBar
    case navigationBar
    case tabBar
    case windowToolbar
}

extension View {
    @ViewBuilder
    func compatToolbarBackground(_ style: some ShapeStyle, for bar: CompatToolbarPlacement) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(style, for: bar.toNative())
        } else {
            self
        }
    }

    @ViewBuilder
    func compatToolbarBackground(_ visibility: Visibility, for bar: CompatToolbarPlacement) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(visibility, for: bar.toNative())
        } else {
            self
        }
    }
    
    @ViewBuilder
    func compatToolbarColorScheme(_ colorScheme: ColorScheme?, for bar: CompatToolbarPlacement) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarColorScheme(colorScheme, for: bar.toNative())
        } else {
            self
        }
    }
}

@available(iOS 16.0, *)
extension CompatToolbarPlacement {
    func toNative() -> ToolbarPlacement {
        switch self {
        case .automatic: return .automatic
        case .bottomBar: return .bottomBar
        case .navigationBar: return .navigationBar
        case .tabBar: return .tabBar
        #if os(macOS)
        case .windowToolbar: return .windowToolbar
        #else
        case .windowToolbar: return .automatic // Fallback on iOS
        #endif
        }
    }
}


// MARK: - Presentation Detents compatibility

extension View {
    @ViewBuilder
    func compatPresentationDetents() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}
