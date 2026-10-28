import SwiftUI

/// A titled group of rows styled like a grouped `Form` section. The main window
/// puts these side by side, which a `Form` can't do: its sections only stack.
struct Panel<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer
    private var fillsHeight = false

    init(@ViewBuilder content: () -> Content,
         @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The height of a pop-up button, so a header with controls and one
            // without line up when two panels sit side by side.
            header
                .frame(minHeight: 24)
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider().padding(.horizontal, 10)
                        }
                        row
                            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil,
                                   alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))

            footer
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
    }

    /// Stretches the rows to share whatever height the panel is offered,
    /// instead of leaving it empty below them.
    func fillingHeight() -> Self {
        var panel = self
        panel.fillsHeight = true
        return panel
    }
}

extension Panel where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension Panel where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
