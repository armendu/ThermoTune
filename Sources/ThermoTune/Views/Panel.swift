import SwiftUI

/// Styled like a grouped `Form` section, which can't sit side by side.
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
            // A pop-up button's height, so headers with and without controls line up.
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

    /// Rows share the panel's height instead of leaving it empty below them.
    func fillingHeight() -> Self {
        var panel = self
        panel.fillsHeight = true
        return panel
    }
}

extension Panel where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
